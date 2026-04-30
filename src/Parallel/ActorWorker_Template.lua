--!native
--!optimize 2
--!strict

-- ─── ActorWorker ─────────────────────────────────────────────────────────────

local Actor = script:GetActor()
if not Actor then
	error("[ActorWorker] Must run inside an Actor instance.")
	return
end

local RunService = game:GetService("RunService")

local ParallelReference = script.Parent:WaitForChild("ParallelReference")
local Parallel        = ParallelReference.Value
local Vetra           = Parallel.Parent
local Core            = Vetra.Core
local ParallelPhysics = require(Parallel.Physics.ParallelPhysics)
local Constants       = require(Core.Constants)
local TypeDefinition  = require(Core.TypeDefinition)

-- ─── Types ───────────────────────────────────────────────────────────────────

type CastSnapshot   = TypeDefinition.CastSnapshot
type ResumeSyncData = TypeDefinition.ResumeSyncData
type ParallelResult = TypeDefinition.ParallelResult

-- ─── State ───────────────────────────────────────────────────────────────────

local LocalCasts:     { [number]: CastSnapshot } = {}
local SuspendedCasts: { [number]: true }          = {}
local Buffers:        { SharedTable }             = {}
local LastWriteCount = { 0, 0 }

-- FF (fire-and-forget) buffer — passed directly via Init message.
-- Terminal events from NeedsSync=false casts are written here each
-- PreSimulation frame. The Coordinator polls this in Phase 1 (Heartbeat),
-- which always runs after PreSimulation completes — no notification needed.
local FFBuffer: SharedTable = nil :: any
local FFWriteCount          = 0

-- ─── Constants ───────────────────────────────────────────────────────────────

local SPATIAL_HOT    = Constants.SPATIAL_TIERS.HOT
local PARALLEL_EVENT = Constants.PARALLEL_EVENT

-- ─── Init ────────────────────────────────────────────────────────────────────

-- BufferA, BufferB: double-buffered SharedTables for NeedsSync=true casts.
-- FF: SharedTable for terminal events from NeedsSync=false casts.
-- All three are passed directly by the Coordinator — no registry lookup needed.
Actor:BindToMessage("Init", function(BufferA: SharedTable, BufferB: SharedTable, FF: SharedTable)
	Buffers[1] = BufferA
	Buffers[2] = BufferB
	FFBuffer   = FF
end)

-- ─── AddCast ─────────────────────────────────────────────────────────────────

