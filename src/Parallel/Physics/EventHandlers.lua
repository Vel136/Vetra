--!optimize 2
--!strict

-- ─── Parallel/Physics/EventHandlers ──────────────────────────────────────────
--[[
    Main-thread apply logic for parallel physics events.

    Invoked by Coordinator's apply pass after reading the SharedTable buffer.
    Each handler receives the full EventData snapshot from the buffer and is
    responsible for:
        • Applying runtime state back onto the Cast object
        • Invoking user callbacks (CanBounceFunction, CanPierceFunction)
        • Firing signals via FireHelpers / HookHelpers
        • Calling Coord:_ResumeCast or Terminate as appropriate

    The three shared helpers (ApplyRuntimeUpdate, ApplyTrajectory,
    RecoverHitInstance) are module-private — only the handler functions
    are exported.
]]

-- ─── References ──────────────────────────────────────────────────────────────

local Parallel = script.Parent.Parent
local Vetra    = Parallel.Parent
local Core     = Vetra.Core
local Physics  = Vetra.Physics
local Signals  = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService    = require(Core.Logger)
local Constants     = require(Core.Constants)
local Kinematics    = require(Physics.Kinematics)
local BouncePhysics = require(Physics.Bounce)
local PiercePhysics = require(Physics.Pierce)
local Fragmentation = require(Physics.Fragmentation)
local FireHelpers   = require(Signals.FireHelpers)
local HookHelpers   = require(Signals.HookHelpers)
local Visualizer    = require(Core.TrajectoryVisualizer)
local TypeDefinition = require(Core.TypeDefinition)
local Enums			= require(Core.Enums)
-- ─── Types ───────────────────────────────────────────────────────────────────

