--!strict
--LateJoinHandler.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Reconciliation/LateJoinHandler.lua
    Sends the current state of all in-flight bullets to a player who joins
    while bullets are already active in the simulation.

    Without this module, a player who joins mid-match sees no bullets until
    new ones are fired after their arrival. The first frame's StateBatcher
    broadcast updates positions but does not tell the client that these cast
    IDs exist at all — the client has no cosmetic bullet to apply corrections
    to. LateJoinHandler bridges this gap by sending a synthetic fire event
    for each active bullet derived from its current trajectory.

    The synthetic fire events carry the bullet's current position (not its
    original origin) so the joining client spawns the cosmetic at the correct
    mid-flight location rather than the initial muzzle. The LatencyBuffer delay
    on the joining client is skipped for late-join spawns — the bullet is
    already in flight so no buffering is appropriate.

    SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity        = "LateJoinHandler"

local LateJoinHandler = {}
LateJoinHandler.__type = Identity

local LateJoinHandlerMetatable = table.freeze({
	__index = LateJoinHandler,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core      = script.Parent.Parent.Core
local Transport = script.Parent.Parent.Transport
local Types     = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local Authority   = require(Core.Authority)
local BlinkSchema = require(Transport.BlinkSchema)
local Constants   = require(Types.Constants)
local LogService  = require(Core.Logger)

Authority.AssertServer("LateJoinHandler")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local buffer_len     = buffer.len
local buffer_create  = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_copy    = buffer.copy
local string_format  = string.format

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Construct the current state snapshot for all active casts and send it to
-- the joining player by writing through OutboundBatcher.
--
-- V0.1.2: late-join sync must go through OutboundBatcher so the client decoder
-- receives the correct channel prefix byte before the payload. Calling
-- Remote:FireClient directly would send a raw state buffer with no channel
-- prefix — the client decoder reads the channel byte first and would
-- misidentify the first payload byte as a channel ID, corrupting the decode.
--
-- OutboundBatcher.WriteStateForAll writes to every player in the list.
-- We pass a single-element table { Player } so only the joiner is targeted.
-- The batcher is flushed immediately after writing rather than waiting for
-- the next Heartbeat — late-join sync must be instantaneous.
--
-- CurrentFrameId is StateBatcher's current _FrameId so the joining client
-- receives a FrameId coherent with the ongoing batch stream. Using 0 would
-- cause the client to discard all subsequent batches as "already seen" until
-- a rollover.
function LateJoinHandler.SyncPlayer(
	Player         : Player,
	Solver         : any,
	NetRemote      : RemoteEvent,
	CurrentFrameId : number
)
	local ActiveCasts = Solver._ActiveCasts
	if not ActiveCasts or #ActiveCasts == 0 then
		return
	end

	local States = {}

	for Index = 1, #ActiveCasts do
		local Cast = ActiveCasts[Index]
		if not Cast or not Cast.Alive or Cast.Paused then continue end

		-- __solverData lives on BulletContext, NOT on the raw Cast object.
		-- Cast.__solverData is always nil — the field does not exist there.
		-- Must go through _CastToBulletContext to reach the BulletContext first,
		-- exactly as StateBatcher.Collect does. Accessing Cast.__solverData
		-- directly was a silent no-op that made every late-join sync send nothing.
		local BulletCtx    = Solver._CastToBulletContext[Cast]
		local ServerCastId = BulletCtx and BulletCtx.__solverData and BulletCtx.__solverData.ServerCastId
		if not ServerCastId then continue end

		local Runtime          = Cast.Runtime
		local ActiveTrajectory = Runtime.ActiveTrajectory
		if not ActiveTrajectory then continue end

		local Elapsed = Runtime.TotalRuntime - ActiveTrajectory.StartTime
		local InitialVelocity = ActiveTrajectory.InitialVelocity
		local Acceleration    = ActiveTrajectory.Acceleration
		local Origin          = ActiveTrajectory.Origin

		local Position = Origin + InitialVelocity * Elapsed + Acceleration * (Elapsed * Elapsed * 0.5)
		local Velocity = InitialVelocity + Acceleration * Elapsed

		States[#States + 1] = {
			CastId   = ServerCastId,
			Position = Position,
			Velocity = Velocity,
		}
	end

	if #States == 0 then
		return
	end

	-- Encode the state batch and send it directly to the joining player.
	-- We do NOT write through OutboundBatcher:WriteStateForAll + Flush here
	-- because Flush iterates ALL player cursors — it would prematurely send
	-- every other player's mid-frame accumulated fire/hit data before the
	-- Heartbeat loop is done writing to them, causing duplicate delivery.
	--
	-- Instead we manually construct the channel-prefixed message and send it
	-- directly via FireClient. This is the ONE permitted exception to the
	-- "Flush is the only FireClient caller" rule — documented here explicitly.
	--
	-- Wire format matches OutboundBatcher.AppendMessage:
	--   channel(u8=1) | msgLen(u16=2) | encodedStateBatch(N bytes)
	--
	-- FrameDelta: there is no Heartbeat DeltaTime available at PlayerAdded time,
	-- so we pass 0. The client clamps FrameDelta to [1/120, 1/10], so 0 becomes
	-- 1/120 — a small but valid correction alpha. Normal Heartbeat batches follow
	-- immediately and restore accurate delta timing.
	local Encoded    = BlinkSchema.EncodeStateBatch(CurrentFrameId, States, #States, 0)
	local MessageLen = buffer_len(Encoded)
	local WrapBuf    = buffer_create(1 + 2 + MessageLen)
	buffer_writeu8(WrapBuf,  0, Constants.CHANNEL_STATE)
	buffer_writeu16(WrapBuf, 1, MessageLen)
	buffer_copy(WrapBuf, 3, Encoded, 0, MessageLen)

	if Player.Parent then
		NetRemote:FireClient(Player, WrapBuf)
	end

	Logger:Debug(string_format(
		"LateJoinHandler: synced %d active bullets to '%s'",
		#States, Player.Name
		))
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(LateJoinHandler, {
	__index = function(_, Key)
		Logger:Warn(string_format("LateJoinHandler: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("LateJoinHandler: write to protected key '%s'", tostring(Key)))
	end,
}))