Actor:BindToMessage("AddCast", function(InitData: CastSnapshot)

	LocalCasts[InitData.Id] = {
		Id = InitData.Id,

		-- Active trajectory
		TrajectoryOrigin          = InitData.TrajectoryOrigin,
		TrajectoryInitialVelocity = InitData.TrajectoryInitialVelocity,
		TrajectoryAcceleration    = InitData.TrajectoryAcceleration,
		TrajectoryStartTime       = InitData.TrajectoryStartTime,

		-- Runtime scalars
		TotalRuntime            = InitData.TotalRuntime,
		DistanceCovered         = InitData.DistanceCovered,
		IsSupersonic            = InitData.IsSupersonic,
		LastDragRecalculateTime = InitData.LastDragRecalculateTime,
		SpinVector              = InitData.SpinVector,
		HomingElapsed           = InitData.HomingElapsed,
		HomingDisengaged        = InitData.HomingDisengaged,
		HomingAcquired          = InitData.HomingAcquired,
		CurrentSegmentSize      = InitData.CurrentSegmentSize,
		BouncesThisFrame        = 0,
		BounceCount             = InitData.BounceCount,
		PierceCount             = InitData.PierceCount,
		LastBounceTime          = InitData.LastBounceTime,

		-- LOD / Spatial
		IsLOD                   = InitData.IsLOD,
		LODDistance             = InitData.LODDistance,
		LODFrameAccumulator     = InitData.LODFrameAccumulator,
		LODDeltaAccumulator     = InitData.LODDeltaAccumulator,
		SpatialFrameAccumulator = InitData.SpatialFrameAccumulator,
		SpatialDeltaAccumulator = InitData.SpatialDeltaAccumulator,
		SpatialTier             = InitData.SpatialTier,
		LODOrigin               = InitData.LODOrigin,

		-- Bounce tracking (corner trap)
		BouncePositionHistory = InitData.BouncePositionHistory,
		BouncePositionHead    = InitData.BouncePositionHead,
		VelocityDirectionEMA  = InitData.VelocityDirectionEMA,
		FirstBouncePosition   = InitData.FirstBouncePosition,
		CornerBounceCount     = InitData.CornerBounceCount,

		-- Behavior: limits
		MaxDistance        = InitData.MaxDistance,
		MinSpeed           = InitData.MinSpeed,
		MaxSpeed           = InitData.MaxSpeed,
		MaxBounces         = InitData.MaxBounces,
		MaxBouncesPerFrame = InitData.MaxBouncesPerFrame,
		MaxPierceCount     = InitData.MaxPierceCount,

		-- Behavior: drag
		DragCoefficient     = InitData.DragCoefficient,
		DragModel           = InitData.DragModel,
		DragSegmentInterval = InitData.DragSegmentInterval,
		CustomMachTable     = InitData.CustomMachTable,

		-- Behavior: bounce
		BounceSpeedThreshold = InitData.BounceSpeedThreshold,
		Restitution          = InitData.Restitution,
		NormalPerturbation   = InitData.NormalPerturbation,
		MaterialRestitution  = InitData.MaterialRestitution,

		-- Behavior: pierce
		PierceSpeedThreshold      = InitData.PierceSpeedThreshold,
		PierceSpeedRetention      = InitData.PierceSpeedRetention,
		PierceNormalBias          = InitData.PierceNormalBias,

		-- Behavior: magnus
		MagnusCoefficient = InitData.MagnusCoefficient,
		SpinDecayRate     = InitData.SpinDecayRate,

		-- Behavior: homing
		HomingStrength    = InitData.HomingStrength,
		HomingMaxDuration = InitData.HomingMaxDuration,
		HomingTarget      = InitData.HomingTarget,

		-- Behavior: high fidelity
		HighFidelitySegmentSize = InitData.HighFidelitySegmentSize,
		AdaptiveScaleFactor     = InitData.AdaptiveScaleFactor,
		MinSegmentSize          = InitData.MinSegmentSize,
		HighFidelityFrameBudget = InitData.HighFidelityFrameBudget,

		-- Behavior: corner trap config
		CornerTimeThreshold         = InitData.CornerTimeThreshold,
		CornerDisplacementThreshold = InitData.CornerDisplacementThreshold,
		CornerEMAAlpha              = InitData.CornerEMAAlpha,
		CornerEMAThreshold          = InitData.CornerEMAThreshold,
		CornerMinProgressPerBounce  = InitData.CornerMinProgressPerBounce,

		-- Callback presence flags
		HasCanPierceCallback = InitData.HasCanPierceCallback,
		HasCanBounceCallback = InitData.HasCanBounceCallback,
		HasCanHomeCallback   = InitData.HasCanHomeCallback,

		-- Speed profiles
		SupersonicDragCoefficient = InitData.SupersonicDragCoefficient,
		SupersonicDragModel       = InitData.SupersonicDragModel,
		SubsonicDragCoefficient   = InitData.SubsonicDragCoefficient,
		SubsonicDragModel         = InitData.SubsonicDragModel,

		-- Physics environment
		BaseAcceleration = InitData.BaseAcceleration,
		Wind             = InitData.Wind,
		WindResponse     = InitData.WindResponse,
		GyroDriftRate    = InitData.GyroDriftRate,
		GyroDriftAxis    = InitData.GyroDriftAxis,

		-- Tumble
		IsTumbling            = InitData.IsTumbling,
		TumbleRandom          = InitData.TumbleRandom,
		TumbleSpeedThreshold  = InitData.TumbleSpeedThreshold,
		TumbleDragMultiplier  = InitData.TumbleDragMultiplier,
		TumbleLateralStrength = InitData.TumbleLateralStrength,
		TumbleOnPierce        = InitData.TumbleOnPierce,
		TumbleRecoverySpeed   = InitData.TumbleRecoverySpeed,

		-- Misc
		VisualizeCasts = InitData.VisualizeCasts,

		-- Fire-and-forget flag. NeedsSync=false casts are stepped via
		-- ConnectParallel autonomously and never enter the StepShard path.
		-- Note: NeedsSync=false casts do not fire travel signals or update
		-- cosmetic parts — they are pure simulation with terminal event delivery.
		NeedsSync = InitData.NeedsSync,

		RaycastParams = InitData.RaycastParams,

		-- Provider positions (populated each frame by UpdateProviderPositions)
		ProvidedLastPosition    = nil :: Vector3?,
		ProvidedCurrentPosition = nil :: Vector3?,
		ProvidedCurrentVelocity = nil :: Vector3?,

		RemainingResimDelta = nil :: number?,
	}
end)

