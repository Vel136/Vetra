--!strict
--Client.lua
--!native
--!optimize 2

local Identity = "Client"

local Client   = {}
Client.__type  = Identity

local ClientMetatable = table.freeze({
	__index = Client,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core           = script.Parent.Core
local Transport      = script.Parent.Transport
local Reconciliation = script.Parent.Reconciliation
local Vetra          = script.Parent.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── Module References ───────────────────────────────────────────────────────

local AuthorityModule  = require(Core.Authority)
local Config           = require(Core.Config)
local LogService       = require(Core.Logger)
local FireChannel      = require(Transport.FireChannel)
local BlinkSchema      = require(Transport.BlinkSchema)
local CosmeticTracker  = require(Reconciliation.CosmeticTracker)
local DriftCorrector   = require(Reconciliation.DriftCorrector)
local LatencyBuffer    = require(Reconciliation.LatencyBuffer)
local BulletContext    = require(Vetra.Core.BulletContext)
local Constants        = require(script.Parent.Types.Constants)

AuthorityModule.AssertClient("VetraNet.Client")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_clamp    = math.clamp
local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local FOLDER_NAME   = Constants.NETWORK_FOLDER_NAME
local REMOTE_NET    = Constants.REMOTE_NET
local CHANNEL_FIRE  = Constants.CHANNEL_FIRE
local CHANNEL_HIT   = Constants.CHANNEL_HIT
local CHANNEL_STATE = Constants.CHANNEL_STATE

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function GetOrCreateRemotes(): any
	local Folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 10)
	if not Folder then
		error("[VetraNet] ReplicatedStorage." .. FOLDER_NAME .. " not found within 10 seconds — ensure the server requires VetraNet before the client.", 2)
	end
	return { Net = Folder:WaitForChild(REMOTE_NET, 5) :: RemoteEvent }
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    Create the client-side VetraNet handle.

    Parameters:
      Solver           — The client-side Vetra Factory instance.
      BehaviorRegistry — A shared BehaviorRegistry.new() instance pre-populated
                         with the same behaviors in the same order as the server.
      NetworkConfig_   — Optional NetworkConfig table.
      OnCosmeticFire   — Optional VeSignal fired after a cosmetic bullet spawns.
      OnCosmeticHit    — Optional VeSignal fired after a cosmetic bullet terminates.

    Returns a ClientNetwork handle with:
      :Fire(origin, direction, speed, behaviorName) — Send a fire request.
      :Destroy()                                    — Clean up all connections.
]]
function Client.new(
	Solver            : any,
	BehaviorRegistry_ : any,
	NetworkConfig_    : any?,
	OnCosmeticFire    : any?,
	OnCosmeticHit     : any?
): any
	local ResolvedConfig = Config.Resolve(NetworkConfig_)
	local Remotes        = GetOrCreateRemotes()

	local Connections: { RBXScriptConnection } = {}

	local Tracker   = CosmeticTracker.new()
	local Corrector = DriftCorrector.new(ResolvedConfig)

	local LastFrameId = 0

	-- ── Fire handler (called from decoder loop) ──────────────────────────────
	local function HandleFire(Payload: any)
		local Behavior = BehaviorRegistry_:Get(Payload.BehaviorHash)
		if not Behavior then
			Logger:Warn(string_format(
				"Client: cannot spawn cosmetic — unknown behavior hash %d",
				Payload.BehaviorHash
			))
			return
		end

		-- Payload.CastId is the server-authoritative cast ID for this bullet.
		-- Payload.LocalCastId (if > 0) is the client-local ID the shooter embedded
		-- when they fired. When both are present, the shooter's cosmetic is already
		-- tracked under LocalCastId — we must re-register it under ServerCastId so
		-- that incoming hit confirmations and state batches (which carry ServerCastId)
		-- can find it in CosmeticTracker.
		--
		-- When LocalCastId is 0 or absent, this is a replication for another player's
		-- bullet: spawn a new cosmetic and register it normally.
		local ServerCastId = Payload.CastId
		local LocalCastId  = Payload.LocalCastId or 0

		if LocalCastId > 0 then
			-- This is the echo of the shooter's own fire. The cosmetic may or may not
			-- have spawned yet depending on LatencyBuffer. Migrate the tracker entry
			-- from LocalCastId → ServerCastId. If the cosmetic hasn't spawned yet
			-- (delay path), it will be registered under ServerCastId when SpawnLocal
			-- completes — we just update the key now so any hits that arrive before
			-- the spawn are handled correctly after it fires.
			local ExistingCast = Tracker:GetLocal(LocalCastId)
			if ExistingCast then
				Tracker:Unregister(LocalCastId)
				Tracker:Register(ServerCastId, ExistingCast)
			end
			-- No new cosmetic to spawn — the shooter's local client already did that.
			return
		end

		local Delay
		if ResolvedConfig.LatencyBuffer ~= 0 then
			Delay = ResolvedConfig.LatencyBuffer
		else
			Delay = LatencyBuffer.GetDelay()
		end

		local function SpawnCosmetic()
			if not Solver or not Solver.Fire then return end
			local FireContext = BulletContext.new({
				Origin    = Payload.Origin,
				Direction = Payload.Direction,
				Speed     = Payload.Speed,
				SolverData = { ServerCastId = ServerCastId },
			})
			local Context = Solver:Fire(FireContext, Behavior)
			if not Context then
				Logger:Warn(string_format(
					"Client: client solver Fire() returned nil for castId %d",
					ServerCastId
				))
				return
			end
			Tracker:Register(ServerCastId, Context)
			if OnCosmeticFire then
				OnCosmeticFire:Fire(ServerCastId, Context)
			end
		end

		if Delay > 0.001 then
			task.delay(Delay, SpawnCosmetic)
		else
			SpawnCosmetic()
		end
	end

	-- ── Hit handler (called from decoder loop) ───────────────────────────────
	local function HandleHit(HitPayload: any)
		local LocalCast = Tracker:GetLocal(HitPayload.CastId)
		-- Cast.Alive is a field on VetraCast, not a method.
		if LocalCast and LocalCast.Alive then
			if LocalCast.SetPosition then
				LocalCast:SetPosition(HitPayload.Position)
			end
			LocalCast:Terminate()
			Tracker:Unregister(HitPayload.CastId)
			-- Fire OnCosmeticHit for any tracked cosmetic — including the shooter's
			-- own bullet, which is now correctly registered under ServerCastId via
			-- the HandleFire echo path. Previously this branch was unreachable for
			-- the shooter because their cosmetic was never registered in the tracker.
			if OnCosmeticHit then
				OnCosmeticHit:Fire(HitPayload.CastId, HitPayload)
			end
		else
			-- No tracked cosmetic — cosmetic already terminated locally before
			-- the server confirmation arrived. Unregister defensively.
			Tracker:Unregister(HitPayload.CastId)
		end
	end

	-- ── State handler (called from decoder loop) ──────────────────────────────
	local function HandleState(Batch: any)
		if Batch.FrameId <= LastFrameId then return end
		LastFrameId = Batch.FrameId

		-- Use the server's actual Heartbeat DeltaTime embedded in the batch header.
		-- Using os.clock() wall-time diff here is wrong: if two batches arrive in
		-- the same client frame (network burst or late delivery), DeltaTime collapses
		-- to near-zero and is clamped to 1/120, making correction alpha ~0 and
		-- barely closing the gap. The server DeltaTime reflects the real simulation
		-- step regardless of when the packet is received on the client.
		-- Clamp to [1/120, 1/10] to guard against stale/malformed values.
		local DeltaTime = math_clamp(Batch.FrameDelta, 1/120, 1/10)

		for _, Entry in Batch.States do
			local LocalCast = Tracker:GetLocal(Entry.CastId)
			-- Cast.Alive is a field, not a method.
			if not LocalCast or not LocalCast.Alive then continue end
			if Corrector:Evaluate(LocalCast, Entry.Position) then
				Corrector:Correct(LocalCast, Entry.Position, Entry.Velocity, DeltaTime)
			end
		end
	end

	-- ── Single OnClientEvent decoder loop ────────────────────────────────────
	-- V0.1.2: all server→client messages arrive on one remote in a single
	-- batched buffer. We read a 1-byte channel prefix, then a u16 message
	-- length, then dispatch the slice to the correct decoder. This mirrors
	-- Packet's "while not Ended()" model and eliminates two extra remotes.
	Connections[#Connections + 1] = Remotes.Net.OnClientEvent:Connect(function(RawBuf: any)
		if typeof(RawBuf) ~= "buffer" then return end

		local BufLen = buffer.len(RawBuf)
		local Offset = 0

		while Offset < BufLen do
			-- Need at least 3 bytes: channel(1) + length(2)
			if Offset + 3 > BufLen then break end

			local Channel = buffer.readu8(RawBuf, Offset)   Offset += 1
			local MsgLen  = buffer.readu16(RawBuf, Offset)  Offset += 2

			if Offset + MsgLen > BufLen then
				Logger:Warn(string_format(
					"Client: message length %d overflows buffer at offset %d — aborting decode",
					MsgLen, Offset
				))
				break
			end

			-- Extract the message slice into its own buffer for the decoder.
			local MsgBuf = buffer.create(MsgLen)
			buffer.copy(MsgBuf, 0, RawBuf, Offset, MsgLen)
			Offset += MsgLen

			if Channel == CHANNEL_FIRE then
				local Success, Result = pcall(BlinkSchema.DecodeFire, MsgBuf)
				if Success then
					HandleFire(Result)
				else
					Logger:Warn(string_format("Client: DecodeFire failed at offset %d: %s", Offset, tostring(Result)))
				end
			elseif Channel == CHANNEL_HIT then
				local Success, Result = pcall(BlinkSchema.DecodeHit, MsgBuf)
				if Success then
					HandleHit(Result)
				else
					Logger:Warn(string_format("Client: DecodeHit failed at offset %d: %s", Offset, tostring(Result)))
				end
			elseif Channel == CHANNEL_STATE then
				local Success, Result = pcall(BlinkSchema.DecodeStateBatch, MsgBuf)
				if Success then
					HandleState(Result)
				else
					Logger:Warn(string_format("Client: DecodeStateBatch failed at offset %d: %s", Offset, tostring(Result)))
				end
			else
				Logger:Warn(string_format("Client: unknown channel id %d — skipping message", Channel))
			end
		end
	end)

	-- ── Solver.OnTerminated: clean up tracker entry ──────────────────────────
	Connections[#Connections + 1] = Solver.Signals.OnTerminated:Connect(function(Context: any)
		local ServerCastId = Context.__solverData and Context.__solverData.ServerCastId
		if ServerCastId then
			Tracker:Unregister(ServerCastId)
		end
	end)

	local self = setmetatable({
		_Solver           = Solver,
		_BehaviorRegistry = BehaviorRegistry_,
		_ResolvedConfig   = ResolvedConfig,
		_Net              = Remotes.Net,
		_Connections      = Connections,
		_Tracker          = Tracker,
		_Corrector        = Corrector,
		_Destroyed        = false,
		-- Monotonic local cast ID counter. Used to tag the shooter's own
		-- cosmetic bullet so it can be registered in CosmeticTracker and
		-- correctly unregistered when the server hit confirmation arrives.
		-- Starts at 1; 0 is reserved as "invalid" (matches UNKNOWN_BEHAVIOR_HASH
		-- convention). This counter is LOCAL ONLY — the server generates its own
		-- authoritative ServerCastId. We send this value in the fire payload so
		-- the server can echo it back in the fire replication, letting the client
		-- correlate its own cosmetic with the server-confirmed bullet.
		_NextLocalCastId  = 1,
	}, ClientMetatable)

	Logger:Info("VetraNet Client initialised")
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

