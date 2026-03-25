--!strict
--ClientHooks.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Hooks/ClientHooks.lua
    Wires the client-side reconciliation and cosmetic bullet pipeline.

    Manages three incoming message types dispatched from the single OnClientEvent
    decoder loop (V0.1.2+). Each message in the batched buffer has a 1-byte
    channel prefix that routes it here:
      1. CHANNEL_FIRE  → spawn cosmetic bullet on local solver, or migrate
                         tracker entry when the shooter's own echo arrives
      2. CHANNEL_HIT   → terminate cosmetic bullet + fire OnCosmeticHit
      3. CHANNEL_STATE → per-frame drift correction via DriftCorrector

    ClientHooks also owns the LatencyBuffer timing for cosmetic spawns.
    When a replicated fire event arrives, the spawn is delayed by one half-RTT
    so the cosmetic bullet arrives at its target at approximately the same time
    as the server bullet.

    CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity    = "ClientHooks"

local ClientHooks = {}
ClientHooks.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local VetraNet = script.Parent.Parent
local Vetra    = VetraNet.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Authority       = require(VetraNet.Core.Authority)

Authority.AssertClient("ClientHooks")

local LogService      = require(VetraNet.Core.Logger)
local BlinkSchema     = require(VetraNet.Transport.BlinkSchema)
local CosmeticTracker = require(VetraNet.Reconciliation.CosmeticTracker)
local DriftCorrector  = require(VetraNet.Reconciliation.DriftCorrector)
local LatencyBuffer   = require(VetraNet.Reconciliation.LatencyBuffer)
local BulletContext   = require(Vetra.Core.BulletContext)
local Constants       = require(VetraNet.Types.Constants)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_clamp    = math.clamp
local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Cached at module level so the decoder loop does not re-read them on every
-- incoming packet.
local CHANNEL_FIRE  = Constants.CHANNEL_FIRE
local CHANNEL_HIT   = Constants.CHANNEL_HIT
local CHANNEL_STATE = Constants.CHANNEL_STATE

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    Bind all client-side hooks.

    Parameters:
      Solver           — The client-side Vetra Factory instance.
      BehaviorRegistry — Transport.BehaviorRegistry instance (shared with server).
      NetRemote        — The single VetraNet RemoteEvent (Remotes.Net).
      ResolvedConfig   — Core.Config.Resolve() output.
      OnCosmeticFire   — Optional signal fired after a cosmetic bullet is spawned.
      OnCosmeticHit    — Optional signal fired after a cosmetic bullet is terminated.

    Returns a Connections table of all RBXScriptConnections.
]]
function ClientHooks.Bind(
	Solver           : any,
	BehaviorRegistry : any,
	NetRemote        : RemoteEvent,
	ResolvedConfig   : any,
	OnCosmeticFire   : any?,
	OnCosmeticHit    : any?
): { RBXScriptConnection }
	local Connections : { RBXScriptConnection } = {}

	local Tracker   = CosmeticTracker.new()
	local Corrector = DriftCorrector.new(ResolvedConfig)

	local LastFrameId   = 0

	-- ── Fire handler (called from decoder loop) ──────────────────────────────
	local function HandleFire(Payload: any)
		local Behavior = BehaviorRegistry:Get(Payload.BehaviorHash)
		if not Behavior then
			Logger:Warn(string_format(
				"ClientHooks: cannot spawn cosmetic — unknown behavior hash %d",
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
					"ClientHooks: client solver Fire() returned nil for castId %d",
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
	Connections[#Connections + 1] = NetRemote.OnClientEvent:Connect(function(RawBuf: any)
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
					"ClientHooks: message length %d overflows buffer at offset %d — aborting decode",
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
					Logger:Warn(string_format("ClientHooks: DecodeFire failed at offset %d: %s", Offset, tostring(Result)))
				end
			elseif Channel == CHANNEL_HIT then
				local Success, Result = pcall(BlinkSchema.DecodeHit, MsgBuf)
				if Success then
					HandleHit(Result)
				else
					Logger:Warn(string_format("ClientHooks: DecodeHit failed at offset %d: %s", Offset, tostring(Result)))
				end
			elseif Channel == CHANNEL_STATE then
				local Success, Result = pcall(BlinkSchema.DecodeStateBatch, MsgBuf)
				if Success then
					HandleState(Result)
				else
					Logger:Warn(string_format("ClientHooks: DecodeStateBatch failed at offset %d: %s", Offset, tostring(Result)))
				end
			else
				Logger:Warn(string_format("ClientHooks: unknown channel id %d — skipping message", Channel))
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

	Connections._Tracker   = Tracker
	Connections._Corrector = Corrector

	return Connections
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(ClientHooks, {
	__index = function(_, Key)
		Logger:Warn(string_format("ClientHooks: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("ClientHooks: write to protected key '%s'", tostring(Key)))
	end,
}))