-- ─── RemoveCast ──────────────────────────────────────────────────────────────

Actor:BindToMessage("RemoveCast", function(CastId: number)
	LocalCasts[CastId]     = nil
	SuspendedCasts[CastId] = nil
end)

-- ─── UpdateFilter ────────────────────────────────────────────────────────────

Actor:BindToMessage("UpdateFilter", function(CastId: number, FilterList: { Instance })
	local State = LocalCasts[CastId]
	if State then State.RaycastParams.FilterDescendantsInstances = FilterList end
end)

-- ─── UpdateHoming ────────────────────────────────────────────────────────────

Actor:BindToMessage("UpdateHoming", function(CastId: number, Target: Vector3?)
	local State = LocalCasts[CastId]
	if State then State.HomingTarget = Target end
end)

-- ─── UpdateProviderPositions ─────────────────────────────────────────────────

Actor:BindToMessage("UpdateProviderPositions", function(
	CastId:          number,
	LastPosition:    Vector3?,
	CurrentPosition: Vector3?,
	CurrentVelocity: Vector3?
)
	local State = LocalCasts[CastId]
	if State then
		State.ProvidedLastPosition    = LastPosition
		State.ProvidedCurrentPosition = CurrentPosition
		State.ProvidedCurrentVelocity = CurrentVelocity
	end
end)

-- ─── UpdateWind ──────────────────────────────────────────────────────────────

Actor:BindToMessage("UpdateWind", function(Wind: Vector3)
	for _, State in LocalCasts do State.Wind = Wind end
end)

-- ─── UpdateLODOrigin ─────────────────────────────────────────────────────────

Actor:BindToMessage("UpdateLODOrigin", function(Origin: Vector3?)
	for _, State in LocalCasts do State.LODOrigin = Origin end
end)

-- ─── ResumeCast ──────────────────────────────────────────────────────────────

Actor:BindToMessage("ResumeCast", function(CastId: number, SyncData: ResumeSyncData)
	SuspendedCasts[CastId] = nil
	local State = LocalCasts[CastId]
	if not State or not SyncData then return end

	if SyncData.TrajectoryOrigin then
		State.TrajectoryOrigin          = SyncData.TrajectoryOrigin
		State.TrajectoryInitialVelocity = SyncData.TrajectoryInitialVelocity
		State.TrajectoryAcceleration    = SyncData.TrajectoryAcceleration
		State.TrajectoryStartTime       = SyncData.TrajectoryStartTime
	end

	if SyncData.TotalRuntime      ~= nil then State.TotalRuntime      = SyncData.TotalRuntime      end
	if SyncData.DistanceCovered   ~= nil then State.DistanceCovered   = SyncData.DistanceCovered   end
	if SyncData.BounceCount       ~= nil then State.BounceCount       = SyncData.BounceCount       end
	if SyncData.PierceCount       ~= nil then State.PierceCount       = SyncData.PierceCount       end
	if SyncData.LastBounceTime    ~= nil then State.LastBounceTime    = SyncData.LastBounceTime    end
	if SyncData.BouncesThisFrame  ~= nil then State.BouncesThisFrame  = SyncData.BouncesThisFrame  end

	if SyncData.BouncePositionHistory      then State.BouncePositionHistory = SyncData.BouncePositionHistory end
	if SyncData.BouncePositionHead  ~= nil then State.BouncePositionHead    = SyncData.BouncePositionHead    end
	if SyncData.VelocityDirectionEMA       then State.VelocityDirectionEMA  = SyncData.VelocityDirectionEMA  end
	if SyncData.FirstBouncePosition        then State.FirstBouncePosition   = SyncData.FirstBouncePosition   end
	if SyncData.CornerBounceCount   ~= nil then State.CornerBounceCount     = SyncData.CornerBounceCount     end

	State.RemainingResimDelta = SyncData.RemainingResimDelta or nil
end)

