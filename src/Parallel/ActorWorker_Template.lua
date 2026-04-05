--!native
--!optimize 2
--!strict

-- ─── ActorWorker ─────────────────────────────────────────────────────────────


local Actor = script:GetActor()
if not Actor then
	error("[ActorWorker] Must run inside an Actor instance.")
	return
end

local SharedTableRegistry = game:GetService("SharedTableRegistry")

local ParallelReference = script.Parent:WaitForChild('ParallelReference')
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

-- ─── Constants ───────────────────────────────────────────────────────────────

local SPATIAL_HOT    = Constants.SPATIAL_TIERS.HOT
local PARALLEL_EVENT = Constants.PARALLEL_EVENT

-- ─── Init ────────────────────────────────────────────────────────────────────

Actor:BindToMessage("Init", function(BufferA: SharedTable, BufferB: SharedTable)
	Buffers[1] = BufferA
	Buffers[2] = BufferB
end)

-- ─── AddCast ─────────────────────────────────────────────────────────────────

Actor:BindToMessage("AddCast", function(InitData: CastSnapshot)
	local RayParams = RaycastParams.new()
	RayParams.FilterType                 = InitData.FilterType
	RayParams.FilterDescendantsInstances = InitData.FilterList

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
		LastDragRecalculateTime = InitData.LastDragRecalculateTime, -- FIX: was LastDragRecalcTime (wrong key)
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
		MaxSpeed           = InitData.MaxSpeed,           -- FIX: was missing → MaxSpeed termination silently broken
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
		PierceSpeedRetention = InitData.PierceSpeedRetention,
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
		HasCanHomeCallback   = InitData.HasCanHomeCallback, -- FIX: was missing

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

		-- Actor-local RaycastParams — reconstructed from FilterType + FilterList
		-- because RaycastParams cannot cross Actor boundaries.
		RaycastParams = RayParams,

		-- Transport fields are consumed above; clear from local state
		-- (not needed by ParallelPhysics, which uses RaycastParams directly).
		FilterType = InitData.FilterType,
		FilterList = InitData.FilterList,

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

	if SyncData.BouncePositionHistory         then State.BouncePositionHistory = SyncData.BouncePositionHistory end
	if SyncData.BouncePositionHead  ~= nil    then State.BouncePositionHead    = SyncData.BouncePositionHead    end
	if SyncData.VelocityDirectionEMA          then State.VelocityDirectionEMA  = SyncData.VelocityDirectionEMA  end
	if SyncData.FirstBouncePosition           then State.FirstBouncePosition   = SyncData.FirstBouncePosition   end
	if SyncData.CornerBounceCount   ~= nil    then State.CornerBounceCount     = SyncData.CornerBounceCount     end

	State.RemainingResimDelta = SyncData.RemainingResimDelta or nil
end)

-- ─── PackEvent ───────────────────────────────────────────────────────────────

local function PackEvent(Result: ParallelResult): SharedTable
	local Entry = SharedTable.new()

	Entry["Id"]    = Result.Id
	Entry["Event"] = Result.Event

	if Result.IsLOD                   ~= nil then Entry["IsLOD"]                   = Result.IsLOD                   end
	if Result.LODFrameAccumulator     ~= nil then Entry["LODFrameAccumulator"]     = Result.LODFrameAccumulator     end
	if Result.LODDeltaAccumulator     ~= nil then Entry["LODDeltaAccumulator"]     = Result.LODDeltaAccumulator     end
	if Result.SpatialFrameAccumulator ~= nil then Entry["SpatialFrameAccumulator"] = Result.SpatialFrameAccumulator end
	if Result.SpatialDeltaAccumulator ~= nil then Entry["SpatialDeltaAccumulator"] = Result.SpatialDeltaAccumulator end

	if Result.TotalRuntime       ~= nil then Entry["TotalRuntime"]       = Result.TotalRuntime       end
	if Result.DistanceCovered    ~= nil then Entry["DistanceCovered"]    = Result.DistanceCovered    end
	if Result.IsSupersonic       ~= nil then Entry["IsSupersonic"]       = Result.IsSupersonic       end
	if Result.LastDragRecalcTime ~= nil then Entry["LastDragRecalcTime"] = Result.LastDragRecalcTime end
	if Result.SpinVector               then Entry["SpinVector"]          = Result.SpinVector          end
	if Result.HomingElapsed      ~= nil then Entry["HomingElapsed"]      = Result.HomingElapsed      end
	if Result.HomingDisengaged   ~= nil then Entry["HomingDisengaged"]   = Result.HomingDisengaged   end
	if Result.HomingAcquired     ~= nil then Entry["HomingAcquired"]     = Result.HomingAcquired     end
	if Result.CurrentSegmentSize ~= nil then Entry["CurrentSegmentSize"] = Result.CurrentSegmentSize end
	if Result.BouncesThisFrame   ~= nil then Entry["BouncesThisFrame"]   = Result.BouncesThisFrame   end

	if Result.HitPosition            then Entry["HitPosition"]            = Result.HitPosition            end
	if Result.HitNormal              then Entry["HitNormal"]              = Result.HitNormal              end
	if Result.HitMaterial            then Entry["HitMaterial"]            = Result.HitMaterial            end
	if Result.RayOrigin              then Entry["RayOrigin"]              = Result.RayOrigin              end
	if Result.PreBounceVelocity      then Entry["PreBounceVelocity"]      = Result.PreBounceVelocity      end
	if Result.TravelVelocity         then Entry["TravelVelocity"]         = Result.TravelVelocity         end
	if Result.VisualizationRayOrigin then Entry["VisualizationRayOrigin"] = Result.VisualizationRayOrigin end
	if Result.IsCornerTrap      ~= nil then Entry["IsCornerTrap"]         = Result.IsCornerTrap           end

	if Result.RemainingResimDelta ~= nil then
		Entry["RemainingResimDelta"] = Result.RemainingResimDelta
	end

	if Result.Trajectory then
		local Trajectory = SharedTable.new()
		Trajectory["Origin"]          = Result.Trajectory.Origin
		Trajectory["InitialVelocity"] = Result.Trajectory.InitialVelocity
		Trajectory["Acceleration"]    = Result.Trajectory.Acceleration
		Trajectory["StartTime"]       = Result.Trajectory.StartTime
		Entry["Trajectory"] = Trajectory
	end

	if Result.BouncePositionHistory then
		local History = SharedTable.new()
		for Index, Value in Result.BouncePositionHistory do History[Index] = Value end
		Entry["BouncePositionHistory"] = History
	end
	if Result.BouncePositionHead  ~= nil then Entry["BouncePositionHead"]  = Result.BouncePositionHead  end
	if Result.VelocityDirectionEMA      then Entry["VelocityDirectionEMA"] = Result.VelocityDirectionEMA end
	if Result.FirstBouncePosition       then Entry["FirstBouncePosition"]  = Result.FirstBouncePosition  end
	if Result.CornerBounceCount   ~= nil then Entry["CornerBounceCount"]   = Result.CornerBounceCount    end

	return Entry
