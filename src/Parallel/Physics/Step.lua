--!strict
--!optimize 2
--!native

local Step     = {}

local ParallelPhysicsFolder = script.Parent
local Vetra                 = ParallelPhysicsFolder.Parent.Parent
local Core                  = Vetra.Core
local Physics               = Vetra.Physics
local Pure                  = Physics.Pure

local Constants      = require(Core.Constants)
local TypeDefinition = require(Vetra.Types)

local Kinematics   = require(Physics.Kinematics)
local PureBounce   = require(Pure.Bounce)
local PureHoming   = require(Pure.Homing)
local PureCoriolis = require(Pure.Coriolis)
local PureTumble   = require(Pure.Tumble)

local DragRecalc = require(ParallelPhysicsFolder.DragRecalc)
local LODSpatial = require(ParallelPhysicsFolder.LODSpatial)
local Profiler   = require(Vetra.Profiler)

local math_abs = math.abs
local os_clock  = os.clock

local math_max = math.max

local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local PARALLEL_EVENT   = Constants.PARALLEL_EVENT
local RAY_ORIGIN_EPSILON = Constants.RAY_ORIGIN_EPSILON

type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot
type ParallelResult    = TypeDefinition.ParallelResult

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

function Step.Step(Snapshot: CastSnapshot, FrameDelta: number): ParallelResult?
	local TrajectoryOrigin          = Snapshot.TrajectoryOrigin
	local TrajectoryInitialVelocity = Snapshot.TrajectoryInitialVelocity
	local TrajectoryAcceleration    = Snapshot.TrajectoryAcceleration
	local TrajectoryStartTime       = Snapshot.TrajectoryStartTime
	local TotalRuntime              = Snapshot.TotalRuntime

	local ElapsedForPosition = TotalRuntime - TrajectoryStartTime
	local CurrentPosition    = PositionAtTime(
		ElapsedForPosition,
		TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration
	)

	local ShouldSkip , StepDelta, LODFrameAccumulator,LODDeltaAccumulator,SpatialFrameAccumulator,SpatialDeltaAccumulator,IsLOD,FiredAccumulatedDelta  = LODSpatial.Resolve(Snapshot, FrameDelta, CurrentPosition)

	if ShouldSkip then
		return {
			Id    = Snapshot.Id,
			Event = "skip",

			TotalRuntime            = TotalRuntime,
			DistanceCovered         = Snapshot.DistanceCovered,
			IsSupersonic            = Snapshot.IsSupersonic,
			LastDragRecalcTime      = Snapshot.LastDragRecalculateTime,
			SpinVector              = Snapshot.SpinVector,
			HomingElapsed           = Snapshot.HomingElapsed,
			HomingDisengaged        = Snapshot.HomingDisengaged,
			HomingAcquired          = Snapshot.HomingAcquired,
			CurrentSegmentSize      = Snapshot.CurrentSegmentSize,
			BouncesThisFrame        = Snapshot.BouncesThisFrame,
			IsLOD                   = IsLOD,
			LODFrameAccumulator     = LODFrameAccumulator,
			LODDeltaAccumulator     = LODDeltaAccumulator,
			SpatialFrameAccumulator = SpatialFrameAccumulator,
			SpatialDeltaAccumulator = SpatialDeltaAccumulator,
		}
	end

	local LastDragRecalcTime                   = Snapshot.LastDragRecalculateTime
	local SpinVector                           = Snapshot.SpinVector
	local OpenedDragTrajectory: TrajectorySegment? = nil

	local Recalculated, NewAcceleration, DragOrigin, DragVelocity, UpdatedSpin =
		DragRecalc.Step(
			Snapshot, TotalRuntime, LastDragRecalcTime,
			{ Origin = TrajectoryOrigin, InitialVelocity = TrajectoryInitialVelocity,
				Acceleration = TrajectoryAcceleration, StartTime = TrajectoryStartTime },
			SpinVector
		)

	if Recalculated then
		LastDragRecalcTime    = TotalRuntime
		SpinVector            = UpdatedSpin
		OpenedDragTrajectory  = {
			Origin          = DragOrigin,
			InitialVelocity = DragVelocity,
			Acceleration    = NewAcceleration,
			StartTime       = TotalRuntime,
		}
		TrajectoryOrigin          = DragOrigin
		TrajectoryInitialVelocity = DragVelocity
		TrajectoryAcceleration    = NewAcceleration
		TrajectoryStartTime       = TotalRuntime
	end

	local ElapsedBefore  = TotalRuntime - TrajectoryStartTime
	TotalRuntime        += StepDelta
	local ElapsedAfter   = TotalRuntime - TrajectoryStartTime

	local LastPosition    = Snapshot.ProvidedLastPosition
		or PositionAtTime(ElapsedBefore, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local CurrentTarget   = Snapshot.ProvidedCurrentPosition
		or PositionAtTime(ElapsedAfter,  TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local CurrentVelocity = Snapshot.ProvidedCurrentVelocity
		or VelocityAtTime(ElapsedAfter,  TrajectoryInitialVelocity, TrajectoryAcceleration)

	local OpenedHomingTrajectory: TrajectorySegment? = nil
	local HomingElapsed    = Snapshot.HomingElapsed
	local HomingDisengaged = Snapshot.HomingDisengaged
	local HomingAcquired   = Snapshot.HomingAcquired

	if Snapshot.HomingTarget and not Snapshot.HomingDisengaged then
		local HomingVelocity, HomingApplied, HomingTrajectory, NewElapsed, NewDisengaged =
			PureHoming.Step(
				Snapshot.HomingDisengaged,
				Snapshot.HomingTarget,
				Snapshot.HomingElapsed,
				Snapshot.HomingMaxDuration,
				Snapshot.HomingStrength,
				CurrentVelocity, LastPosition, StepDelta,
				TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration,
				TrajectoryStartTime, TotalRuntime
			)

		HomingElapsed    = NewElapsed
		HomingDisengaged = NewDisengaged

		if HomingApplied and HomingTrajectory then
			CurrentVelocity           = HomingVelocity
			OpenedHomingTrajectory    = HomingTrajectory
			TrajectoryOrigin          = HomingTrajectory.Origin
			TrajectoryInitialVelocity = HomingTrajectory.InitialVelocity
			TrajectoryAcceleration    = HomingTrajectory.Acceleration
			TrajectoryStartTime       = HomingTrajectory.StartTime
			local NewElapsedAfter     = TotalRuntime - TrajectoryStartTime
			CurrentTarget = PositionAtTime(
				NewElapsedAfter,
				TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration
			)
		end
	end

	local Trajectory = OpenedHomingTrajectory or OpenedDragTrajectory

	local CoriolisOmega = Snapshot.CoriolisOmega
	if CoriolisOmega and CoriolisOmega:Dot(CoriolisOmega) > 0 then
		local CoriolisAccel = PureCoriolis.ComputeAcceleration(CoriolisOmega, CurrentVelocity)
		CurrentVelocity     = CurrentVelocity + CoriolisAccel * StepDelta
		CurrentTarget      += CoriolisAccel * (StepDelta * StepDelta * 0.5)
	end

	local CurrentSpeed = CurrentVelocity.Magnitude
	local IsSupersonic = CurrentSpeed >= SPEED_OF_SOUND

	local IsTumbling      = Snapshot.IsTumbling
	local TumbleBegan     = false
	local TumbleRecovered = false
	if (Snapshot.TumbleSpeedThreshold ~= nil and Snapshot.TumbleSpeedThreshold > 0)
		or Snapshot.TumbleOnPierce == true
	then
		if not IsTumbling then
			if PureTumble.ShouldBeginFromSpeed(CurrentSpeed, Snapshot.TumbleSpeedThreshold) then
				IsTumbling           = true
				Snapshot.IsTumbling  = true
				Snapshot.TumbleRandom = PureTumble.CreateRandom(Snapshot.Id)
				TumbleBegan          = true
			end
		elseif PureTumble.ShouldRecover(CurrentSpeed, Snapshot.TumbleRecoverySpeed) then
			IsTumbling            = false
			Snapshot.IsTumbling   = false
			Snapshot.TumbleRandom = nil
			TumbleRecovered       = true
		end
	end

	local Displacement = CurrentTarget - LastPosition
	if Displacement:Dot(Displacement) < MIN_MAGNITUDE_SQ then
		return {
			Id    = Snapshot.Id,
			Event = PARALLEL_EVENT.Travel,

			TotalRuntime            = TotalRuntime,
			DistanceCovered         = Snapshot.DistanceCovered,
			IsSupersonic            = IsSupersonic,
			LastDragRecalcTime      = LastDragRecalcTime,
			SpinVector              = SpinVector,
			HomingElapsed           = HomingElapsed,
			HomingDisengaged        = HomingDisengaged,
			HomingAcquired          = HomingAcquired,
			CurrentSegmentSize      = Snapshot.CurrentSegmentSize,
			BouncesThisFrame        = Snapshot.BouncesThisFrame,
			IsLOD                   = IsLOD,
			LODFrameAccumulator     = LODFrameAccumulator,
			LODDeltaAccumulator     = LODDeltaAccumulator,
			SpatialFrameAccumulator = SpatialFrameAccumulator,
			SpatialDeltaAccumulator = SpatialDeltaAccumulator,
			FiredAccumulatedDelta   = FiredAccumulatedDelta,
			Trajectory              = Trajectory,
			TravelPosition          = CurrentTarget,
			TravelVelocity          = CurrentVelocity,
			IsTumbling              = IsTumbling,
			TumbleBegan             = TumbleBegan,
			TumbleRecovered         = TumbleRecovered,
		}
	end

	local S = Snapshot.StaticOccupancy
	local D = Snapshot.DynamicOccupancy
	local RaycastResult
	local _pOcc; if Profiler.Enabled then _pOcc = os_clock() end
	local ClearedByGrid = (S ~= nil or D ~= nil)
		and (S == nil or S:SegmentClear(LastPosition, Displacement))
		and (D == nil or D:SegmentClear(LastPosition, Displacement))
	if Profiler.Enabled then
		Profiler.Add(Profiler.Phase.Occupancy, os_clock() - _pOcc)
		if S ~= nil or D ~= nil then
			Profiler.Count(Profiler.Counter.OccCalls)
			if D ~= nil then Profiler.Count(Profiler.Counter.DynCalls) end
		end
	end
	if ClearedByGrid then
		RaycastResult = nil
		if Profiler.Enabled then Profiler.Count(Profiler.Counter.OccSkips) end
	else
		local OriginMagnitude = math_max(
			math_abs(LastPosition.X), math_abs(LastPosition.Y), math_abs(LastPosition.Z)
		)
		local RayOrigin = LastPosition
			- Displacement.Unit * (math_max(OriginMagnitude, 1) * RAY_ORIGIN_EPSILON)
		local RayDisplacement = CurrentTarget - RayOrigin

		local _pRay; if Profiler.Enabled then _pRay = os_clock() end
		RaycastResult = workspace:Raycast(RayOrigin, RayDisplacement, Snapshot.RaycastParams)
		if Profiler.Enabled then Profiler.Add(Profiler.Phase.Raycast, os_clock() - _pRay) end
	end

	local HitPoint        = RaycastResult and RaycastResult.Position or CurrentTarget
	local FrameDistance   = (HitPoint - LastPosition).Magnitude
	local DistanceCovered = Snapshot.DistanceCovered + FrameDistance

	local ResultBase = {
		Id    = Snapshot.Id,
		Event = PARALLEL_EVENT.Travel,

		TotalRuntime            = TotalRuntime,
		DistanceCovered         = DistanceCovered,
		IsSupersonic            = IsSupersonic,
		LastDragRecalcTime      = LastDragRecalcTime,
		SpinVector              = SpinVector,
		HomingElapsed           = HomingElapsed,
		HomingDisengaged        = HomingDisengaged,
		HomingAcquired          = HomingAcquired,
		CurrentSegmentSize      = Snapshot.CurrentSegmentSize,
		BouncesThisFrame        = Snapshot.BouncesThisFrame,
		IsLOD                   = IsLOD,
		LODFrameAccumulator     = LODFrameAccumulator,
		LODDeltaAccumulator     = LODDeltaAccumulator,
		SpatialFrameAccumulator = SpatialFrameAccumulator,
		SpatialDeltaAccumulator = SpatialDeltaAccumulator,
		FiredAccumulatedDelta   = FiredAccumulatedDelta,
		Trajectory              = Trajectory,
		TravelPosition          = CurrentTarget,
		TravelVelocity          = CurrentVelocity,
		IsTumbling              = IsTumbling,
		TumbleBegan             = TumbleBegan,
		TumbleRecovered         = TumbleRecovered,
		VisualizationRayOrigin  = nil,
		RayOrigin               = LastPosition,
	}

	if Snapshot.SixDOFEnabled then
		ResultBase.Orientation     = Snapshot.Orientation
		ResultBase.AngularVelocity = Snapshot.AngularVelocity
		ResultBase.AngleOfAttack   = Snapshot.AngleOfAttack
	end

	if Snapshot.VisualizeCasts then
		ResultBase.VisualizationRayOrigin = LastPosition
	end

	if DistanceCovered >= Snapshot.MaxDistance then
		ResultBase.Event = PARALLEL_EVENT.DistanceEnd
		return ResultBase
	end
	local MaxDisplacement = Snapshot.MaxDisplacement
	if MaxDisplacement > 0 and (HitPoint - Snapshot.SpawnOrigin).Magnitude >= MaxDisplacement then
		ResultBase.Event = PARALLEL_EVENT.DisplacementEnd
		return ResultBase
	end
	if CurrentSpeed < Snapshot.MinSpeed or CurrentSpeed > Snapshot.MaxSpeed then
		ResultBase.Event = PARALLEL_EVENT.SpeedEnd
		return ResultBase
	end

	if not RaycastResult then
		return ResultBase
	end

	local HitNormal   = RaycastResult.Normal
	local HitPosition = RaycastResult.Position
	local HitMaterial = RaycastResult.Material

	ResultBase.HitPosition = HitPosition
	ResultBase.HitNormal   = HitNormal
	ResultBase.HitMaterial = HitMaterial
	ResultBase.HitInstance = RaycastResult.Instance

	local ImpactDot = math_abs(Displacement.Unit:Dot(HitNormal))

	ResultBase.ImpactDot = ImpactDot

	local IsAbovePierceSpeed = CurrentSpeed >= Snapshot.PierceSpeedThreshold
	local IsBelowMaxPierce   = Snapshot.PierceCount < Snapshot.MaxPierceCount
	local MeetsNormalBias    = ImpactDot >= (1.0 - Snapshot.PierceNormalBias)
	local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

	local IsAboveBounceSpeed = CurrentSpeed >= Snapshot.BounceSpeedThreshold
	local IsBelowMaxBounce   = Snapshot.BounceCount < Snapshot.MaxBounces
	local IsBelowFrameBounce = Snapshot.BouncesThisFrame < Snapshot.MaxBouncesPerFrame
	local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

	if EligibleForPierce and Snapshot.HasCanPierceCallback then
		ResultBase.Event = PARALLEL_EVENT.PiercePending
		return ResultBase
	end

	if EligibleForBounce then
		local ReflectedVel  = PureBounce.Reflect(CurrentVelocity, HitNormal)
		local MaterialMult  = Snapshot.MaterialRestitution and (Snapshot.MaterialRestitution[tostring(HitMaterial)] or 1.0) or 1.0
		local BounceRandom = Snapshot.BounceRandom
		if not BounceRandom and Snapshot.NormalPerturbation > 0 then
			BounceRandom          = PureBounce.CreateRandom(Snapshot.Id)
			Snapshot.BounceRandom = BounceRandom
		end
		local FinalVelocity = PureBounce.ApplyRestitution(
			ReflectedVel, HitNormal, Snapshot.Restitution, MaterialMult, Snapshot.NormalPerturbation, BounceRandom
		)

		local BounceCornerState: PureBounce.CornerState = {
			TotalRuntime                = TotalRuntime,
			LastBounceTime              = Snapshot.LastBounceTime,
			BouncePositionHistory       = Snapshot.BouncePositionHistory,
			BouncePositionHead          = Snapshot.BouncePositionHead,
			CornerBounceCount           = Snapshot.CornerBounceCount,
			VelocityDirectionEMA        = Snapshot.VelocityDirectionEMA,
			FirstBouncePosition         = Snapshot.FirstBouncePosition,
			CornerTimeThreshold         = Snapshot.CornerTimeThreshold,
			CornerDisplacementThreshold = Snapshot.CornerDisplacementThreshold,
			CornerEMAAlpha              = Snapshot.CornerEMAAlpha,
			CornerEMAThreshold          = Snapshot.CornerEMAThreshold,
			CornerMinProgressPerBounce  = Snapshot.CornerMinProgressPerBounce,
			CornerPositionHistorySize   = Snapshot.CornerPositionHistorySize or 4,
		}

		local CornerTrap = PureBounce.IsCornerTrap(BounceCornerState, HitPosition, TotalRuntime)

		local NewLastBounceTime, NewBouncePositionHead, NewBouncePositionHistory,
		NewCornerBounceCount, NewVelocityDirectionEMA, NewFirstBouncePosition =
			PureBounce.RecordBounceState(BounceCornerState, HitPosition, FinalVelocity, TotalRuntime)

		ResultBase.PreBounceVelocity       = CurrentVelocity
		ResultBase.ReflectedVelocity       = FinalVelocity
		ResultBase.IsCornerTrap            = CornerTrap
		ResultBase.BounceCount             = Snapshot.BounceCount
		ResultBase.LastBounceTime          = NewLastBounceTime
		ResultBase.BouncePositionHistory   = NewBouncePositionHistory
		ResultBase.BouncePositionHead      = NewBouncePositionHead
		ResultBase.VelocityDirectionEMA    = NewVelocityDirectionEMA
		ResultBase.FirstBouncePosition     = NewFirstBouncePosition
		ResultBase.CornerBounceCount       = NewCornerBounceCount
		ResultBase.BouncesThisFrame        = Snapshot.BouncesThisFrame + 1

		if Snapshot.HasCanBounceCallback then
			ResultBase.Event = "bounce_pending"
		else
			ResultBase.Event = PARALLEL_EVENT.Hit
		end
		return ResultBase
	end

	ResultBase.Event = PARALLEL_EVENT.Hit
	return ResultBase
end

return table.freeze(Step)