-- ─── WriteEventToBuffer ───────────────────────────────────────────────────────
-- Reuses the SharedTable already sitting at Buffer[Index] from 2 frames ago
-- (double-buffer guarantee makes this safe), or allocates once on first use.
--
-- Writes every field unconditionally — nil clears any stale value left over
-- from a different event type that previously occupied this slot.
-- This avoids the conditional-write pattern that made PackEvent hard to reason
-- about and removes the per-event SharedTable.new() allocation entirely.

local function WriteEventToBuffer(
	Buffer: SharedTable,
	Index:  number,
	Result: ParallelResult
)
	local Entry = Buffer[Index]
	if typeof(Entry) ~= "SharedTable" then
		Entry = SharedTable.new()
		Buffer[Index] = Entry
	end

	-- Required
	Entry["Id"]    = Result.Id
	Entry["Event"] = Result.Event

	-- LOD / Spatial (always present on non-Skip results)
	Entry["IsLOD"]                   = Result.IsLOD
	Entry["LODFrameAccumulator"]     = Result.LODFrameAccumulator
	Entry["LODDeltaAccumulator"]     = Result.LODDeltaAccumulator
	Entry["SpatialFrameAccumulator"] = Result.SpatialFrameAccumulator
	Entry["SpatialDeltaAccumulator"] = Result.SpatialDeltaAccumulator

	-- Runtime scalars
	Entry["TotalRuntime"]       = Result.TotalRuntime
	Entry["DistanceCovered"]    = Result.DistanceCovered
	Entry["IsSupersonic"]       = Result.IsSupersonic
	Entry["LastDragRecalcTime"] = Result.LastDragRecalcTime
	Entry["SpinVector"]         = Result.SpinVector
	Entry["HomingElapsed"]      = Result.HomingElapsed
	Entry["HomingDisengaged"]   = Result.HomingDisengaged
	Entry["HomingAcquired"]     = Result.HomingAcquired
	Entry["CurrentSegmentSize"] = Result.CurrentSegmentSize
	Entry["BouncesThisFrame"]   = Result.BouncesThisFrame

	-- Position / velocity fields (Travel uses TravelPosition/TravelVelocity;
	-- terminal events use HitPosition etc; nil clears stale fields from prior
	-- event types that reused this slot)
	Entry["TravelPosition"]         = Result.TravelPosition
	Entry["TravelVelocity"]         = Result.TravelVelocity
	Entry["HitPosition"]            = Result.HitPosition
	Entry["HitNormal"]              = Result.HitNormal
	Entry["HitMaterial"]            = Result.HitMaterial
	Entry["RayOrigin"]              = Result.RayOrigin
	Entry["PreBounceVelocity"]      = Result.PreBounceVelocity
	Entry["VisualizationRayOrigin"] = Result.VisualizationRayOrigin
	Entry["IsCornerTrap"]           = Result.IsCornerTrap
	Entry["RemainingResimDelta"]    = Result.RemainingResimDelta

	-- Trajectory sub-table: reuse in-place, allocate once per slot
	if Result.Trajectory then
		local Traj = Entry["Trajectory"]
		if typeof(Traj) ~= "SharedTable" then
			Traj = SharedTable.new()
			Entry["Trajectory"] = Traj
		end
		Traj["Origin"]          = Result.Trajectory.Origin
		Traj["InitialVelocity"] = Result.Trajectory.InitialVelocity
		Traj["Acceleration"]    = Result.Trajectory.Acceleration
		Traj["StartTime"]       = Result.Trajectory.StartTime
	else
		Entry["Trajectory"] = nil
	end

	-- Corner-trap scalars
	Entry["BouncePositionHead"]   = Result.BouncePositionHead
	Entry["VelocityDirectionEMA"] = Result.VelocityDirectionEMA
	Entry["FirstBouncePosition"]  = Result.FirstBouncePosition
	Entry["CornerBounceCount"]    = Result.CornerBounceCount

	-- Corner-trap history sub-table: reuse in-place, allocate once per slot
	if Result.BouncePositionHistory then
		local Hist = Entry["BouncePositionHistory"]
		if typeof(Hist) ~= "SharedTable" then
			Hist = SharedTable.new()
			Entry["BouncePositionHistory"] = Hist
		end
		for i, v in Result.BouncePositionHistory do Hist[i] = v end
	else
		Entry["BouncePositionHistory"] = nil
	end
end

