--!native
--!optimize 2
--!strict

-- ─── Step ────────────────────────────────────────────────────────────────────
--[[
    Standard single-raycast parallel step.

    Runs LOD/spatial skip detection, drag+magnus recalculation, homing,
    then fires exactly one raycast for the frame. Returns a ParallelResult
    describing what happened (travel, hit, bounce_pending, pierce_pending, etc.)

    Safe to call from task.desynchronize() — no Instance writes, no signal
    fires, no user callbacks.
]]

local Identity = "Step"
local Step     = {}
Step.__type    = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local ParallelPhysicsFolder = script.Parent
local Vetra                 = ParallelPhysicsFolder.Parent.Parent
local Core                  = Vetra.Core
local Physics               = Vetra.Physics
local Pure                  = Physics.Pure

-- ─── Module References ───────────────────────────────────────────────────────

local LogService     = require(Core.Logger)
local Constants      = require(Core.Constants)
local TypeDefinition = require(Core.TypeDefinition)

local Kinematics   = require(Physics.Kinematics)
local PureBounce   = require(Pure.Bounce)
local PureHoming   = require(Pure.Homing)
local PureCoriolis = require(Pure.Coriolis)  -- [CORIOLIS]

local DragRecalc = require(ParallelPhysicsFolder.DragRecalc)
local LODSpatial = require(ParallelPhysicsFolder.LODSpatial)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_abs = math.abs
local cframe_new = CFrame.new

local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MIN_DOT_SQ       = Constants.MIN_DOT_SQ
local LOOK_AT_FALLBACK = Constants.LOOK_AT_FALLBACK
local PARALLEL_EVENT   = Constants.PARALLEL_EVENT

-- ─── Types ───────────────────────────────────────────────────────────────────

type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot
type ParallelResult    = TypeDefinition.ParallelResult

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

-- ─── Module ──────────────────────────────────────────────────────────────────