--[[
    Serialize and send a fire request to the server.

    Parameters:
      Context      — BulletContext created by the caller. Origin, Direction, Speed,
                     and RaycastParams are read from it. VetraNet stamps its internal
                     __solverData onto the context before passing it to the local solver.
      BehaviorName — The registered behavior name string.
]]
function Client:Fire(Context: BulletContext, BehaviorName: string)
	if self._Destroyed then
		Logger:Warn("Client.Fire: called on destroyed handle — ignoring")
		return
	end

	local BehaviorHash = self._BehaviorRegistry:GetHash(BehaviorName)
	if BehaviorHash == 0 then
		Logger:Warn(string_format(
			"Client.Fire: behavior '%s' is not registered — request not sent",
			BehaviorName
		))
		return
	end

	-- Assign a local cast ID for this fire event. This ID is sent in the
	-- payload and echoed back by the server in the fire replication so the
	-- client can register the shooter's own cosmetic in CosmeticTracker.
	-- Without this, the shooter's local bullet is permanently unlinked from
	-- the server bullet: hit confirmations arrive with a ServerCastId the
	-- tracker doesn't know about, so OnCosmeticHit never fires for the shooter,
	-- and drift correction never applies to their own bullets.
	local LocalCastId       = self._NextLocalCastId
	self._NextLocalCastId   = LocalCastId + 1

	local Behavior = self._BehaviorRegistry:Get(BehaviorHash)
	if Behavior and self._Solver and self._Solver.Fire then

		local TimeDelay = self._ResolvedConfig.LatencyBuffer ~= 0 and self._ResolvedConfig.LatencyBuffer or LatencyBuffer.GetDelay()

		local Tracker = self._Tracker

		local function SpawnLocal()
			if self._Destroyed then return end
			-- Stamp networking metadata onto the caller's context before firing.
			-- Embed LocalCastId so the server can echo it back in the replicated
			-- fire event. The client decoder uses ServerCastId to re-register this
			-- cosmetic under the correct key when the echo arrives.
			Context.__solverData = { IsLocalCosmetic = true, LocalCastId = LocalCastId }
			local LocalCast = self._Solver:Fire(Context, Behavior)

			-- Register immediately so the tracker can match the server's echo.
			-- The server echoes ServerCastId (not LocalCastId) in the replication,
			-- so we register under LocalCastId here and the decoder will re-register
			-- under ServerCastId when the echo arrives.
			if LocalCast and Tracker then
				Tracker:Register(LocalCastId, LocalCast)
			end
		end

		if TimeDelay > 0.001 then
			task.delay(TimeDelay, SpawnLocal)
		else
			SpawnLocal()
		end
	end

	local Timestamp = workspace:GetServerTimeNow()
	FireChannel.SendFire(
		self._Net,
		Context.Origin,
		Context.Direction,
		Context.Speed,
		BehaviorHash,
		LocalCastId,
		Timestamp
	)
end

function Client:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	for _, Connection in self._Connections do
		Connection:Disconnect()
	end

	self._Tracker:Destroy()
	self._Corrector:Destroy()
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Client)
