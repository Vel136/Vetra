--!native
--!optimize 2
--!strict

local StepProjectile = {}

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals
local Simulation = script.Parent

local Constants              = require(Core.Constants)
local t                      = require(Core.TypeCheck)
local SimulateCast           = require(Simulation.SimulateCast)
local ResimulateHighFidelity = require(Simulation.ResimulateHighFidelity)
local FrameBudget            = require(Simulation.FrameBudget)
local SpatialPartition       = require(Simulation.SpatialPartition)
local FireHelpers             = require(Signals.FireHelpers)
local Kinematics              = require(Physics.Kinematics)
local HomingPhysics           = require(Physics.Homing)
local Profiler                = require(Vetra.Profiler)

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

local function IsThreadHanging(Thread: thread?): boolean
	return Thread ~= nil and Thread ~= coroutine.running()
end

local ThrottledBuffer: { any } = {}
local ThrottledCount = 0

local TravelWanted = false

local function QueueThrottledTravel(Cast: any)
	if not TravelWanted then return end
	if not Cast.Behavior.FireTravelEvents then return end
	ThrottledCount += 1
	ThrottledBuffer[ThrottledCount] = Cast
end

local function FlushThrottledTravel(Solver: any)
	for Index = 1, ThrottledCount do
		local Cast = ThrottledBuffer[Index]
		ThrottledBuffer[Index] = nil
		if Cast.Alive then
			local Runtime    = Cast.Runtime
			local Trajectory = Runtime.ActiveTrajectory
			local Elapsed = Runtime.TotalRuntime - Trajectory.StartTime
			FireHelpers.FireOnTravel(
				Solver, Cast,
				PositionAtTime(Elapsed, Trajectory.Origin, Trajectory.InitialVelocity, Trajectory.Acceleration),
				VelocityAtTime(Elapsed, Trajectory.InitialVelocity, Trajectory.Acceleration)
			)
		end
	end
	ThrottledCount = 0
end