type VetraCast      = TypeDefinition.VetraCast
type ResumeSyncData = TypeDefinition.ResumeSyncData
type ParallelResult = TypeDefinition.ParallelResult

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("EventHandlers", false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local cframe_new     = CFrame.new
local table_insert   = table.insert
local ZERO_VECTOR          = Constants.ZERO_VECTOR
local PARALLEL_EVENT       = Constants.PARALLEL_EVENT
local VISUALIZER_HIT_TYPE  = Constants.VISUALIZER_HIT_TYPE
local TERMINATE_REASON     = Enums.TerminateReason
local MIN_DOT_SQ          = Constants.MIN_DOT_SQ
local LOOK_AT_FALLBACK    = Constants.LOOK_AT_FALLBACK
local SPEED_OF_SOUND      = Constants.SPEED_OF_SOUND
local THRESHOLD_DIRECTION = Constants.THRESHOLD_DIRECTION

-- ─── Shared Helpers ──────────────────────────────────────────────────────────

local function ApplyRuntimeUpdate(Cast: VetraCast, EventData: ParallelResult)
	local Runtime                   = Cast.Runtime
	Runtime.TotalRuntime            = EventData.TotalRuntime
	Runtime.DistanceCovered         = EventData.DistanceCovered
	Runtime.IsSupersonic            = EventData.IsSupersonic
	Runtime.LastDragRecalculateTime = EventData.LastDragRecalcTime
	Runtime.HomingElapsed           = EventData.HomingElapsed
	Runtime.HomingDisengaged        = EventData.HomingDisengaged
	Runtime.HomingAcquired          = EventData.HomingAcquired
	Runtime.CurrentSegmentSize      = EventData.CurrentSegmentSize
	Runtime.BouncesThisFrame        = EventData.BouncesThisFrame
	Runtime.IsLOD                   = EventData.IsLOD
	Runtime.LODFrameAccumulator     = EventData.LODFrameAccumulator
	Runtime.LODDeltaAccumulator     = EventData.LODDeltaAccumulator
	Runtime.SpatialFrameAccumulator = EventData.SpatialFrameAccumulator
	Runtime.SpatialDeltaAccumulator = EventData.SpatialDeltaAccumulator
	Cast.Behavior.SpinVector        = EventData.SpinVector
end

local function ApplyTrajectory(Cast: VetraCast, Trajectory: TypeDefinition.ParallelTrajectorySegment?)
	if not Trajectory then return end
	local Runtime = Cast.Runtime
	local Last    = Runtime.ActiveTrajectory
	Last.EndTime  = Runtime.TotalRuntime
	local Segment = {
		StartTime       = Trajectory.StartTime,
		EndTime         = -1,
		Origin          = Trajectory.Origin,
		InitialVelocity = Trajectory.InitialVelocity,
		Acceleration    = Trajectory.Acceleration,
		IsSampled       = false,
		SampledFn       = nil,
	}
	table_insert(Runtime.Trajectories, Segment)
	Runtime.ActiveTrajectory   = Segment
	Runtime.CancelResimulation = true
end

-- Re-raycasts on the main thread to recover the hit Instance.
-- Instances cannot be stored in SharedTables, so the parallel worker omits
-- HitInstance from its result. We recover it here with a directed raycast
-- from RayOrigin to HitPosition using the cast's own RaycastParams.
local function RecoverHitInstance(Cast: VetraCast, EventData: ParallelResult): Instance?
	local RayOrigin = EventData.RayOrigin or EventData.VisualizationRayOrigin
	if not RayOrigin or not EventData.HitPosition then return nil end
	local Direction = EventData.HitPosition - RayOrigin
	if Direction:Dot(Direction) < 1e-8 then return nil end

	local Behavior = Cast.Behavior
	local Runtime  = Cast.Runtime

	local Result = workspace:Raycast(RayOrigin, Direction * 1.01, Behavior.RaycastParams)

	return Result and Result.Instance or nil
end

-- Mirrors SimulateCast's HandleTermination for the parallel path.
-- Fires OnPreTermination, respects cancellation (with a 3-strike force-terminate
-- guard).
--
-- WasSuspended: true when the event that triggered this termination also
--   suspended the cast in the Actor (Bounce, BouncePending, PiercePending).
--   In that case, _ResumeCast is needed to unsuspend the Actor when the
--   termination is cancelled.
--   For non-suspending events (Hit, DistanceEnd, SpeedEnd) the Actor has
--   already continued stepping freely, so calling _ResumeCast would overwrite
--   its newer state with a stale snapshot — pass false for those callers.
local function ParallelTerminate(
	Coord       : any,
	Solver      : any,
	Cast        : VetraCast,
	Terminate   : any,
	Reason      : string,
	HitResult   : any,
	Velocity    : Vector3,
	WasSuspended: boolean
)
	local Cancelled, MutatedReason = HookHelpers.FireOnPreTermination(Solver, Cast, Reason)
	local EffectiveReason          = MutatedReason or Reason

	if Cancelled then
		local Counts = Cast.Runtime.TerminationCancelCounts
		local Count  = (Counts[Reason] or 0) + 1
		Counts[Reason] = Count
		if Count >= 3 then
			-- Force-terminate after three consecutive cancellations of this reason.
			Counts[Reason] = nil
			FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
			FireHelpers.FireOnTerminated(Solver, Cast)
			Terminate(Solver, Cast, EffectiveReason)
		elseif WasSuspended then
			-- Cast was suspended in the Actor — unsuspend so it resumes next frame.
			-- PierceCount is included so the Actor stays in sync if ResolveChain
			-- incremented it before the termination was cancelled.
			local Runtime = Cast.Runtime
			Coord:_ResumeCast(Cast, {
				TotalRuntime    = Runtime.TotalRuntime,
				DistanceCovered = Runtime.DistanceCovered,
				PierceCount     = Runtime.PierceCount,
			})
		end
		-- If not WasSuspended, the Actor was never paused and is already
		-- stepping the cast freely — no action needed.
	else
		Cast.Runtime.TerminationCancelCounts[Reason] = nil
		FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
		FireHelpers.FireOnTerminated(Solver, Cast)
		Terminate(Solver, Cast, EffectiveReason)
	end
end

-- ─── Handlers ────────────────────────────────────────────────────────────────

local function HandleHit(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any)
	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	local HitInstance = RecoverHitInstance(Cast, EventData)
	local FakeResult
	if HitInstance then
		FakeResult = {
			Position = EventData.HitPosition,
			Normal   = EventData.HitNormal,
			Material = EventData.HitMaterial,
			Instance = HitInstance,
		}
	end

	local Velocity = EventData.TravelVelocity or ZERO_VECTOR

	if Cast.Behavior.VisualizeCasts then
		local HitPoint = EventData.HitPosition or EventData.TravelPosition
		if HitPoint then
			if EventData.VisualizationRayOrigin then
				local SegmentVector = HitPoint - EventData.VisualizationRayOrigin
				local SegmentLength = SegmentVector.Magnitude
				if SegmentLength > 0.001 then
					Visualizer.Segment(cframe_new(EventData.VisualizationRayOrigin, HitPoint), SegmentLength)
				end
			end
			Visualizer.Hit(cframe_new(HitPoint), VISUALIZER_HIT_TYPE.Terminal)
		end
	end

	ParallelTerminate(Coord, Solver, Cast, Terminate, PARALLEL_EVENT.Hit, FakeResult, Velocity, false)
end

local function HandleBounce(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local HitInstance = RecoverHitInstance(Cast, EventData)
	local FakeResult  = {
		Position = EventData.HitPosition,
		Normal   = EventData.HitNormal,
		Material = EventData.HitMaterial,
		Instance = HitInstance,
	}

	local CurrentVelocity = EventData.PreBounceVelocity or ZERO_VECTOR

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	local Context   = Solver._CastToBulletContext[Cast]
	
	local CanBounce = Behavior.CanBounceFunction and Behavior.CanBounceFunction(Context, FakeResult, CurrentVelocity)
		

	if Behavior.VisualizeCasts and EventData.VisualizationRayOrigin and EventData.HitPosition then
		local SegmentVector = EventData.HitPosition - EventData.VisualizationRayOrigin
		local SegmentLength = SegmentVector.Magnitude
		if SegmentLength > 0.001 then
			Visualizer.Segment(cframe_new(EventData.VisualizationRayOrigin, EventData.HitPosition), SegmentLength)
		end
	end

	if not CanBounce or EventData.IsCornerTrap then
		if Behavior.VisualizeCasts and EventData.HitPosition then
			if EventData.IsCornerTrap then
				Visualizer.CornerTrap(EventData.HitPosition)
			else
				Visualizer.Hit(cframe_new(EventData.HitPosition), VISUALIZER_HIT_TYPE.Terminal)
			end
		end
		ParallelTerminate(Coord, Solver, Cast, Terminate, PARALLEL_EVENT.Hit, FakeResult, CurrentVelocity, true)
		return
	end

	local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(Solver, Cast, FakeResult, CurrentVelocity)
	local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
	local FinalVelocity, BaseRestitution, NormalPerturbation = HookHelpers.FireOnMidBounce(Solver, Cast, FakeResult, ReflectedVelocity)
	local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, EventData.HitMaterial)

	FinalVelocity = BouncePhysics.ApplyRestitution(
		FinalVelocity, BaseRestitution, MaterialMultiplier, NormalPerturbation
	)

	local PostBounceOrigin = EventData.HitPosition + EffectiveNormal * 0.01

	if Behavior.VisualizeCasts and EventData.HitPosition then
		Visualizer.Hit(cframe_new(EventData.HitPosition), VISUALIZER_HIT_TYPE.Bounce)
		Visualizer.Normal(EventData.HitPosition, EffectiveNormal)
		Visualizer.Velocity(EventData.HitPosition, FinalVelocity)
	end

	Runtime.BounceCount      += 1
	Runtime.BouncesThisFrame += 1

	-- BouncePositionHistory arrives as a SharedTable (integer-keyed) —
	-- convert to a plain array so the rest of the codebase can use ipairs / #.
	if EventData.BouncePositionHistory then
		local History = {}
		for Key, Value in EventData.BouncePositionHistory do History[Key] = Value end
		Runtime.BouncePositionHistory = History
		Runtime.BouncePositionHead    = EventData.BouncePositionHead
	end

	if EventData.VelocityDirectionEMA then Runtime.VelocityDirectionEMA = EventData.VelocityDirectionEMA end
	if EventData.FirstBouncePosition  then Runtime.FirstBouncePosition  = EventData.FirstBouncePosition  end
	if EventData.CornerBounceCount    then Runtime.CornerBounceCount    = EventData.CornerBounceCount    end
	Runtime.LastBounceTime = Runtime.TotalRuntime

	local NewSegment = Kinematics.OpenFreshSegment(
		Cast, PostBounceOrigin, FinalVelocity, Runtime.ActiveTrajectory.Acceleration
	)
	FireHelpers.FireOnSegmentOpen(Solver, Cast, NewSegment)

	if Behavior.ResetPierceOnBounce then
		Cast:ResetPierceState()
		Coord:_UpdateFilter(Cast)
	end

	FireHelpers.FireOnBounce(Solver, Cast, FakeResult, FinalVelocity, CurrentVelocity)

	Coord:_ResumeCast(Cast, {
		TrajectoryOrigin          = NewSegment.Origin,
		TrajectoryInitialVelocity = NewSegment.InitialVelocity,
		TrajectoryAcceleration    = NewSegment.Acceleration,
		TrajectoryStartTime       = NewSegment.StartTime,

		TotalRuntime     = Runtime.TotalRuntime,
		DistanceCovered  = Runtime.DistanceCovered,
		BounceCount      = Runtime.BounceCount,
		BouncesThisFrame = Runtime.BouncesThisFrame,
		LastBounceTime   = Runtime.LastBounceTime,

		BouncePositionHistory = Runtime.BouncePositionHistory,
		BouncePositionHead    = Runtime.BouncePositionHead,
		VelocityDirectionEMA  = Runtime.VelocityDirectionEMA,
		FirstBouncePosition   = Runtime.FirstBouncePosition,
		CornerBounceCount     = Runtime.CornerBounceCount,

		-- Echo remaining resim time so the Actor resumes StepHighFidelity
		-- from the exact sub-segment boundary rather than re-stepping the frame.
		RemainingResimDelta = EventData.RemainingResimDelta or nil,
	})
end

local function HandlePierce(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any)
	local Behavior    = Cast.Behavior
	local HitInstance = RecoverHitInstance(Cast, EventData)
	local FakeResult  = {
		Position = EventData.HitPosition,
		Normal   = EventData.HitNormal,
		Material = EventData.HitMaterial,
		Instance = HitInstance,
	}

	local CurrentVelocity = EventData.TravelVelocity or ZERO_VECTOR
	local Context         = Solver._CastToBulletContext[Cast]
	local CanPierce       = Behavior.CanPierceFunction and Behavior.CanPierceFunction(Context, FakeResult, CurrentVelocity)

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	if not CanPierce then
		-- Mirror serial fallthrough: when pierce callback rejects, check bounce
		-- before giving up — serial SimulateCast falls through to its bounce block.
		local Runtime  = Cast.Runtime
		local CurrentSpeed = CurrentVelocity.Magnitude

		local IsAboveBounceSpeed = CurrentSpeed >= Behavior.BounceSpeedThreshold
		local IsBelowMaxBounce   = Runtime.BounceCount < Behavior.MaxBounces
		local IsBelowFrameBounce = Runtime.BouncesThisFrame < Behavior.MaxBouncesPerFrame
		local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

		-- Serial: CanBounce = CanBounceCallback and CanBounceCallback(...)
		-- Nil callback → nil → no bounce.
		local CanBounceCallback = Behavior.CanBounceFunction
		local CanBounce = CanBounceCallback
			and CanBounceCallback(Context, FakeResult, CurrentVelocity)

		if EligibleForBounce and CanBounce then
			local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(Solver, Cast, FakeResult, CurrentVelocity)
			local IsCornerTrap = BouncePhysics.IsCornerTrap(Cast, EffectiveNormal, EventData.HitPosition)

			if not IsCornerTrap then
				local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
				local FinalVelocity, BaseRestitution, NormalPerturbation = HookHelpers.FireOnMidBounce(Solver, Cast, FakeResult, ReflectedVelocity)
				local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, EventData.HitMaterial)
				FinalVelocity = BouncePhysics.ApplyRestitution(FinalVelocity, BaseRestitution, MaterialMultiplier, NormalPerturbation)

				local PostBounceOrigin = EventData.HitPosition + EffectiveNormal * 0.01

				Runtime.BounceCount      += 1
				Runtime.BouncesThisFrame += 1
				BouncePhysics.RecordBounceState(Cast, EffectiveNormal, EventData.HitPosition, FinalVelocity)
				Runtime.LastBounceTime = Runtime.TotalRuntime

				local NewSegment = Kinematics.OpenFreshSegment(Cast, PostBounceOrigin, FinalVelocity, Runtime.ActiveTrajectory.Acceleration)
				FireHelpers.FireOnSegmentOpen(Solver, Cast, NewSegment)

				if Behavior.ResetPierceOnBounce then
					Cast:ResetPierceState()
					Coord:_UpdateFilter(Cast)
				end

				FireHelpers.FireOnBounce(Solver, Cast, FakeResult, FinalVelocity, CurrentVelocity)
				Coord:_ResumeCast(Cast, {
					TrajectoryOrigin          = NewSegment.Origin,
					TrajectoryInitialVelocity = NewSegment.InitialVelocity,
					TrajectoryAcceleration    = NewSegment.Acceleration,
					TrajectoryStartTime       = NewSegment.StartTime,
					TotalRuntime              = Runtime.TotalRuntime,
					DistanceCovered           = Runtime.DistanceCovered,
					BounceCount               = Runtime.BounceCount,
					BouncesThisFrame          = Runtime.BouncesThisFrame,
					LastBounceTime            = Runtime.LastBounceTime,
					BouncePositionHistory     = Runtime.BouncePositionHistory,
					BouncePositionHead        = Runtime.BouncePositionHead,
					VelocityDirectionEMA      = Runtime.VelocityDirectionEMA,
					FirstBouncePosition       = Runtime.FirstBouncePosition,
					CornerBounceCount         = Runtime.CornerBounceCount,
					RemainingResimDelta       = EventData.RemainingResimDelta or nil,
				})
				return
			end
		end

		ParallelTerminate(Coord, Solver, Cast, Terminate, PARALLEL_EVENT.Hit, FakeResult, CurrentVelocity, true)
		return
	end
	
	if Behavior.FragmentOnPierce and Behavior.FragmentCount > 0 then
		Fragmentation.SpawnFragments(
			Solver, Cast, EventData.HitPosition, CurrentVelocity
		)
	end


	local RayDirection = EventData.RayOrigin and (EventData.HitPosition - EventData.RayOrigin)
	
	if not RayDirection then
		RayDirection = CurrentVelocity
	end
	local FoundSolid, SolidResult, PostPierceVelocity = PiercePhysics.ResolveChain(
		Solver, Cast, FakeResult, RayDirection, CurrentVelocity
	)

	Coord:_UpdateFilter(Cast)

	if FoundSolid and SolidResult then
		ParallelTerminate(Coord, Solver, Cast, Terminate, PARALLEL_EVENT.Hit, SolidResult, PostPierceVelocity, true)
		return
	end

	local Runtime = Cast.Runtime
	Coord:_ResumeCast(Cast, {
		TotalRuntime    = Runtime.TotalRuntime,
		DistanceCovered = Runtime.DistanceCovered,
		PierceCount     = Runtime.PierceCount,

		RemainingResimDelta = EventData.RemainingResimDelta or nil,
	})
