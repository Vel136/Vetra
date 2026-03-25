--!strict
--StateBatcher.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/StateBatcher.lua
    Collects all active bullet states each frame and packs them into a single
    StateBatch buffer.

    The central performance claim: N active bullets produce exactly 1
    RemoteEvent call per frame to each client, not N. At 60 fps with 50 active
    bullets, naive per-bullet replication would fire 3000 RemoteEvents per
    second per client. StateBatcher reduces that to 60.

    Collect() reads from the Vetra solver's _ActiveCasts. This is the ONE place
    in VetraNet that directly accesses the solver's internal state. All other
    modules go through BulletContext or Vetra signals — never _ActiveCasts
    directly. Centralising access here makes it easy to audit.

    Pre-allocation strategy: _StateBuffer is a table pre-allocated to
    MAX_STATE_BATCH_SIZE. Collect() writes into it by index; Flush() reads
    count entries and clears the array without deallocating the underlying
    storage. No per-frame allocation occurs in the steady state.
]]

local Identity      = "StateBatcher"

local StateBatcher  = {}
StateBatcher.__type = Identity

local StateBatcherMetatable = table.freeze({
	__index = StateBatcher,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core      = script.Parent.Parent.Core
local Types     = script.Parent.Parent.Types
local Transport = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Constants   = require(Types.Constants)
local BlinkSchema = require(Transport.BlinkSchema)
local LogService  = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_create  = table.create
local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function StateBatcher.new(): any
	local self = setmetatable({
		-- Monotonically increasing frame counter. Clients discard batches whose
		-- FrameId is not greater than the last received FrameId, preventing
		-- reordered UDP packets from snapping bullets to stale positions.
		_FrameId = 0,

		-- Pre-allocated state entry array. Written by Collect(), read by Flush().
		-- Using table.create pre-touches the memory, avoiding GC pressure from
		-- repeated allocation and collection on every frame.
		_StateBuffer = table_create(Constants.MAX_STATE_BATCH_SIZE),
		_StateCount  = 0,
	}, StateBatcherMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Read position and velocity for every active cast from the solver and store
-- them into the pre-allocated _StateBuffer.
-- Called once per frame by the server frame loop BEFORE Flush().
--
-- We read Runtime.ActiveTrajectory rather than calling Cast:GetPosition() and
-- Cast:GetVelocity() to avoid the method-dispatch overhead in the collection
-- loop. The kinematic computation is identical — this is an optimisation for
-- the high-bullet-count case where every nanosecond in Collect() matters.
function StateBatcher.Collect(self: any, Solver: any)
	local ActiveCasts = Solver._ActiveCasts
	if not ActiveCasts then
		Logger:Warn("StateBatcher.Collect: Solver has no _ActiveCasts")
		return
	end

	local Count        = 0
	local StateBuffer  = self._StateBuffer
	local MaxBatchSize = Constants.MAX_STATE_BATCH_SIZE

	for Index = 1, #ActiveCasts do
		if Count >= MaxBatchSize then
			Logger:Warn(string_format(
				"StateBatcher.Collect: active cast count exceeds MAX_STATE_BATCH_SIZE (%d) — excess bullets omitted",
				MaxBatchSize
				))
			break
		end

		local Cast = ActiveCasts[Index]
		if not Cast or not Cast.Alive or Cast.Paused then continue end

		-- __solverData lives on the BulletContext, not on the internal Cast object.
		-- Vetra stores the BulletContext → Cast mapping in Solver._CastToBulletContext.
		-- Going through that map is the only correct way to reach __solverData from
		-- a raw Cast reference. Accessing Cast.__solverData directly always returns
		-- nil because the field does not exist on the Cast table.
		-- Casts with no BulletContext (e.g. internally-spawned non-network bullets)
		-- or no ServerCastId are excluded from state sync.
		local BulletCtx    = Solver._CastToBulletContext[Cast]
		local ServerCastId = BulletCtx and BulletCtx.__solverData and BulletCtx.__solverData.ServerCastId
		if not ServerCastId then continue end

		local Runtime          = Cast.Runtime
		local ActiveTrajectory = Runtime.ActiveTrajectory
		if not ActiveTrajectory then continue end

		local Elapsed         = Runtime.TotalRuntime - ActiveTrajectory.StartTime
		local InitialVelocity = ActiveTrajectory.InitialVelocity
		local Acceleration    = ActiveTrajectory.Acceleration
		local Origin          = ActiveTrajectory.Origin

		-- Kinematic position: p = origin + v₀·t + ½·a·t²
		local Position = Origin + InitialVelocity * Elapsed + Acceleration * (Elapsed * Elapsed * 0.5)
		-- Kinematic velocity: v = v₀ + a·t
		local Velocity = InitialVelocity + Acceleration * Elapsed

		Count += 1
		local Entry = StateBuffer[Count]
		if Entry then
			Entry.CastId   = ServerCastId
			Entry.Position = Position
			Entry.Velocity = Velocity
		else
			StateBuffer[Count] = {
				CastId   = ServerCastId,
				Position = Position,
				Velocity = Velocity,
			}
		end
	end

	self._StateCount = Count
end

-- Encode the collected states into a StateBatch buffer and reset the
-- collection for the next frame. Returns the encoded buffer.
-- Called once per frame AFTER Collect().
-- FrameDelta is the Heartbeat DeltaTime for this frame in seconds. It is
-- embedded in the batch header so the client can use it directly as the
-- correction alpha base, avoiding the os.clock() burst-collapse bug.
function StateBatcher.Flush(self: any, FrameDelta: number): buffer
	self._FrameId += 1
	-- Pass _StateCount explicitly so EncodeStateBatch only encodes the entries
	-- written this frame. The buffer is pre-allocated to MAX_STATE_BATCH_SIZE
	-- slots — after Collect() clears unused slots by zeroing their fields
	-- (not nilling them), #self._StateBuffer returns MAX_STATE_BATCH_SIZE, not
	-- the active count. Passing the count directly bypasses the # operator.
	local Encoded = BlinkSchema.EncodeStateBatch(self._FrameId, self._StateBuffer, self._StateCount, FrameDelta)
	self._StateCount = 0
	-- Clear references so GC can collect Vector3 values from the previous frame
	-- without waiting for the pre-allocated table slots to be overwritten.
	for Index = 1, #self._StateBuffer do
		local Entry = self._StateBuffer[Index]
		if Entry then
			Entry.CastId   = 0
			Entry.Position = Vector3.zero
			Entry.Velocity = Vector3.zero
		end
	end
	return Encoded
end

-- Idempotent destroy.
function StateBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._StateBuffer)
	self._StateBuffer = nil
	setmetatable(self, nil)
end

-- Returns the FrameId that the next Flush() call will assign.
-- Used by LateJoinHandler to stamp its one-shot state batch with a coherent
-- FrameId. The joining client uses this ID to initialise its LastFrameId, so
-- the immediately-following regular Heartbeat batch (which will carry this same
-- ID after Flush increments _FrameId) is not discarded as stale.
--
-- Exposing this via a method rather than letting callers read _FrameId directly
-- keeps the internal counter encapsulated and makes the +1 intent explicit.
function StateBatcher.GetNextFrameId(self: any): number
	return self._FrameId + 1
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(StateBatcher, {
	__index = function(_, Key)
		Logger:Warn(string_format("StateBatcher: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("StateBatcher: write to protected key '%s'", tostring(Key)))
	end,
}))