function Step.Step(Snapshot: CastSnapshot, FrameDelta: number): ParallelResult?
	-- ── Mutable trajectory state (may be replaced by drag / homing) ──────────
	local TrajectoryOrigin          = Snapshot.TrajectoryOrigin
	local TrajectoryInitialVelocity = Snapshot.TrajectoryInitialVelocity
	local TrajectoryAcceleration    = Snapshot.TrajectoryAcceleration
	local TrajectoryStartTime       = Snapshot.TrajectoryStartTime
	local TotalRuntime              = Snapshot.TotalRuntime

	-- ── LOD / Spatial skip ────────────────────────────────────────────────────
	local ElapsedForPosition = TotalRuntime - TrajectoryStartTime
	local CurrentPosition    = PositionAtTime(
		ElapsedForPosition,
		TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration
	)

	local LOD = LODSpatial.Resolve(Snapshot, FrameDelta, CurrentPosition)

	if LOD.ShouldSkip then
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
			IsLOD                   = LOD.IsLOD,
			LODFrameAccumulator     = LOD.LODFrameAccumulator,
			LODDeltaAccumulator     = LOD.LODDeltaAccumulator,
			SpatialFrameAccumulator = LOD.SpatialFrameAccumulator,
			SpatialDeltaAccumulator = LOD.SpatialDeltaAccumulator,
		}
	end

	-- ── Drag / Magnus recalculation ───────────────────────────────────────────
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

	-- ── Advance runtime ───────────────────────────────────────────────────────
	local ElapsedBefore  = TotalRuntime - TrajectoryStartTime
	TotalRuntime        += LOD.StepDelta
	local ElapsedAfter   = TotalRuntime - TrajectoryStartTime

	-- ── Position / velocity at end of this frame ──────────────────────────────
	local LastPosition    = Snapshot.ProvidedLastPosition
		or PositionAtTime(ElapsedBefore, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local CurrentTarget   = Snapshot.ProvidedCurrentPosition
		or PositionAtTime(ElapsedAfter,  TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local CurrentVelocity = Snapshot.ProvidedCurrentVelocity
		or VelocityAtTime(ElapsedAfter,  TrajectoryInitialVelocity, TrajectoryAcceleration)

	-- ── Homing step (pre-fetched target) ──────────────────────────────────────
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
				CurrentVelocity, LastPosition, LOD.StepDelta,
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

	-- Homing trajectory takes precedence — it opens after drag, so it
	-- incorporates drag's acceleration as its own base.
	local Trajectory = OpenedHomingTrajectory or OpenedDragTrajectory

	-- ── Coriolis deflection ───────────────────────────────────────────────────
	-- Applied after homing (which may have replaced CurrentVelocity) but before
	-- the displacement / raycast direction is computed.
	--
	-- Snapshot.CoriolisOmega is the precomputed Ω vector written by the
	-- Coordinator in AddCast (sourced from Solver._CoriolisOmega). It is zero
	-- when Coriolis is disabled, so the dot-product guard makes this branch
	-- a single multiply + compare on the common path.
	--
	-- PureCoriolis.ComputeAcceleration is safe inside task.desynchronize():
	-- it contains only math operations, no game-service reads or Instance refs.
	local CoriolisOmega = Snapshot.CoriolisOmega
	if CoriolisOmega and CoriolisOmega:Dot(CoriolisOmega) > 0 then
		local CoriolisAccel = PureCoriolis.ComputeAcceleration(CoriolisOmega, CurrentVelocity)
		CurrentVelocity     = CurrentVelocity + CoriolisAccel * LOD.StepDelta
		-- Recompute CurrentTarget so the raycast direction reflects the
		-- Coriolis-nudged velocity rather than the pure kinematic endpoint.
		CurrentTarget       = LastPosition + CurrentVelocity * LOD.StepDelta
	end

	-- ── Speed / supersonic ────────────────────────────────────────────────────
	local CurrentSpeed = CurrentVelocity.Magnitude
	local IsSupersonic = CurrentSpeed >= SPEED_OF_SOUND

	-- ── Displacement / raycast ────────────────────────────────────────────────
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
			IsLOD                   = LOD.IsLOD,
			LODFrameAccumulator     = LOD.LODFrameAccumulator,
			LODDeltaAccumulator     = LOD.LODDeltaAccumulator,
			SpatialFrameAccumulator = LOD.SpatialFrameAccumulator,
			SpatialDeltaAccumulator = LOD.SpatialDeltaAccumulator,
			FiredAccumulatedDelta   = LOD.FiredAccumulatedDelta,
			Trajectory              = Trajectory,
			TravelPosition          = CurrentTarget,
			TravelVelocity          = CurrentVelocity,
		}
	end

	local RaycastResult = workspace:Raycast(LastPosition, Displacement, Snapshot.RaycastParams)

	local HitPoint        = RaycastResult and RaycastResult.Position or CurrentTarget
	local FrameDistance   = (HitPoint - LastPosition).Magnitude
	local DistanceCovered = Snapshot.DistanceCovered + FrameDistance

	local LookDirection = CurrentVelocity:Dot(CurrentVelocity) > MIN_DOT_SQ and CurrentVelocity.Unit or LOOK_AT_FALLBACK

	-- ── Base result (shared across all event types below) ─────────────────────
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
		IsLOD                   = LOD.IsLOD,
		LODFrameAccumulator     = LOD.LODFrameAccumulator,
		LODDeltaAccumulator     = LOD.LODDeltaAccumulator,
		SpatialFrameAccumulator = LOD.SpatialFrameAccumulator,
		SpatialDeltaAccumulator = LOD.SpatialDeltaAccumulator,
		FiredAccumulatedDelta   = LOD.FiredAccumulatedDelta,
		Trajectory              = Trajectory,
		TravelPosition          = CurrentTarget,
		TravelVelocity          = CurrentVelocity,
		CosmeticCFrame          = cframe_new(HitPoint, HitPoint + LookDirection),
		VisualizationRayOrigin  = nil,
		RayOrigin               = LastPosition,
	}

	if Snapshot.VisualizeCasts then
		ResultBase.VisualizationRayOrigin = LastPosition
	end

	-- ── No hit: travel ────────────────────────────────────────────────────────
	if not RaycastResult then
		if DistanceCovered >= Snapshot.MaxDistance then
			ResultBase.Event = PARALLEL_EVENT.DistanceEnd
			return ResultBase
		end
		if CurrentSpeed < Snapshot.MinSpeed then
			ResultBase.Event = PARALLEL_EVENT.SpeedEnd
			return ResultBase
		end
		if CurrentSpeed > Snapshot.MaxSpeed then
			ResultBase.Event = PARALLEL_EVENT.SpeedEnd
			return ResultBase
		end
		return ResultBase
	end

	-- ── Hit detected ──────────────────────────────────────────────────────────
	local HitNormal   = RaycastResult.Normal
	local HitPosition = RaycastResult.Position
	local HitMaterial = RaycastResult.Material

	ResultBase.HitPosition = HitPosition
	ResultBase.HitNormal   = HitNormal
	ResultBase.HitMaterial = HitMaterial
	-- HitInstance intentionally omitted — Instances cannot cross Actor boundaries
	-- via SharedTable. Coordinator re-raycasts using RayOrigin + HitPosition.

	local ImpactDot = math_abs(Displacement.Unit:Dot(HitNormal))

	local IsAbovePierceSpeed = CurrentSpeed >= Snapshot.PierceSpeedThreshold
	local IsBelowMaxPierce   = Snapshot.PierceCount < Snapshot.MaxPierceCount
	local MeetsNormalBias    = ImpactDot >= (1.0 - Snapshot.PierceNormalBias)
	local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

	local IsAboveBounceSpeed = CurrentSpeed >= Snapshot.BounceSpeedThreshold
	local IsBelowMaxBounce   = Snapshot.BounceCount < Snapshot.MaxBounces
	local IsBelowFrameBounce = Snapshot.BouncesThisFrame < Snapshot.MaxBouncesPerFrame
	local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

	-- Pierce takes priority over bounce.
	if EligibleForPierce and Snapshot.HasCanPierceCallback then
		ResultBase.Event = PARALLEL_EVENT.PiercePending
		return ResultBase
	end

	if EligibleForBounce then
		local ReflectedVel  = PureBounce.Reflect(CurrentVelocity, HitNormal)
		local MaterialMult  = Snapshot.MaterialRestitution and (Snapshot.MaterialRestitution[tostring(HitMaterial)] or 1.0) or 1.0
		local FinalVelocity = PureBounce.ApplyRestitution(
			ReflectedVel, Snapshot.Restitution, MaterialMult, Snapshot.NormalPerturbation
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
			CornerPositionHistorySize   = 4,
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

		-- No callback: serial never bounces without CanBounceFunction — emit Hit.
		-- Callback present: defer to main thread for the user Lua call.
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

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Step)