end

-- ─── HandleTrajUpdate ────────────────────────────────────────────────────────
--[[
    Applies a mid-flight trajectory recalculation that originated inside the
    Actor (drag, Magnus, or homing segment open).  No signal is fired here —
    OnSegmentOpen was already fired on the Actor side via PureHoming, and the
    main-thread homing pass fires it for its own opens. The only thing needed
    is to update the Cast's runtime clock, distance, and active trajectory so
    the main thread stays in sync.
]]
local function HandleTrajUpdate(_Coord: any, _Solver: any, Cast: VetraCast, EventData: ParallelResult, _Terminate: any, _Ctx: any)
	Cast.Runtime.TotalRuntime    = EventData["TotalRuntime"]
	Cast.Runtime.DistanceCovered = EventData["DistanceCovered"]
	ApplyTrajectory(Cast, EventData["Trajectory"])
end

-- ─── HandleTravel ─────────────────────────────────────────────────────────────
--[[
    Applies a normal travel frame from the Actor: syncs runtime state, fires
    OnTravel, fires OnSpeedThresholdCrossed / OnHomingDisengaged as needed,
    and batches CosmeticBulletObject CFrame updates into the caller-supplied
    Ctx table ({ CosmeticParts, CosmeticCFrames }).
]]
local function HandleTravel(_Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, _Terminate: any, Ctx: any)
	if EventData["TotalRuntime"] ~= nil then
		Cast.Runtime.TotalRuntime = EventData["TotalRuntime"]
	end
	if EventData["Trajectory"] then
		ApplyTrajectory(Cast, EventData["Trajectory"])
	end

	local Position = EventData["TravelPosition"]
	local Velocity = EventData["TravelVelocity"]

	-- Sync homing state; fire OnHomingDisengaged exactly once on the
	-- false → true edge (max-duration expiry or target lost in Actor).
	local HomingDisengaged = EventData["HomingDisengaged"]
	if HomingDisengaged ~= nil then
		if HomingDisengaged == true and not Cast.Runtime.HomingDisengaged then
			Cast.Runtime.HomingDisengaged = true
			FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		else
			Cast.Runtime.HomingDisengaged = HomingDisengaged
		end
	end
	local HomingElapsed = EventData["HomingElapsed"]
	if HomingElapsed ~= nil then
		Cast.Runtime.HomingElapsed = HomingElapsed
	end

	if not (Position and Velocity) then return end

	-- Visualisation segment
	if Cast.Behavior.VisualizeCasts then
		local VisualizationRayOrigin = EventData["VisualizationRayOrigin"]
		if VisualizationRayOrigin then
			local SegmentLength = (Position - VisualizationRayOrigin).Magnitude
			if SegmentLength > 0.001 then
				Visualizer.Segment(cframe_new(VisualizationRayOrigin, Position), SegmentLength)
			end
		end
	end

	-- Speed threshold + sonic detection using Actor-computed velocity
	local CurrentSpeed    = Velocity.Magnitude
	local SpeedThresholds = Cast.Behavior.SpeedThresholds
	if SpeedThresholds and #SpeedThresholds > 0 then
		local CrossedThresholds = Cast.Runtime.CrossedThresholds
		for _, Threshold in SpeedThresholds do
			local WasAbove   = CrossedThresholds[Threshold] == true
			local IsNowAbove = CurrentSpeed >= Threshold
			if IsNowAbove ~= WasAbove then
				CrossedThresholds[Threshold] = IsNowAbove
				FireHelpers.FireOnSpeedThresholdCrossed(
					Solver, Cast, Threshold,
					IsNowAbove and THRESHOLD_DIRECTION.Ascending
						or THRESHOLD_DIRECTION.Descending,
					CurrentSpeed
				)
			end
		end
	end

	local IsNowSupersonic = CurrentSpeed >= SPEED_OF_SOUND
	if IsNowSupersonic ~= Cast.Runtime.IsSupersonic then
		Cast.Runtime.IsSupersonic = IsNowSupersonic
		FireHelpers.FireOnSpeedThresholdCrossed(
			Solver, Cast,
			SPEED_OF_SOUND,
			IsNowSupersonic and THRESHOLD_DIRECTION.Ascending
				or THRESHOLD_DIRECTION.Descending,
			CurrentSpeed
		)
	end

	FireHelpers.FireOnTravel(Solver, Cast, Position, Velocity)

	-- Cosmetic bullet batching — Ctx carries the per-Step arrays
	local CosmeticObject = Cast.Runtime.CosmeticBulletObject
	if CosmeticObject and Ctx then
		local LookDirection = Velocity:Dot(Velocity) > MIN_DOT_SQ
			and Velocity.Unit
			or LOOK_AT_FALLBACK
		local CF = cframe_new(Position, Position + LookDirection)
		if CosmeticObject:IsA("BasePart") then
			table_insert(Ctx.CosmeticParts,   CosmeticObject)
			table_insert(Ctx.CosmeticCFrames, CF)
		else
			CosmeticObject:PivotTo(CF)
		end
	end
