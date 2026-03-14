--!native
--!optimize 2
--!strict

-- ─── StepHighFidelity ────────────────────────────────────────────────────────
--[[
    Sub-segment resimulation loop, parallel-safe.

    Subdivides StepDelta into N sub-segments based on CurrentSegmentSize,
    raycasting each one. Mirrors ResimulateHighFidelity but operates entirely
    on snapshot data so it can run inside task.desynchronize().

    Inline bounce (no CanBounceFunction):
        Reflects velocity, opens a new local trajectory, continues the loop.
        Zero main-thread round-trips for the common no-callback bounce path.

    Callback-required events (HasCanPierceCallback / HasCanBounceCallback):
        Returns the pending event early with RemainingResimDelta set to the
        un-stepped sub-segment time. ActorWorker stores this on suspend; on
        ResumeCast the Coordinator sends the value back and the Actor calls
        StepHighFidelity again with the remaining delta.

    Budget:
        os_clock() checked at the top of each sub-segment iteration.
        When exceeded, CurrentSegmentSize is grown and the loop exits early.
]]

local Identity         = "StepHighFidelity"
local StepHighFidelity = {}
StepHighFidelity.__type = Identity

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

local Kinematics = require(Physics.Kinematics)
local PureBounce = require(Pure.Bounce)
local PureHoming = require(Pure.Homing)

local DragRecalc = require(ParallelPhysicsFolder.DragRecalc)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_abs   = math.abs
local math_floor = math.floor
local math_clamp = math.clamp
local math_min   = math.min
local math_max   = math.max
local os_clock   = os.clock

local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MAX_SUBSEGMENTS  = Constants.MAX_SUBSEGMENTS
local PARALLEL_EVENT   = Constants.PARALLEL_EVENT

-- ─── Types ───────────────────────────────────────────────────────────────────

type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot
type ParallelResult    = TypeDefinition.ParallelResult

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

-- ─── Module ──────────────────────────────────────────────────────────────────