-- ─── StepShard ───────────────────────────────────────────────────────────────
-- Handles NeedsSync=true casts only.
-- Driven by Coordinator:SendMessage("StepShard") so the Coordinator can
-- guarantee its Phase 1–5 work (read previous results, push homing/provider
-- data) is complete before Actors step.
--
-- Double-buffer guarantee: the Coordinator always reads (FrameIndex-1)%2+1
-- while we write FrameIndex%2+1 — they are always opposite, so no clone
-- is needed on the read side.
--
-- Optimization: WriteEventToBuffer writes results directly into the target
-- SharedTable slot, reusing the SharedTable from 2 frames ago. The intermediate
-- Events accumulator table and per-frame PackEvent / PackTravelEvent allocations
-- are eliminated entirely. After warm-up, zero SharedTable.new() calls occur
-- per frame for steady-state casts.

Actor:BindToMessageParallel("StepShard", function(FrameDelta: number, FrameIndex: number)

	local BufferIndex = FrameIndex % 2 + 1
	local WriteBuffer = Buffers[BufferIndex]

	if next(LocalCasts) == nil then
		WriteBuffer["count"]        = 0
		LastWriteCount[BufferIndex] = 0
		return
	end

	task.desynchronize()

	local EventCount: number = 0

	for CastId, State in LocalCasts do
		if not State.NeedsSync    then continue end  -- FF casts run via ConnectParallel
		if SuspendedCasts[CastId] then continue end

		State.BouncesThisFrame = 0

		local SavedLastPosition    = State.ProvidedLastPosition
		local SavedCurrentPosition = State.ProvidedCurrentPosition
		local SavedCurrentVelocity = State.ProvidedCurrentVelocity
		State.ProvidedLastPosition    = nil
		State.ProvidedCurrentPosition = nil
		State.ProvidedCurrentVelocity = nil

		local Result: ParallelResult
		local UseHighFidelity = State.HighFidelitySegmentSize > 0 and not State.IsLOD and State.SpatialTier == SPATIAL_HOT

		if UseHighFidelity then
			local EffectiveDelta = State.RemainingResimDelta or FrameDelta
			State.RemainingResimDelta = nil

			local ElapsedTime        = State.TotalRuntime - State.TrajectoryStartTime
			local HalfElapsedSq      = ElapsedTime * ElapsedTime * 0.5
			local CurrentPositionForSkip = State.TrajectoryOrigin
				+ State.TrajectoryInitialVelocity * ElapsedTime
				+ State.TrajectoryAcceleration    * HalfElapsedSq

			local ShouldSkip, StepDelta,
			NewLODFrameAccumulator, NewLODDeltaAccumulator,
			NewSpatialFrameAccumulator, NewSpatialDeltaAccumulator,
			NewIsLOD, FiredAccumulatedDelta =
				ParallelPhysics.ResolveLODAndSpatialSkip(State, EffectiveDelta, CurrentPositionForSkip)

			if ShouldSkip then
				State.IsLOD                   = NewIsLOD
				State.LODFrameAccumulator     = NewLODFrameAccumulator
				State.LODDeltaAccumulator     = NewLODDeltaAccumulator
				State.SpatialFrameAccumulator = NewSpatialFrameAccumulator
				State.SpatialDeltaAccumulator = NewSpatialDeltaAccumulator
				continue
			end

			local HighFidelityDelta = (FiredAccumulatedDelta and FiredAccumulatedDelta > 0)
				and FiredAccumulatedDelta
				or StepDelta

			State.ProvidedLastPosition    = SavedLastPosition
			State.ProvidedCurrentPosition = SavedCurrentPosition
			State.ProvidedCurrentVelocity = SavedCurrentVelocity

			Result = ParallelPhysics.StepHighFidelity(
				State,
				HighFidelityDelta,
				NewIsLOD,
				NewLODFrameAccumulator,
				NewLODDeltaAccumulator,
				NewSpatialFrameAccumulator,
				NewSpatialDeltaAccumulator
			)
		else
			State.RemainingResimDelta     = nil
			State.ProvidedLastPosition    = SavedLastPosition
			State.ProvidedCurrentPosition = SavedCurrentPosition
			State.ProvidedCurrentVelocity = SavedCurrentVelocity
			Result = ParallelPhysics.Step(State, FrameDelta)
		end

		State.ProvidedLastPosition    = nil
		State.ProvidedCurrentPosition = nil
		State.ProvidedCurrentVelocity = nil

		local EventType = Result.Event

		-- ── Mutate local state ────────────────────────────────────────────
		State.IsLOD                   = Result.IsLOD
		State.LODFrameAccumulator     = Result.LODFrameAccumulator
		State.LODDeltaAccumulator     = Result.LODDeltaAccumulator
		State.SpatialFrameAccumulator = Result.SpatialFrameAccumulator
		State.SpatialDeltaAccumulator = Result.SpatialDeltaAccumulator

		if EventType ~= PARALLEL_EVENT.Skip then
			State.TotalRuntime            = Result.TotalRuntime
			State.DistanceCovered         = Result.DistanceCovered
			State.IsSupersonic            = Result.IsSupersonic
			State.LastDragRecalculateTime = Result.LastDragRecalcTime
			State.SpinVector              = Result.SpinVector
			State.HomingElapsed           = Result.HomingElapsed
			State.HomingDisengaged        = Result.HomingDisengaged
			State.HomingAcquired          = Result.HomingAcquired
			State.CurrentSegmentSize      = Result.CurrentSegmentSize
			State.BouncesThisFrame        = Result.BouncesThisFrame
		end

		if Result.Trajectory then
			State.TrajectoryOrigin          = Result.Trajectory.Origin
			State.TrajectoryInitialVelocity = Result.Trajectory.InitialVelocity
			State.TrajectoryAcceleration    = Result.Trajectory.Acceleration
			State.TrajectoryStartTime       = Result.Trajectory.StartTime
		end

		-- ── Write event directly into buffer slot ─────────────────────────
		-- Skip produces no output. BouncePending / Bounce / PiercePending
		-- additionally suspend the cast so the Coordinator can resolve it
		-- on the main thread before resuming.

		if EventType == PARALLEL_EVENT.Skip then
			-- No output needed.

		elseif EventType == PARALLEL_EVENT.BouncePending
			or  EventType == PARALLEL_EVENT.Bounce
			or  EventType == PARALLEL_EVENT.PiercePending then
			SuspendedCasts[CastId] = true
			EventCount += 1
			WriteEventToBuffer(WriteBuffer, EventCount, Result)

		else
			-- Travel, Hit, DistanceEnd, SpeedEnd — write directly.
			EventCount += 1
			WriteEventToBuffer(WriteBuffer, EventCount, Result)
		end
	end

	-- ── Finalize buffer ───────────────────────────────────────────────────────
	-- Clear only the tail beyond the current write count (slots from a prior
	-- frame with more events). No copy loop — results were written in-place.
	local PreviousCount = LastWriteCount[BufferIndex]
	for Index = EventCount + 1, PreviousCount do
		WriteBuffer[Index] = nil
	end
	WriteBuffer["count"]        = EventCount
	LastWriteCount[BufferIndex] = EventCount
end)