end

-- ─── HandleTerminalEnd ────────────────────────────────────────────────────────
--[[
    Handles DistanceEnd and SpeedEnd — both are non-suspended terminations
    (the Actor was never paused for a callback; it finished the frame and
    reported the limit breach). The Reason is derived from the event type.
]]
local function HandleTerminalEnd(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any, _Ctx: any)
	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData["Trajectory"])

	local Velocity  = EventData["TravelVelocity"] or ZERO_VECTOR
	local EventType = EventData["Event"]
	local Reason
	if EventType == PARALLEL_EVENT.DistanceEnd then
		Reason = TERMINATE_REASON.Distance
	else
		Reason = TERMINATE_REASON.Speed
	end

	if Cast.Behavior.VisualizeCasts then
		local EndPosition            = EventData["TravelPosition"]
		local VisualizationRayOrigin = EventData["VisualizationRayOrigin"]
		if EndPosition then
			if VisualizationRayOrigin then
				local SegmentLength = (EndPosition - VisualizationRayOrigin).Magnitude
				if SegmentLength > 0.001 then
					Visualizer.Segment(cframe_new(VisualizationRayOrigin, EndPosition), SegmentLength)
				end
			end
			Visualizer.Hit(cframe_new(EndPosition), VISUALIZER_HIT_TYPE.Terminal)
		end
	end

	ParallelTerminate(Coord, Solver, Cast, Terminate, Reason, nil, Velocity, false)