function StepProjectile.StepProjectile(Solver: any, FrameDelta: number)
	Profiler.MarkFrame()
	FrameBudget.Reset(Solver._FrameBudget)

	local SpatialConfig  = Solver._SpatialConfig
	local SpatialEnabled = SpatialConfig and SpatialConfig.Enabled
	if SpatialEnabled then
		Solver._SpatialFrameCounter += 1
		if Solver._SpatialFrameCounter >= SpatialConfig.UpdateInterval then
			Solver._SpatialFrameCounter = 0
			SpatialPartition.Rebuild(Solver)
		end
	end

	local ActiveCasts = Solver._ActiveCasts
	local ActiveCount = #ActiveCasts
	local LODOrigin   = Solver._LODOrigin

	local Signals = Solver.Signals
	TravelWanted  = Signals.OnTravel:HasListeners() or Signals.OnTravelBatch:HasListeners()

	local SeenDynOcc: { [any]: true }? = nil
	for CastIndex = 1, ActiveCount do
		local Cast = ActiveCasts[CastIndex]
		local DynOcc = Cast and Cast.Alive and Cast.Behavior.DynamicOccupancy
		if DynOcc then
			if not SeenDynOcc then SeenDynOcc = {} end
			if not (SeenDynOcc :: any)[DynOcc] then
				(SeenDynOcc :: any)[DynOcc] = true
				DynOcc:UpdateTransforms()
			end
		end
	end

	for CastIndex = ActiveCount, 1, -1 do
		local Cast = ActiveCasts[CastIndex]
		if not Cast or not Cast.Alive then continue end
		if Cast.Paused then continue end

		local Runtime  = Cast.Runtime
		local Behavior = Cast.Behavior

		Runtime.BouncesThisFrame = 0

		local SuspendActive = false
		if Runtime.SuspendFramesRemaining > 0 then
			Runtime.SuspendFramesRemaining -= 1
			SuspendActive = true
		end
		if Runtime.SuspendTimeRemaining > 0 then
			Runtime.SuspendTimeRemaining -= FrameDelta
			if Runtime.SuspendTimeRemaining < 0 then Runtime.SuspendTimeRemaining = 0 end
			SuspendActive = true
		end

		if SuspendActive then
			Runtime.SuspendDeltaAccumulator += FrameDelta
			if Runtime.SuspendFramesRemaining > 0 or Runtime.SuspendTimeRemaining > 0 then
				QueueThrottledTravel(Cast)
				continue
			end
		end

		local FrameDelta = FrameDelta + Runtime.SuspendDeltaAccumulator
		Runtime.SuspendDeltaAccumulator = 0

		if Behavior.LODDistance > 0 and LODOrigin then
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local ElapsedTime      = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CastPosition     = PositionAtTime(ElapsedTime, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
			local DistanceToOrigin = (CastPosition - LODOrigin).Magnitude
			local ShouldLOD        = DistanceToOrigin > Behavior.LODDistance
			if ShouldLOD ~= Runtime.IsLOD then
				Runtime.IsLOD               = ShouldLOD
				Runtime.LODFrameAccumulator = 0
				Runtime.LODDeltaAccumulator = 0
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			end
		end

		local StepDelta = FrameDelta
		local SpatialTier = Constants.SPATIAL_TIERS.HOT
		if SpatialEnabled and not Runtime.IsLOD then
			local ActiveTrajectory  = Runtime.ActiveTrajectory
			local ElapsedTime       = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CastPosition      = PositionAtTime(
				ElapsedTime,
				ActiveTrajectory.Origin,
				ActiveTrajectory.InitialVelocity,
				ActiveTrajectory.Acceleration
			)
			SpatialTier = SpatialPartition.GetTier(Solver, CastPosition)

			if SpatialTier > Constants.SPATIAL_TIERS.HOT then
				Runtime.SpatialFrameAccumulator = (Runtime.SpatialFrameAccumulator or 0) + 1
				Runtime.SpatialDeltaAccumulator = (Runtime.SpatialDeltaAccumulator or 0) + FrameDelta

				if Runtime.SpatialFrameAccumulator < SpatialTier then
					QueueThrottledTravel(Cast)
					continue
				end

				StepDelta                       = Runtime.SpatialDeltaAccumulator
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			else
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			end
		end

		if HomingPhysics.IsActive(Cast) then
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local ElapsedTime      = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local GatePosition     = PositionAtTime(
				ElapsedTime, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
			)
			local GateVelocity     = VelocityAtTime(
				ElapsedTime, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
			)
			HomingPhysics.EvaluateFrameGate(Cast, Solver, GatePosition, GateVelocity)
		end

		local UseHighFidelity = Behavior.HighFidelitySegmentSize > 0
			and Runtime.CurrentSegmentSize > 0
			and not Runtime.IsLOD
			and SpatialTier == Constants.SPATIAL_TIERS.HOT

		if UseHighFidelity then
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local Provider         = Behavior.TrajectoryPositionProvider
			local PositionAtStart, PositionAtEnd

			if Provider then
				if IsThreadHanging(Runtime.TrajectoryProviderThread) then
					Runtime.TrajectoryProviderThread = nil
					warn("TrajectoryPositionProvider yielded during probe — falling back to kinematic")
					Provider = nil
				end
			end

			if Provider then
				Runtime.TrajectoryProviderThread = coroutine.running()
				PositionAtStart = Provider(Runtime.TotalRuntime)
				Runtime.TotalRuntime += StepDelta

				PositionAtEnd   = Provider(Runtime.TotalRuntime)
				Runtime.TotalRuntime -= StepDelta
				Runtime.TrajectoryProviderThread = nil

				if not PositionAtStart or not PositionAtEnd or not t.Vector3(PositionAtStart) or not t.Vector3(PositionAtEnd) then
					warn("StepProjectile: TrajectoryPositionProvider returned invalid value during probe — falling back to kinematic")
					Provider = nil
				end
			end

			if not Provider then
				local ElapsedAtStart = Runtime.TotalRuntime - ActiveTrajectory.StartTime
				PositionAtStart = PositionAtTime(
					ElapsedAtStart, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
				)
				Runtime.TotalRuntime += StepDelta
				local ElapsedAtEnd = Runtime.TotalRuntime - ActiveTrajectory.StartTime
				PositionAtEnd = PositionAtTime(
					ElapsedAtEnd, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
				)
				Runtime.TotalRuntime -= StepDelta
			end

			local TotalFrameDisplacement = (PositionAtEnd - PositionAtStart).Magnitude

			local SpanStart, SpanEnd
			if not Provider then
				SpanStart = PositionAtStart
				SpanEnd   = PositionAtEnd
			end

			ResimulateHighFidelity.Execute(Solver, Cast, StepDelta, TotalFrameDisplacement, SpanStart, SpanEnd)

		elseif Runtime.IsLOD then
			Runtime.LODFrameAccumulator += 1
			Runtime.LODDeltaAccumulator  = (Runtime.LODDeltaAccumulator or 0) + StepDelta

			if Runtime.LODFrameAccumulator >= Behavior.LODInterval then
				local AccumulatedDelta      = Runtime.LODDeltaAccumulator
				Runtime.LODFrameAccumulator = 0
				Runtime.LODDeltaAccumulator = 0
				SimulateCast.StepProjectile(Solver, Cast, AccumulatedDelta, false)
			else
				QueueThrottledTravel(Cast)
			end
		else
			SimulateCast.StepProjectile(Solver, Cast, StepDelta, false)
		end
	end

	if ThrottledCount > 0 then
		FlushThrottledTravel(Solver)
	end

	if #Solver._TravelBatch > 0 then
		FireHelpers.FlushTravelBatch(Solver)
	end
end

return table.freeze(StepProjectile)