end

-- ─── PackTravelEvent ─────────────────────────────────────────────────────────
-- Compact SharedTable entry for pure-travel frames.

local function PackTravelEvent(CastId: number, Result: ParallelResult): SharedTable
	local Entry = SharedTable.new()
	Entry["Id"]              = CastId
	Entry["Event"]           = PARALLEL_EVENT.Travel
	Entry["TravelPosition"]  = Result.TravelPosition
	Entry["TravelVelocity"]  = Result.TravelVelocity
	Entry["TotalRuntime"]  = Result.TotalRuntime
	if Result.VisualizationRayOrigin then
		Entry["VisualizationRayOrigin"] = Result.VisualizationRayOrigin
	end
	if Result.Trajectory then
		local Trajectory = SharedTable.new()
		Trajectory["Origin"]          = Result.Trajectory.Origin
		Trajectory["InitialVelocity"] = Result.Trajectory.InitialVelocity
		Trajectory["Acceleration"]    = Result.Trajectory.Acceleration
		Trajectory["StartTime"]       = Result.Trajectory.StartTime
		Entry["Trajectory"] = Trajectory
	end
	return Entry
end

-- ─── StepShard ───────────────────────────────────────────────────────────────

Actor:BindToMessageParallel("StepShard", function(FrameDelta: number, FrameIndex: number)

	local BufferIndex = FrameIndex % 2 + 1
	local WriteBuffer = Buffers[BufferIndex]

	if next(LocalCasts) == nil then
		WriteBuffer["count"]        = 0
		LastWriteCount[BufferIndex] = 0
		return
	end

	task.desynchronize()

	local Events:     { SharedTable }? = nil
	local EventCount: number           = 0

	for CastId, State in LocalCasts do
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

			local ElapsedTime   = State.TotalRuntime - State.TrajectoryStartTime
			local HalfElapsedSq = ElapsedTime * ElapsedTime * 0.5
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

		-- ── Classify reportable events ────────────────────────────────────

		if EventType == PARALLEL_EVENT.Travel then
			if not Events then Events = {} end
			EventCount += 1
			Events[EventCount] = PackTravelEvent(CastId, Result)

		elseif EventType == PARALLEL_EVENT.Skip then
			-- LOD/spatial skip: no position update to report.
			do end

		elseif EventType == PARALLEL_EVENT.BouncePending or EventType == PARALLEL_EVENT.Bounce
			or EventType == PARALLEL_EVENT.PiercePending then
			SuspendedCasts[CastId] = true
			if not Events then Events = {} end
			EventCount += 1
			Events[EventCount] = PackEvent(Result)

		else
			-- Hit / DistanceEnd / SpeedEnd
			if not Events then Events = {} end
			EventCount += 1
			Events[EventCount] = PackEvent(Result)
		end
	end

	-- ── Write results ─────────────────────────────────────────────────────
	local PreviousCount = LastWriteCount[BufferIndex]
	if Events then
		for Index = 1, EventCount do WriteBuffer[Index] = Events[Index] end
		for Index = EventCount + 1, PreviousCount do WriteBuffer[Index] = nil end
		WriteBuffer["count"]        = EventCount
		LastWriteCount[BufferIndex] = EventCount
	else
		for Index = 1, PreviousCount do WriteBuffer[Index] = nil end
		WriteBuffer["count"]        = 0
		LastWriteCount[BufferIndex] = 0
	end
end)