end

-- ─── Module Return ────────────────────────────────────────────────────────────
--[[
    Full event dispatch table — every PARALLEL_EVENT constant maps to a handler.
    Coordinator.Step no longer contains any inline event logic; all handling
    lives here as the single source of truth.

    Handler signature: (Coord, Solver, Cast, EventData, Terminate, Ctx?)
      Ctx is a { CosmeticParts: {}, CosmeticCFrames: {} } table supplied by
      Coordinator.Step for handlers that need to batch cosmetic updates.
]]

return {
	-- Geometry events (suspended — Actor waits for _ResumeCast)
	[PARALLEL_EVENT.Hit]           = HandleHit,
	[PARALLEL_EVENT.Bounce]        = HandleBounce,
	[PARALLEL_EVENT.BouncePending] = HandleBounce,
	[PARALLEL_EVENT.PiercePending] = HandlePierce,

	-- State-sync events (non-suspended)
	[PARALLEL_EVENT.TrajUpdate]    = HandleTrajUpdate,
	[PARALLEL_EVENT.Travel]        = HandleTravel,
	[PARALLEL_EVENT.DistanceEnd]   = HandleTerminalEnd,
	[PARALLEL_EVENT.SpeedEnd]      = HandleTerminalEnd,

	-- Internal helpers exposed for Coordinator._ResumeCast and tests
	ApplyRuntimeUpdate = ApplyRuntimeUpdate,
	ApplyTrajectory    = ApplyTrajectory,
	ParallelTerminate  = ParallelTerminate,
}