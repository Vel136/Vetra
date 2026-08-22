--!strict
--!optimize 2
--!native

local StateBatcher  = {}
StateBatcher.__index = StateBatcher

local Core      = script.Parent.Parent.Core
local Types     = script.Parent.Parent.Types
local Transport = script.Parent

local Constants   = require(Types.Constants)
local BlinkSchema = require(Transport.BlinkSchema)

local table_create = table.create
local table_clear  = table.clear

function StateBatcher.new(): any
	return setmetatable({
		_FrameId     = 0,
		_StateBuffer = table_create(Constants.MAX_STATE_BATCH_SIZE),
		_StateCount  = 0,
	}, StateBatcher)
end

function StateBatcher.Collect(self: any, Solver: any)
	local ActiveCasts = Solver._ActiveCasts
	if not ActiveCasts then
		warn("StateBatcher.Collect: Solver has no _ActiveCasts")
		return
	end

	local Count        = 0
	local StateBuffer  = self._StateBuffer
	local MaxBatchSize = Constants.MAX_STATE_BATCH_SIZE

	for Index = 1, #ActiveCasts do
		if Count >= MaxBatchSize then
			warn(string.format("StateBatcher.Collect: active cast count exceeds MAX_STATE_BATCH_SIZE (%d) — excess omitted", MaxBatchSize))
			break
		end

		local Cast = ActiveCasts[Index]
		if not Cast or not Cast.Alive or Cast.Paused then continue end

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

		local Position = Origin + InitialVelocity * Elapsed + Acceleration * (Elapsed * Elapsed * 0.5)
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

function StateBatcher.Flush(self: any, FrameDelta: number): buffer
	self._FrameId += 1
	local Encoded = BlinkSchema.EncodeStateBatch(self._FrameId, self._StateBuffer, self._StateCount, FrameDelta)
	self._StateCount = 0
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

function StateBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._StateBuffer)
	self._StateBuffer = nil
	setmetatable(self, nil)
end

function StateBatcher.GetNextFrameId(self: any): number
	return self._FrameId + 1
end

return table.freeze(StateBatcher)