function StepHighFidelity.StepHighFidelity(
	Snapshot:               CastSnapshot,
	StepDelta:              number,
	IsLOD:                  boolean,
	LODFrameAccumulator:    number,
	LODDeltaAccumulator:    number,
	SpatialFrameAccumulator: number,
	SpatialDeltaAccumulator: number
): ParallelResult?
	-- ── Mutable local state ───────────────────────────────────────────────────
	local TrajectoryOrigin          = Snapshot.TrajectoryOrigin
	local TrajectoryInitialVelocity = Snapshot.TrajectoryInitialVelocity
	local TrajectoryAcceleration    = Snapshot.TrajectoryAcceleration
	local TrajectoryStartTime       = Snapshot.TrajectoryStartTime
	local TotalRuntime              = Snapshot.TotalRuntime
	local DistanceCovered           = Snapshot.DistanceCovered
	local SpinVector                = Snapshot.SpinVector
	local LastDragRecalculateTime   = Snapshot.LastDragRecalculateTime
	local HomingElapsed             = Snapshot.HomingElapsed
	local HomingDisengaged          = Snapshot.HomingDisengaged
	local HomingAcquired            = Snapshot.HomingAcquired
	local BounceCount               = Snapshot.BounceCount
	local BouncesThisFrame          = Snapshot.BouncesThisFrame
	local PierceCount               = Snapshot.PierceCount
	local IsSupersonic              = Snapshot.IsSupersonic
	local CurrentSegmentSize        = Snapshot.CurrentSegmentSize
	local LatestTrajectory: TrajectorySegment? = nil

	-- Mutable corner-trap tracking — initialised from snapshot then updated
	-- after each inline bounce within the sub-segment loop.
	local OriginalHistory = Snapshot.BouncePositionHistory
	local BounceHistory: { Vector3 } = {}
	for Index, Value in OriginalHistory do BounceHistory[Index] = Value end

	local BounceState: PureBounce.CornerState = {
		TotalRuntime                = Snapshot.TotalRuntime,
		LastBounceTime              = Snapshot.LastBounceTime,
		BouncePositionHistory       = BounceHistory,
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

	-- ── Mutable result base ───────────────────────────────────────────────────
	-- Maintained in-place; SyncResult() flushes current locals into it before
	-- each return. Avoids repeating every common field at every early-exit point.
	local Result = {
		Id                      = Snapshot.Id,
		Event                   = "travel",
		TotalRuntime            = TotalRuntime,
		DistanceCovered         = DistanceCovered,
		IsSupersonic            = IsSupersonic,
		LastDragRecalcTime      = LastDragRecalculateTime,
		SpinVector              = SpinVector,
		HomingElapsed           = HomingElapsed,
		HomingDisengaged        = HomingDisengaged,
		HomingAcquired          = HomingAcquired,
		CurrentSegmentSize      = CurrentSegmentSize,
		BouncesThisFrame        = BouncesThisFrame,
		IsLOD                   = IsLOD,
		LODFrameAccumulator     = LODFrameAccumulator,
		LODDeltaAccumulator     = LODDeltaAccumulator,
		SpatialFrameAccumulator = SpatialFrameAccumulator,
		SpatialDeltaAccumulator = SpatialDeltaAccumulator,
		Trajectory              = nil :: TrajectorySegment?,
	}

	local function SyncResult()
		Result.TotalRuntime       = TotalRuntime
		Result.DistanceCovered    = DistanceCovered
		Result.IsSupersonic       = IsSupersonic
		Result.LastDragRecalcTime = LastDragRecalculateTime
		Result.SpinVector         = SpinVector
		Result.HomingElapsed      = HomingElapsed
		Result.HomingDisengaged   = HomingDisengaged
		Result.HomingAcquired     = HomingAcquired
		Result.CurrentSegmentSize = CurrentSegmentSize
		Result.BouncesThisFrame   = BouncesThisFrame
		Result.Trajectory         = LatestTrajectory
	end

	local function OpenTrajectorySegment(Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3)
		TrajectoryOrigin          = Origin
		TrajectoryInitialVelocity = InitialVelocity
		TrajectoryAcceleration    = Acceleration
		TrajectoryStartTime       = TotalRuntime
		LatestTrajectory = {
			Origin          = Origin,
			InitialVelocity = InitialVelocity,
			Acceleration    = Acceleration,
			StartTime       = TotalRuntime,
		}
	end

	-- ── Sub-segment count ─────────────────────────────────────────────────────
	local ElapsedStart      = TotalRuntime - TrajectoryStartTime
	local PositionStart     = PositionAtTime(ElapsedStart, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local PositionEnd       = PositionAtTime(ElapsedStart + StepDelta, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local FrameDisplacement = (PositionEnd - PositionStart).Magnitude

	local SubSegmentCount = math_clamp(math_floor(FrameDisplacement / CurrentSegmentSize), 1, MAX_SUBSEGMENTS)
	if SubSegmentCount >= MAX_SUBSEGMENTS then
		CurrentSegmentSize = math_min(
			CurrentSegmentSize * Snapshot.AdaptiveScaleFactor * 2,
			Snapshot.MaxDistance
		)
	end
	local SubSegmentDelta = StepDelta / SubSegmentCount
	local BudgetStartTime = os_clock()

	-- ── Sub-segment loop ──────────────────────────────────────────────────────
	for SubIndex = 1, SubSegmentCount do

		-- Budget check
		if (os_clock() - BudgetStartTime) * 1000 > Snapshot.HighFidelityFrameBudget then
			CurrentSegmentSize = math_min(
				CurrentSegmentSize * Snapshot.AdaptiveScaleFactor,
				Snapshot.MaxDistance
			)
			break
		end

		-- Drag / Magnus / GyroDrift recalc
		local Recalculated, NewAcceleration, DragOrigin, DragVelocity, UpdatedSpin =
			DragRecalc.Step(
				Snapshot, TotalRuntime, LastDragRecalculateTime,
				{ Origin = TrajectoryOrigin, InitialVelocity = TrajectoryInitialVelocity,
					Acceleration = TrajectoryAcceleration, StartTime = TrajectoryStartTime },
				SpinVector
			)
		if Recalculated then
			SpinVector              = UpdatedSpin
			LastDragRecalculateTime = TotalRuntime
			OpenTrajectorySegment(DragOrigin, DragVelocity, NewAcceleration)
		end

		-- Homing
		if Snapshot.HomingTarget and not HomingDisengaged then
			local Elapsed     = TotalRuntime - TrajectoryStartTime
			local SubVelocity = VelocityAtTime(Elapsed, TrajectoryInitialVelocity, TrajectoryAcceleration)
			local SubPosition = PositionAtTime(Elapsed, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)

			local HomingVelocity, HomingApplied, HomingTrajectory, NewElapsed, NewDisengaged =
				PureHoming.Step(
					HomingDisengaged,
					Snapshot.HomingTarget,
					HomingElapsed,
					Snapshot.HomingMaxDuration,
					Snapshot.HomingStrength,
					SubVelocity, SubPosition, SubSegmentDelta,
					TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration,
					TrajectoryStartTime, TotalRuntime
				)
			HomingElapsed    = NewElapsed
			HomingDisengaged = NewDisengaged
			if HomingApplied and HomingTrajectory then
				OpenTrajectorySegment(HomingTrajectory.Origin, HomingTrajectory.InitialVelocity, HomingTrajectory.Acceleration)
			end
		end

		-- Advance time
		local ElapsedBefore  = TotalRuntime - TrajectoryStartTime
		TotalRuntime        += SubSegmentDelta
		local ElapsedAfter   = TotalRuntime - TrajectoryStartTime

		local LastPosition: Vector3
		if SubIndex == 1 and Snapshot.ProvidedLastPosition then
			LastPosition = Snapshot.ProvidedLastPosition
		else
			LastPosition = PositionAtTime(ElapsedBefore, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
		end

		local CurrentTarget   = PositionAtTime(ElapsedAfter, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
		local CurrentVelocity = (SubIndex == 1 and Snapshot.ProvidedCurrentVelocity)
			or VelocityAtTime(ElapsedAfter, TrajectoryInitialVelocity, TrajectoryAcceleration)
		local CurrentSpeed    = CurrentVelocity.Magnitude
		IsSupersonic          = CurrentSpeed >= SPEED_OF_SOUND

		local Displacement = CurrentTarget - LastPosition
		if Displacement:Dot(Displacement) < MIN_MAGNITUDE_SQ then continue end

		local RaycastResult = workspace:Raycast(LastPosition, Displacement, Snapshot.RaycastParams)
		local HitPoint      = RaycastResult and RaycastResult.Position or CurrentTarget
		DistanceCovered    += (HitPoint - LastPosition).Magnitude

		-- ── Termination (no geometry) ─────────────────────────────────────────
		if DistanceCovered >= Snapshot.MaxDistance then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.DistanceEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			return Result
		end
		if CurrentSpeed < Snapshot.MinSpeed then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.SpeedEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			return Result
		end
		if CurrentSpeed > Snapshot.MaxSpeed then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.SpeedEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			return Result
		end

		if not RaycastResult then continue end

		-- ── Hit detected ──────────────────────────────────────────────────────
		local HitPosition = RaycastResult.Position
		local HitNormal   = RaycastResult.Normal
		local HitMaterial = RaycastResult.Material

		local ImpactDot = math_abs(Displacement.Unit:Dot(HitNormal))

		local IsAbovePierceSpeed = CurrentSpeed >= Snapshot.PierceSpeedThreshold
		local IsBelowMaxPierce   = PierceCount < Snapshot.MaxPierceCount
		local MeetsNormalBias    = ImpactDot >= (1.0 - Snapshot.PierceNormalBias)
		local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

		local IsAboveBounceSpeed = CurrentSpeed >= Snapshot.BounceSpeedThreshold
		local IsBelowMaxBounce   = BounceCount < Snapshot.MaxBounces
		local IsBelowFrameBounce = BouncesThisFrame < Snapshot.MaxBouncesPerFrame
		local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

		-- Pierce: always requires callback — defer to main thread
		if EligibleForPierce and Snapshot.HasCanPierceCallback then
			local RemainingDelta = SubSegmentDelta * (SubSegmentCount - SubIndex)
			SyncResult()
			Result.Event               = PARALLEL_EVENT.PiercePending
			Result.HitPosition         = HitPosition
			Result.HitNormal           = HitNormal
			Result.HitMaterial         = HitMaterial
			Result.TravelPosition      = CurrentTarget
			Result.TravelVelocity      = CurrentVelocity
			Result.RemainingResimDelta = RemainingDelta
			Result.RayOrigin           = LastPosition
			return Result
		end

		if EligibleForBounce then
			local ReflectedVel  = PureBounce.Reflect(CurrentVelocity, HitNormal)
			local MaterialMult  = Snapshot.MaterialRestitution and (Snapshot.MaterialRestitution[tostring(HitMaterial)] or 1.0) or 1.0
			local FinalVelocity = PureBounce.ApplyRestitution(
				ReflectedVel, Snapshot.Restitution, MaterialMult, Snapshot.NormalPerturbation
			)

			local CornerTrap = PureBounce.IsCornerTrap(BounceState, HitPosition, TotalRuntime)

			local NewLastBounceTime, NewBouncePositionHead, NewBouncePositionHistory,
			NewCornerBounceCount, NewVelocityDirectionEMA, NewFirstBouncePosition =
				PureBounce.RecordBounceState(BounceState, HitPosition, FinalVelocity, TotalRuntime)

			-- Keep BounceState in sync for subsequent bounces in this loop
			BounceState.LastBounceTime          = NewLastBounceTime
			BounceState.BouncePositionHead      = NewBouncePositionHead
			BounceState.BouncePositionHistory   = NewBouncePositionHistory
			BounceState.CornerBounceCount       = NewCornerBounceCount
			BounceState.VelocityDirectionEMA    = NewVelocityDirectionEMA
			BounceState.FirstBouncePosition     = NewFirstBouncePosition

			if Snapshot.HasCanBounceCallback then
				-- Callback required: defer to main thread
				local RemainingDelta = SubSegmentDelta * (SubSegmentCount - SubIndex)
				SyncResult()
				Result.Event                  = PARALLEL_EVENT.BouncePending
				Result.HitPosition            = HitPosition
				Result.HitNormal              = HitNormal
				Result.HitMaterial            = HitMaterial
				Result.PreBounceVelocity      = CurrentVelocity
				Result.ReflectedVelocity      = FinalVelocity
				Result.IsCornerTrap           = CornerTrap
				Result.BounceCount            = BounceCount
				Result.LastBounceTime         = NewLastBounceTime
				Result.BouncePositionHistory  = NewBouncePositionHistory
				Result.BouncePositionHead     = NewBouncePositionHead
				Result.VelocityDirectionEMA   = NewVelocityDirectionEMA
				Result.FirstBouncePosition    = NewFirstBouncePosition
				Result.CornerBounceCount      = NewCornerBounceCount
				Result.BouncesThisFrame       = BouncesThisFrame + 1
				Result.TravelPosition         = CurrentTarget
				Result.TravelVelocity         = CurrentVelocity
				Result.RemainingResimDelta    = RemainingDelta
				Result.RayOrigin              = LastPosition
				return Result
			end

			if CornerTrap then
				-- Corner trap: terminate as a hit
				SyncResult()
				Result.Event          = "hit"
				Result.HitPosition    = HitPosition
				Result.HitNormal      = HitNormal
				Result.HitMaterial    = HitMaterial
				Result.TravelPosition = CurrentTarget
				Result.TravelVelocity = CurrentVelocity
				Result.RayOrigin      = LastPosition
				return Result
			end

			-- No callback: serial never bounces without CanBounceFunction.
			-- Fall through to terminal hit below.
		end

		-- Terminal hit (no pierce, no bounce)
		SyncResult()
		Result.Event          = PARALLEL_EVENT.Hit
		Result.HitPosition    = HitPosition
		Result.HitNormal      = HitNormal
		Result.HitMaterial    = HitMaterial
		Result.TravelPosition = CurrentTarget
		Result.TravelVelocity = CurrentVelocity
		Result.RayOrigin      = LastPosition
		return Result
	end

	-- ── Budget exhausted or all sub-segments clear → travel ──────────────────
	local FinalElapsed  = TotalRuntime - TrajectoryStartTime
	local FinalPosition = PositionAtTime(FinalElapsed, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local FinalVelocity = VelocityAtTime(FinalElapsed, TrajectoryInitialVelocity, TrajectoryAcceleration)

	-- Under budget: shrink segment size toward MinSegmentSize
	if (os_clock() - BudgetStartTime) * 1000 < Snapshot.HighFidelityFrameBudget * 0.5 then
		CurrentSegmentSize = math_max(CurrentSegmentSize / Snapshot.AdaptiveScaleFactor, Snapshot.MinSegmentSize)
	end

	SyncResult()
	Result.Event          = PARALLEL_EVENT.Travel
	Result.TravelPosition = FinalPosition
	Result.TravelVelocity = FinalVelocity
	Result.RayOrigin      = PositionStart
	return Result
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(StepHighFidelity)