-- ─── FF ConnectParallel ───────────────────────────────────────────────────────
-- Steps NeedsSync=false casts autonomously each PreSimulation frame.
-- Runs entirely in the parallel phase — no task.desynchronize() needed.
--
-- Ordering guarantee: PreSimulation always completes before Heartbeat fires.
-- The Coordinator's Step() runs on Heartbeat, so by the time it polls FFBuffer
-- in Phase 1, this handler has already finished writing for this frame.
-- No BindableEvent notification is required — polling is sufficient.
--
-- Only terminal events (Hit / DistanceEnd / SpeedEnd) are written to FFBuffer.
-- Travel and Skip results require no main-thread action for FF casts.
-- BouncePending / PiercePending cannot occur: NeedsSync=false casts have no
-- callbacks, so Step() resolves bounces and pierces inline and never returns
-- a Pending event type.
--
-- Optimization: WriteEventToBuffer reuses the SharedTable already sitting at
-- FFBuffer[Index] from the previous write cycle. The FFBuffer is single-buffered
-- (no double-buffer here) but the Coordinator clears FFBuffer["count"] to 0
-- after draining, and the Actor resets FFWriteCount to 0 at the top of each
-- PreSimulation. Slots beyond FFWriteCount from prior frames are harmlessly
-- ignored. After the first few frames, zero SharedTable.new() calls occur.

RunService.PreSimulation:ConnectParallel(function(FrameDelta: number)
	if next(LocalCasts) == nil then return end
	if FFBuffer == nil         then return end

	-- Reset write cursor at the start of each frame. The Coordinator cleared
	-- FFBuffer["count"] to 0 at the end of its previous Phase 1 drain, so
	-- any stale entries beyond FFWriteCount are safely ignored.
	FFWriteCount = 0

	for CastId, State in LocalCasts do
		if State.NeedsSync        then continue end  -- handled by StepShard
		if SuspendedCasts[CastId] then continue end

		State.BouncesThisFrame = 0

		local UseHighFidelity = State.HighFidelitySegmentSize > 0 and not State.IsLOD and State.SpatialTier == SPATIAL_HOT
		local Result: ParallelResult

		if UseHighFidelity then
			local EffectiveDelta = State.RemainingResimDelta or FrameDelta
			State.RemainingResimDelta = nil

			local ElapsedTime        = State.TotalRuntime - State.TrajectoryStartTime
			local HalfElapsedSq      = ElapsedTime * ElapsedTime * 0.5
			local CurrentPositionForSkip = State.TrajectoryOrigin
				+ State.TrajectoryInitialVelocity * ElapsedTime
				+ State.TrajectoryAcceleration    * HalfElapsedSq

			local ShouldSkip, StepDelta,
			NewLODFrameAccumulator, NewLODDeltaAccumulator,
			NewSpatialFrameAccumulator, NewSpatialDeltaAccumulator,
			NewIsLOD, FiredAccumulatedDelta =
				ParallelPhysics.ResolveLODAndSpatialSkip(State, EffectiveDelta, CurrentPositionForSkip)

			State.IsLOD                   = NewIsLOD
			State.LODFrameAccumulator     = NewLODFrameAccumulator
			State.LODDeltaAccumulator     = NewLODDeltaAccumulator
			State.SpatialFrameAccumulator = NewSpatialFrameAccumulator
			State.SpatialDeltaAccumulator = NewSpatialDeltaAccumulator

			if ShouldSkip then continue end

			local HighFidelityDelta = (FiredAccumulatedDelta and FiredAccumulatedDelta > 0)
				and FiredAccumulatedDelta
				or StepDelta

			Result = ParallelPhysics.StepHighFidelity(
				State, HighFidelityDelta,
				NewIsLOD,
				NewLODFrameAccumulator, NewLODDeltaAccumulator,
				NewSpatialFrameAccumulator, NewSpatialDeltaAccumulator
			)
		else
			State.RemainingResimDelta = nil
			Result = ParallelPhysics.Step(State, FrameDelta)
		end

		local EventType = Result.Event

		-- Mutate local state
		State.IsLOD                   = Result.IsLOD
		State.LODFrameAccumulator     = Result.LODFrameAccumulator
		State.LODDeltaAccumulator     = Result.LODDeltaAccumulator
		State.SpatialFrameAccumulator = Result.SpatialFrameAccumulator
		State.SpatialDeltaAccumulator = Result.SpatialDeltaAccumulator

		if EventType ~= PARALLEL_EVENT.Skip then
			State.TotalRuntime            = Result.TotalRuntime
			State.DistanceCovered         = Result.DistanceCovered
			State.IsSupersonic            = Result.IsSupersonic
			State.LastDragRecalculateTime = Result.LastDragRecalcTime
			State.SpinVector              = Result.SpinVector
			State.HomingElapsed           = Result.HomingElapsed
			State.HomingDisengaged        = Result.HomingDisengaged
			State.HomingAcquired          = Result.HomingAcquired
			State.CurrentSegmentSize      = Result.CurrentSegmentSize
			State.BouncesThisFrame        = Result.BouncesThisFrame
		end

		if Result.Trajectory then
			State.TrajectoryOrigin          = Result.Trajectory.Origin
			State.TrajectoryInitialVelocity = Result.Trajectory.InitialVelocity
			State.TrajectoryAcceleration    = Result.Trajectory.Acceleration
			State.TrajectoryStartTime       = Result.Trajectory.StartTime
		end

		-- Travel and Skip require no main-thread action for FF casts.
		if EventType == PARALLEL_EVENT.Travel or EventType == PARALLEL_EVENT.Skip then
			continue
		end

		-- Terminal event — write directly into FFBuffer slot, reusing the
		-- SharedTable from the previous cycle. Zero allocations after warm-up.
		FFWriteCount += 1
		WriteEventToBuffer(FFBuffer, FFWriteCount, Result)
	end

	-- Always write the count so the Coordinator knows how many entries to read.
	-- Writing 0 is a valid no-op and costs one SharedTable write vs a branch.
	FFBuffer["count"] = FFWriteCount
end)