--!native
--!optimize 2
--!strict

local Actor = script:GetActor()
if not Actor then
	error("[ActorWorker] Must run inside an Actor instance.")
	return
end

local RunService = game:GetService("RunService")

local ParallelReference = script.Parent:WaitForChild("ParallelReference")
local HitInstanceEvent  = script.Parent:WaitForChild("HitInstanceEvent") :: BindableEvent
local WorkerReadyEvent  = script.Parent:WaitForChild("WorkerReadyEvent") :: BindableEvent
local Parallel        = ParallelReference.Value
local Vetra           = Parallel.Parent
local Core            = Vetra.Core
local Step             = require(Parallel.Physics.Step).Step
local StepHighFidelity  = require(Parallel.Physics.StepHighFidelity).StepHighFidelity
local LODSpatial               = require(Parallel.Physics.LODSpatial)
local ResolveLODAndSpatialSkip = LODSpatial.Resolve
local Constants       = require(Core.Constants)
local TypeDefinition  = require(Vetra.Types)
local ResultBuffer    = require(Parallel.ResultBuffer)
local PackTravelLite    = ResultBuffer.PackTravelLite
local TRAVEL_LITE_SIZE  = ResultBuffer.TRAVEL_LITE_SIZE
local PackTravelHomingLite = ResultBuffer.PackTravelHomingLite
local HOMING_LITE_SIZE     = ResultBuffer.HOMING_LITE_SIZE
local PackTrajUpdateLite   = ResultBuffer.PackTrajUpdateLite
local TRAJ_LITE_SIZE       = ResultBuffer.TRAJ_LITE_SIZE
local TRAJ_6DOF_SIZE       = ResultBuffer.TRAJ_6DOF_SIZE
local PackThrottleState    = ResultBuffer.PackThrottleState
local THROTTLE_SIZE        = ResultBuffer.THROTTLE_SIZE
local StaticOccupancy  = require(Vetra.Occupancy.StaticOccupancy)
local DynamicOccupancy = require(Vetra.Occupancy.DynamicOccupancy)
local PureTumble       = require(Vetra.Physics.Pure.Tumble)

local OccGrids: { [number]: any } = {}

local buffer_tostring = buffer.tostring
local buffer_create   = buffer.create
local buffer_writeu32 = buffer.writeu32

type CastSnapshot   = TypeDefinition.CastSnapshot
type ResumeSyncData = TypeDefinition.ResumeSyncData
type ParallelResult = TypeDefinition.ParallelResult

local LocalCasts:     { [number]: CastSnapshot } = {}
local SuspendedCasts: { [number]: true }          = {}

local SuspendFrames: { [number]: number } = {}
local SuspendTime:   { [number]: number } = {}
local SuspendAccum:  { [number]: number } = {}
local Buffers:        { SharedTable }             = {}
local FFBuffer: SharedTable = nil :: any

local ACTOR_BUFFER = buffer_create(ResultBuffer.HEADER_SIZE + ResultBuffer.MAX_RECORD_SIZE * 256)
local ACTOR_BUFFER_CAPACITY = ResultBuffer.HEADER_SIZE + ResultBuffer.MAX_RECORD_SIZE * 256

local Profiler  = require(Vetra.Profiler)
local os_clock  = os.clock
local ActorName = Actor.Name
local SPATIAL_HOT    = Constants.SPATIAL_TIERS.HOT
local PARALLEL_EVENT = Constants.PARALLEL_EVENT
local HF_WORKER_BUDGET_US = Constants.PARALLEL_HF_WORKER_BUDGET_MS * 1000

Actor:BindToMessage("Init", function(BufferA: SharedTable, BufferB: SharedTable, FF: SharedTable)
	Buffers[1] = BufferA
	Buffers[2] = BufferB
	FFBuffer   = FF

end)

Actor:BindToMessage("RegisterOccupancyGrid", function(Id: number, Blob: string)
	if OccGrids[Id] == nil then
		local _pDes = os_clock()
		OccGrids[Id] = StaticOccupancy.Deserialize(Blob)
		print(string.format(
			"[Vetra][OccShip] %s deserialize grid=%d %.2fms",
			ActorName, Id, (os_clock() - _pDes) * 1000
		))
	end
end)

local DynReaders: { [number]: any } = {}
Actor:BindToMessage("RegisterDynamicOcc", function(Id: number, ShapeST: SharedTable, XformST: SharedTable, BoundST: SharedTable, WorldST: SharedTable)
	if DynReaders[Id] == nil then
		DynReaders[Id] = DynamicOccupancy.Reader(ShapeST, XformST, BoundST, WorldST)
	end
end)

Actor:BindToMessage("SetProfiler", function(Enabled: boolean)
	if Enabled then
		Profiler.Reset()
		Profiler.Enabled = true
	else
		Profiler.Enabled = false
		Profiler.Report("Vetra Worker " .. ActorName)
	end
end)

Actor:BindToMessage("AddCast", function(InitData: CastSnapshot)
	LocalCasts[InitData.Id] = {
		Id = InitData.Id,
		TrajectoryOrigin          = InitData.TrajectoryOrigin,
		TrajectoryInitialVelocity = InitData.TrajectoryInitialVelocity,
		TrajectoryAcceleration    = InitData.TrajectoryAcceleration,
		TrajectoryStartTime       = InitData.TrajectoryStartTime,
		TotalRuntime            = InitData.TotalRuntime,
		DistanceCovered         = InitData.DistanceCovered,
		SpawnOrigin             = InitData.SpawnOrigin,
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
		IsLOD                   = InitData.IsLOD,
		LODDistance             = InitData.LODDistance,
		LODInterval             = InitData.LODInterval,
		LODFrameAccumulator     = InitData.LODFrameAccumulator,
		LODDeltaAccumulator     = InitData.LODDeltaAccumulator,
		SpatialFrameAccumulator = InitData.SpatialFrameAccumulator,
		SpatialDeltaAccumulator = InitData.SpatialDeltaAccumulator,
		SpatialTier             = InitData.SpatialTier,
		LODOrigin               = InitData.LODOrigin,
		BouncePositionHistory = InitData.BouncePositionHistory,
		BouncePositionHead    = InitData.BouncePositionHead,
		VelocityDirectionEMA  = InitData.VelocityDirectionEMA,
		FirstBouncePosition   = InitData.FirstBouncePosition,
		CornerBounceCount     = InitData.CornerBounceCount,
		MaxDistance        = InitData.MaxDistance,
		MaxDisplacement    = InitData.MaxDisplacement,
		MinSpeed           = InitData.MinSpeed,
		MaxSpeed           = InitData.MaxSpeed,
		MaxBounces         = InitData.MaxBounces,
		MaxBouncesPerFrame = InitData.MaxBouncesPerFrame,
		MaxPierceCount     = InitData.MaxPierceCount,
		DragCoefficient     = InitData.DragCoefficient,
		DragModel           = InitData.DragModel,
		DragSegmentInterval = InitData.DragSegmentInterval,
		CustomMachTable     = InitData.CustomMachTable,
		BounceSpeedThreshold = InitData.BounceSpeedThreshold,
		Restitution          = InitData.Restitution,
		NormalPerturbation   = InitData.NormalPerturbation,
		MaterialRestitution  = InitData.MaterialRestitution,
		PierceSpeedThreshold      = InitData.PierceSpeedThreshold,
		PierceSpeedRetention      = InitData.PierceSpeedRetention,
		PierceNormalBias          = InitData.PierceNormalBias,
		MagnusCoefficient = InitData.MagnusCoefficient,
		SpinDecayRate     = InitData.SpinDecayRate,
		HomingStrength    = InitData.HomingStrength,
		HomingMaxDuration = InitData.HomingMaxDuration,
		HomingTarget      = InitData.HomingTarget,
		HighFidelitySegmentSize = InitData.HighFidelitySegmentSize,
		AdaptiveScaleFactor     = InitData.AdaptiveScaleFactor,
		MinSegmentSize          = InitData.MinSegmentSize,
		HighFidelityFrameBudget = InitData.HighFidelityFrameBudget,
		CornerTimeThreshold         = InitData.CornerTimeThreshold,
		CornerDisplacementThreshold = InitData.CornerDisplacementThreshold,
		CornerEMAAlpha              = InitData.CornerEMAAlpha,
		CornerEMAThreshold          = InitData.CornerEMAThreshold,
		CornerMinProgressPerBounce  = InitData.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = InitData.CornerPositionHistorySize,
		HasCanPierceCallback = InitData.HasCanPierceCallback,
		HasCanBounceCallback = InitData.HasCanBounceCallback,
		HasCanHomeCallback   = InitData.HasCanHomeCallback,
		SupersonicDragCoefficient = InitData.SupersonicDragCoefficient,
		SupersonicDragModel       = InitData.SupersonicDragModel,
		SubsonicDragCoefficient   = InitData.SubsonicDragCoefficient,
		SubsonicDragModel         = InitData.SubsonicDragModel,
		BaseAcceleration = InitData.BaseAcceleration,
		Wind             = InitData.Wind,
		WindResponse     = InitData.WindResponse,
		GyroDriftRate    = InitData.GyroDriftRate,
		GyroDriftAxis    = InitData.GyroDriftAxis,
		IsTumbling            = InitData.IsTumbling,
		TumbleRandom          = InitData.IsTumbling and PureTumble.CreateRandom(InitData.Id) or nil,
		TumbleSpeedThreshold  = InitData.TumbleSpeedThreshold,
		TumbleDragMultiplier  = InitData.TumbleDragMultiplier,
		TumbleLateralStrength = InitData.TumbleLateralStrength,
		TumbleOnPierce        = InitData.TumbleOnPierce,
		TumbleRecoverySpeed   = InitData.TumbleRecoverySpeed,
		VisualizeCasts = InitData.VisualizeCasts,
		NeedsSync = InitData.NeedsSync,
		RaycastParams = InitData.RaycastParams,
		StaticOccupancy    = (InitData.StaticOccupancyId ~= 0) and OccGrids[InitData.StaticOccupancyId] or nil,
		StaticOccupancyId  = InitData.StaticOccupancyId,
		DynamicOccupancy   = (InitData.DynamicOccupancyId ~= 0) and DynReaders[InitData.DynamicOccupancyId] or nil,
		DynamicOccupancyId = InitData.DynamicOccupancyId,
		ProvidedLastPosition    = nil :: Vector3?,
		ProvidedCurrentPosition = nil :: Vector3?,
		ProvidedCurrentVelocity = nil :: Vector3?,

		RemainingResimDelta = nil :: number?,

		SixDOFEnabled        = InitData.SixDOFEnabled,
		Orientation          = InitData.Orientation,
		AngularVelocity      = InitData.AngularVelocity,
		AngleOfAttack        = InitData.AngleOfAttack,
		SixDOFAccumulator    = 0,
		LiftCoefficientSlope = InitData.LiftCoefficientSlope,
		PitchingMomentSlope  = InitData.PitchingMomentSlope,
		PitchDampingCoeff    = InitData.PitchDampingCoeff,
		RollDampingCoeff     = InitData.RollDampingCoeff,
		AoADragFactor        = InitData.AoADragFactor,
		ReferenceArea        = InitData.ReferenceArea,
		ReferenceLength      = InitData.ReferenceLength,
		AirDensity           = InitData.AirDensity,
		MomentOfInertia      = InitData.MomentOfInertia,
		SpinMOI              = InitData.SpinMOI,
		MaxAngularSpeed      = InitData.MaxAngularSpeed,
		BulletMass           = InitData.BulletMass,
		CLAlphaMachTable     = InitData.CLAlphaMachTable,
		CmAlphaMachTable     = InitData.CmAlphaMachTable,
		CmqMachTable         = InitData.CmqMachTable,
		ClpMachTable         = InitData.ClpMachTable,
	}
end)

Actor:BindToMessage("RemoveCast", function(CastId: number)
	LocalCasts[CastId]     = nil
	SuspendedCasts[CastId] = nil
	SuspendFrames[CastId]  = nil
	SuspendTime[CastId]    = nil
	SuspendAccum[CastId]   = nil
end)

Actor:BindToMessage("SuspendCast", function(CastId: number, FramesRemaining: number, TimeRemaining: number)
	if FramesRemaining <= 0 and TimeRemaining <= 0 then
		SuspendFrames[CastId] = nil
		SuspendTime[CastId]   = nil
		SuspendAccum[CastId]  = nil
		return
	end
	SuspendFrames[CastId] = FramesRemaining > 0 and FramesRemaining or nil
	SuspendTime[CastId]   = TimeRemaining  > 0 and TimeRemaining  or nil
end)

Actor:BindToMessage("UpdateFilter", function(CastId: number, FilterList: { Instance }, Kind: number?)
	local State = LocalCasts[CastId]
	if not State then return end
	local Params = State.RaycastParams
	if Kind == 1 then
		Params.IncludeInstances = FilterList
	elseif Kind == 2 then
		Params.ExcludeInstances = FilterList
	else
		Params.FilterDescendantsInstances = FilterList
	end
end)

Actor:BindToMessage("UpdateHoming", function(CastId: number, Target: Vector3?)
	local State = LocalCasts[CastId]
	if State then State.HomingTarget = Target end
end)

Actor:BindToMessage("UpdateHomingAcquired", function(CastId: number, Acquired: boolean)
	local State = LocalCasts[CastId]
	if State then State.HomingAcquired = Acquired end
end)

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

Actor:BindToMessage("UpdateWind", function(Wind: Vector3)
	for _, State in LocalCasts do State.Wind = Wind end
end)

Actor:BindToMessage("UpdateLODOrigin", function(Origin: Vector3?)
	for _, State in LocalCasts do State.LODOrigin = Origin end
end)

local SpatialActive = false
Actor:BindToMessage("UpdateSpatialGrid", function(
	Keys: { number }?, Tiers: { number }?, CellSize: number?, FallbackTier: number?
)
	local Grid: { [number]: number }? = nil
	if Keys and Tiers then
		Grid = {}
		for i = 1, #Keys do
			Grid[Keys[i]] = Tiers[i]
		end
	end
	SpatialActive = Grid ~= nil
	LODSpatial.SetGrid(Grid, CellSize, FallbackTier)
end)

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
	if SyncData.IsTumbling ~= nil then
		State.IsTumbling   = SyncData.IsTumbling
		State.TumbleRandom = SyncData.IsTumbling
			and (State.TumbleRandom or PureTumble.CreateRandom(CastId))
			or nil
	end

	if SyncData.BouncePositionHistory      then State.BouncePositionHistory = SyncData.BouncePositionHistory end
	if SyncData.BouncePositionHead  ~= nil then State.BouncePositionHead    = SyncData.BouncePositionHead    end
	if SyncData.VelocityDirectionEMA       then State.VelocityDirectionEMA  = SyncData.VelocityDirectionEMA  end
	if SyncData.FirstBouncePosition        then State.FirstBouncePosition   = SyncData.FirstBouncePosition   end
	if SyncData.CornerBounceCount   ~= nil then State.CornerBounceCount     = SyncData.CornerBounceCount     end

	if SyncData.Orientation     then State.Orientation     = SyncData.Orientation     end
	if SyncData.AngularVelocity then State.AngularVelocity = SyncData.AngularVelocity end

	State.RemainingResimDelta = SyncData.RemainingResimDelta or nil
end)

Actor:BindToMessage("ModifyTrajectory", function(
	CastId: number, Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3
)
	local State = LocalCasts[CastId]
	if not State then return end
	State.TrajectoryOrigin          = Origin
	State.TrajectoryInitialVelocity = InitialVelocity
	State.TrajectoryAcceleration    = Acceleration
	State.TrajectoryStartTime       = State.TotalRuntime
end)

Actor:BindToMessage("UpdateOrientation", function(
	CastId: number, Orientation: CFrame, AngularVelocity: Vector3
)
	local State = LocalCasts[CastId]
	if not State then return end
	State.Orientation     = Orientation
	State.AngularVelocity = AngularVelocity
end)

local function PackEventInto(Offset: number, Result: ParallelResult): number
	if Offset + ResultBuffer.MAX_RECORD_SIZE > ACTOR_BUFFER_CAPACITY then
		local NewCapacity = ACTOR_BUFFER_CAPACITY * 2
		local NewBuffer   = buffer_create(NewCapacity)
		buffer.copy(NewBuffer, 0, ACTOR_BUFFER, 0, Offset)
		ACTOR_BUFFER          = NewBuffer
		ACTOR_BUFFER_CAPACITY = NewCapacity
	end
	return ResultBuffer.PackEvent(ACTOR_BUFFER, Offset, Result)
end

local function BatchToString(UsedBytes: number, EventCount: number): string
	buffer_writeu32(ACTOR_BUFFER, 0, EventCount)
	local Out = buffer_create(UsedBytes)
	buffer.copy(Out, 0, ACTOR_BUFFER, 0, UsedBytes)
	return buffer_tostring(Out)
end

local function EnsureCapacity(Offset: number, RecordSize: number)
	if Offset + RecordSize > ACTOR_BUFFER_CAPACITY then
		local NewCapacity = ACTOR_BUFFER_CAPACITY * 2
		local NewBuffer   = buffer_create(NewCapacity)
		buffer.copy(NewBuffer, 0, ACTOR_BUFFER, 0, Offset)
		ACTOR_BUFFER          = NewBuffer
		ACTOR_BUFFER_CAPACITY = NewCapacity
	end
end

local function AdvanceSuspend(CastId: number, FrameDelta: number): (boolean, number)
	local Frames = SuspendFrames[CastId]
	local Time   = SuspendTime[CastId]
	if not Frames and not Time then
		return false, FrameDelta
	end

	if Frames then
		Frames -= 1
		SuspendFrames[CastId] = Frames > 0 and Frames or nil
	end
	if Time then
		Time -= FrameDelta
		SuspendTime[CastId] = Time > 0 and Time or nil
	end

	local Accum = (SuspendAccum[CastId] or 0) + FrameDelta

	if SuspendFrames[CastId] or SuspendTime[CastId] then
		SuspendAccum[CastId] = Accum
		return true, FrameDelta
	end

	SuspendAccum[CastId] = nil
	return false, FrameDelta + Accum
end

Actor:BindToMessageParallel("StepShard", function(FrameDelta: number, FrameIndex: number)
	local BufferIndex = FrameIndex % 2 + 1
	local WriteBuffer = Buffers[BufferIndex]

	if next(LocalCasts) == nil then
		WriteBuffer["count"] = 0
		return
	end

	local EventCount  = 0
	local WriteOffset = ResultBuffer.HEADER_SIZE

	local HFBudget = { RemainingUs = HF_WORKER_BUDGET_US, TotalUs = HF_WORKER_BUDGET_US }

	local PendingHits: { any } = {}
	local PendingHitCount = 0

	local AccLod       = 0
	local AccWriteback = 0

	for CastId, State in LocalCasts do
		if not State.NeedsSync    then continue end
		if SuspendedCasts[CastId] then continue end

		if State.StaticOccupancy == nil and State.StaticOccupancyId ~= 0 then
			State.StaticOccupancy = OccGrids[State.StaticOccupancyId]
		end
		if State.DynamicOccupancy == nil and State.DynamicOccupancyId ~= 0 then
			State.DynamicOccupancy = DynReaders[State.DynamicOccupancyId]
		end

		local SuspendSkip, FrameDelta = AdvanceSuspend(CastId, FrameDelta)
		if SuspendSkip then continue end

		State.BouncesThisFrame = 0

		local SavedLastPosition    = State.ProvidedLastPosition
		local SavedCurrentPosition = State.ProvidedCurrentPosition
		local SavedCurrentVelocity = State.ProvidedCurrentVelocity
		State.ProvidedLastPosition    = nil
		State.ProvidedCurrentPosition = nil
		State.ProvidedCurrentVelocity = nil

		local Result: ParallelResult
		local UseHighFidelity = State.HighFidelitySegmentSize > 0 and not State.IsLOD and State.SpatialTier == SPATIAL_HOT

		if UseHighFidelity and HFBudget.RemainingUs <= 0 then
			State.ProvidedLastPosition    = SavedLastPosition
			State.ProvidedCurrentPosition = SavedCurrentPosition
			State.ProvidedCurrentVelocity = SavedCurrentVelocity
			State.RemainingResimDelta     = State.RemainingResimDelta or FrameDelta
			continue
		end

		local _pLod; if Profiler.Enabled then _pLod = os_clock() end

		if UseHighFidelity then
			local EffectiveDelta = State.RemainingResimDelta or FrameDelta
			State.RemainingResimDelta = nil

			local CurrentPositionForSkip: Vector3? = nil
			if SpatialActive or (State.LODDistance > 0 and State.LODOrigin) then
				local ElapsedTime   = State.TotalRuntime - State.TrajectoryStartTime
				local HalfElapsedSq = ElapsedTime * ElapsedTime * 0.5
				CurrentPositionForSkip = State.TrajectoryOrigin
					+ State.TrajectoryInitialVelocity * ElapsedTime
					+ State.TrajectoryAcceleration    * HalfElapsedSq
			end

			local ShouldSkip, StepDelta, LODFrameAccumulator, LODDeltaAccumulator,
			SpatialFrameAccumulator, SpatialDeltaAccumulator, IsLOD, FiredAccumulatedDelta
				= ResolveLODAndSpatialSkip(State, EffectiveDelta, CurrentPositionForSkip)

			if ShouldSkip then
				State.IsLOD                   = IsLOD
				State.LODFrameAccumulator     = LODFrameAccumulator
				State.LODDeltaAccumulator     = LODDeltaAccumulator
				State.SpatialFrameAccumulator = SpatialFrameAccumulator
				State.SpatialDeltaAccumulator = SpatialDeltaAccumulator
				if Profiler.Enabled then
					AccLod += os_clock() - _pLod
					Profiler.Count(Profiler.Counter.LodSkipped)
				end
				continue
			end

			local HighFidelityDelta = (FiredAccumulatedDelta and FiredAccumulatedDelta > 0)
				and FiredAccumulatedDelta
				or StepDelta

			State.ProvidedLastPosition    = SavedLastPosition
			State.ProvidedCurrentPosition = SavedCurrentPosition
			State.ProvidedCurrentVelocity = SavedCurrentVelocity

			local _p; if Profiler.Enabled then _p = os_clock(); AccLod += _p - _pLod end
			Result = StepHighFidelity(
				State,
				HighFidelityDelta,
				IsLOD,
				LODFrameAccumulator,
				LODDeltaAccumulator,
				SpatialFrameAccumulator,
				SpatialDeltaAccumulator,
				HFBudget
			)
			if Profiler.Enabled then
				Profiler.Add(Profiler.Phase.StepHf, os_clock() - _p)
				Profiler.Count(Profiler.Counter.CastsStepped)
			end
		else
			State.RemainingResimDelta     = nil
			State.ProvidedLastPosition    = SavedLastPosition
			State.ProvidedCurrentPosition = SavedCurrentPosition
			State.ProvidedCurrentVelocity = SavedCurrentVelocity
			local _p; if Profiler.Enabled then _p = os_clock(); AccLod += _p - _pLod end
			Result = Step(State, FrameDelta)
			if Profiler.Enabled then
				Profiler.Add(Profiler.Phase.StepBase, os_clock() - _p)
			end
		end

		State.ProvidedLastPosition    = nil
		State.ProvidedCurrentPosition = nil
		State.ProvidedCurrentVelocity = nil

		local _pWb; if Profiler.Enabled then _pWb = os_clock() end

		local EventType = Result.Event

		if Profiler.Enabled then
			if EventType == PARALLEL_EVENT.Skip then
				Profiler.Count(Profiler.Counter.LodSkipped)
			else
				Profiler.Count(Profiler.Counter.CastsStepped)
			end
		end

		State.IsLOD                   = Result.IsLOD
		State.LODFrameAccumulator     = Result.LODFrameAccumulator
		State.LODDeltaAccumulator     = Result.LODDeltaAccumulator
		State.SpatialFrameAccumulator = Result.SpatialFrameAccumulator
		State.SpatialDeltaAccumulator = Result.SpatialDeltaAccumulator

		local WasHomingDisengaged = State.HomingDisengaged

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
			if Result.IsTumbling ~= nil then State.IsTumbling = Result.IsTumbling end
		end

		if Result.Trajectory then
			State.TrajectoryOrigin          = Result.Trajectory.Origin
			State.TrajectoryInitialVelocity = Result.Trajectory.InitialVelocity
			State.TrajectoryAcceleration    = Result.Trajectory.Acceleration
			State.TrajectoryStartTime       = Result.Trajectory.StartTime
		end

		if EventType == PARALLEL_EVENT.Skip then

		elseif EventType == PARALLEL_EVENT.BouncePending
			or  EventType == PARALLEL_EVENT.Bounce
			or  EventType == PARALLEL_EVENT.PiercePending then
			SuspendedCasts[CastId] = true
			EventCount += 1
			WriteOffset = PackEventInto(WriteOffset, Result)

			if Result.HitInstance then
				PendingHits[PendingHitCount + 1] = CastId
				PendingHits[PendingHitCount + 2] = Result.HitInstance
				PendingHitCount += 2
			end

		elseif EventType == PARALLEL_EVENT.Travel
			and Result.Trajectory == nil
			and (State.HomingTarget == nil
				or (State.HomingDisengaged and WasHomingDisengaged))
			and not State.SixDOFEnabled
			and not State.VisualizeCasts
			and not Result.TumbleBegan
			and not Result.TumbleRecovered
		then
			EventCount += 1
			if WriteOffset + TRAVEL_LITE_SIZE > ACTOR_BUFFER_CAPACITY then
				local NewCapacity = ACTOR_BUFFER_CAPACITY * 2
				local NewBuffer   = buffer_create(NewCapacity)
				buffer.copy(NewBuffer, 0, ACTOR_BUFFER, 0, WriteOffset)
				ACTOR_BUFFER          = NewBuffer
				ACTOR_BUFFER_CAPACITY = NewCapacity
			end
			WriteOffset = PackTravelLite(
				ACTOR_BUFFER, WriteOffset,
				Result.Id, Result.TravelPosition, Result.TravelVelocity, Result.TotalRuntime
			)

		elseif EventType == PARALLEL_EVENT.Travel
			and State.HomingTarget ~= nil
			and not State.HomingDisengaged
			and not State.SixDOFEnabled
			and not State.VisualizeCasts
		then
			EventCount += 1
			if WriteOffset + HOMING_LITE_SIZE > ACTOR_BUFFER_CAPACITY then
				local NewCapacity = ACTOR_BUFFER_CAPACITY * 2
				local NewBuffer   = buffer_create(NewCapacity)
				buffer.copy(NewBuffer, 0, ACTOR_BUFFER, 0, WriteOffset)
				ACTOR_BUFFER          = NewBuffer
				ACTOR_BUFFER_CAPACITY = NewCapacity
			end
			local TrajOrigin     = Result.Trajectory and Result.Trajectory.Origin or Result.TravelPosition
			local TrajStartTime  = Result.Trajectory and Result.Trajectory.StartTime or Result.TotalRuntime
			WriteOffset = PackTravelHomingLite(
				ACTOR_BUFFER, WriteOffset,
				Result.Id, Result.TravelPosition, Result.TravelVelocity, Result.TotalRuntime,
				Result.HomingElapsed, TrajOrigin, TrajStartTime
			)

		else
			EventCount += 1
			WriteOffset = PackEventInto(WriteOffset, Result)

			if Result.HitInstance then
				PendingHits[PendingHitCount + 1] = CastId
				PendingHits[PendingHitCount + 2] = Result.HitInstance
				PendingHitCount += 2
			end
		end

		if Profiler.Enabled then AccWriteback += os_clock() - _pWb end
	end

	local _pPack; if Profiler.Enabled then _pPack = os_clock() end
	WriteBuffer["data"]  = BatchToString(WriteOffset, EventCount)
	WriteBuffer["count"] = EventCount
	if Profiler.Enabled then
		Profiler.Add(Profiler.Phase.Pack, os_clock() - _pPack)
		Profiler.Add(Profiler.Phase.Lod, AccLod)
		Profiler.Add(Profiler.Phase.Writeback, AccWriteback)
	end

	if PendingHitCount > 0 then
		task.synchronize()
		HitInstanceEvent:Fire(PendingHits)
	end
end)

local FFConnection: RBXScriptConnection

FFConnection = RunService.PreSimulation:ConnectParallel(function(FrameDelta: number)
	if next(LocalCasts) == nil then return end
	if FFBuffer == nil         then return end

	local AccLod       = 0
	local AccWriteback = 0

	local FFWriteCount = 0
	local WriteOffset  = ResultBuffer.HEADER_SIZE

	local HFBudget = { RemainingUs = HF_WORKER_BUDGET_US, TotalUs = HF_WORKER_BUDGET_US }

	local PendingHits: { any } = {}
	local PendingHitCount = 0

	for CastId, State in LocalCasts do
		if State.NeedsSync        then continue end
		if SuspendedCasts[CastId] then continue end

		local SuspendSkip, FrameDelta = AdvanceSuspend(CastId, FrameDelta)
		if SuspendSkip then continue end

		local _pLod; if Profiler.Enabled then _pLod = os_clock() end

		if State.StaticOccupancy == nil and State.StaticOccupancyId ~= 0 then
			State.StaticOccupancy = OccGrids[State.StaticOccupancyId]
		end
		if State.DynamicOccupancy == nil and State.DynamicOccupancyId ~= 0 then
			State.DynamicOccupancy = DynReaders[State.DynamicOccupancyId]
		end

		State.BouncesThisFrame = 0

		local UseHighFidelity = State.HighFidelitySegmentSize > 0 and not State.IsLOD and State.SpatialTier == SPATIAL_HOT
		local Result: ParallelResult

		if UseHighFidelity and HFBudget.RemainingUs <= 0 then
			State.RemainingResimDelta = State.RemainingResimDelta or FrameDelta
			if Profiler.Enabled then
				AccLod += os_clock() - _pLod
				Profiler.Count(Profiler.Counter.GateFrozen)
			end
			continue
		end

		if UseHighFidelity then

			local EffectiveDelta = State.RemainingResimDelta or FrameDelta
			State.RemainingResimDelta = nil

			local CurrentPositionForSkip: Vector3? = nil
			if SpatialActive or (State.LODDistance > 0 and State.LODOrigin) then
				local ElapsedTime   = State.TotalRuntime - State.TrajectoryStartTime
				local HalfElapsedSq = ElapsedTime * ElapsedTime * 0.5
				CurrentPositionForSkip = State.TrajectoryOrigin
					+ State.TrajectoryInitialVelocity * ElapsedTime
					+ State.TrajectoryAcceleration    * HalfElapsedSq
			end

			local ShouldSkip, StepDelta, LODFrameAccumulator, LODDeltaAccumulator,
			SpatialFrameAccumulator, SpatialDeltaAccumulator, IsLOD, FiredAccumulatedDelta
				= ResolveLODAndSpatialSkip(State, EffectiveDelta, CurrentPositionForSkip)

			State.IsLOD                   = IsLOD
			State.LODFrameAccumulator     = LODFrameAccumulator
			State.LODDeltaAccumulator     = LODDeltaAccumulator
			State.SpatialFrameAccumulator = SpatialFrameAccumulator
			State.SpatialDeltaAccumulator = SpatialDeltaAccumulator

			if ShouldSkip then
				if Profiler.Enabled then
					AccLod += os_clock() - _pLod
					Profiler.Count(Profiler.Counter.LodSkipped)
				end
				continue
			end

			local HighFidelityDelta = (FiredAccumulatedDelta and FiredAccumulatedDelta > 0)
				and FiredAccumulatedDelta
				or StepDelta

			local _p; if Profiler.Enabled then _p = os_clock(); AccLod += _p - _pLod end
			Result = StepHighFidelity(
				State, HighFidelityDelta,
				IsLOD,
				LODFrameAccumulator, LODDeltaAccumulator,
				SpatialFrameAccumulator, SpatialDeltaAccumulator,
				HFBudget
			)
			if Profiler.Enabled then
				Profiler.Add(Profiler.Phase.StepHf, os_clock() - _p)
				Profiler.Count(Profiler.Counter.CastsStepped)
			end
		else
			State.RemainingResimDelta = nil
			local _p; if Profiler.Enabled then _p = os_clock(); AccLod += _p - _pLod end
			Result = Step(State, FrameDelta)
			if Profiler.Enabled then
				Profiler.Add(Profiler.Phase.StepBase, os_clock() - _p)
			end
		end

		local _pWb; if Profiler.Enabled then _pWb = os_clock() end

		local EventType = Result.Event

		if Profiler.Enabled then
			if EventType == PARALLEL_EVENT.Skip then
				Profiler.Count(Profiler.Counter.LodSkipped)
			else
				Profiler.Count(Profiler.Counter.CastsStepped)
			end
		end

		State.IsLOD                   = Result.IsLOD
		State.LODFrameAccumulator     = Result.LODFrameAccumulator
		State.LODDeltaAccumulator     = Result.LODDeltaAccumulator
		State.SpatialFrameAccumulator = Result.SpatialFrameAccumulator
		State.SpatialDeltaAccumulator = Result.SpatialDeltaAccumulator

		local IsThrottledNow = State.IsLOD or (State.SpatialTier or SPATIAL_HOT) > SPATIAL_HOT
		local ThrottleChanged = IsThrottledNow ~= State.LastSentThrottled

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
			if Result.IsTumbling ~= nil then State.IsTumbling = Result.IsTumbling end
		end

		if IsThrottledNow or ThrottleChanged then
			if EventType ~= PARALLEL_EVENT.Skip or ThrottleChanged then
				State.LastSentThrottled = IsThrottledNow
				FFWriteCount += 1
				EnsureCapacity(WriteOffset, THROTTLE_SIZE)
				WriteOffset = PackThrottleState(
					ACTOR_BUFFER, WriteOffset, CastId, State.TotalRuntime, IsThrottledNow
				)
			end
		end

		if Result.Trajectory then
			State.TrajectoryOrigin          = Result.Trajectory.Origin
			State.TrajectoryInitialVelocity = Result.Trajectory.InitialVelocity
			State.TrajectoryAcceleration    = Result.Trajectory.Acceleration
			State.TrajectoryStartTime       = Result.Trajectory.StartTime
		end

		if EventType == PARALLEL_EVENT.Travel then
			local Trajectory = Result.Trajectory
			if Result.TumbleBegan or Result.TumbleRecovered then
				FFWriteCount += 1
				WriteOffset = PackEventInto(WriteOffset, Result)
			elseif Trajectory then
				FFWriteCount += 1
				EnsureCapacity(WriteOffset, State.SixDOFEnabled and TRAJ_6DOF_SIZE or TRAJ_LITE_SIZE)
				WriteOffset = PackTrajUpdateLite(
					ACTOR_BUFFER, WriteOffset,
					Result.Id, Result.TotalRuntime, Result.DistanceCovered,
					Trajectory.Origin, Trajectory.InitialVelocity,
					Trajectory.Acceleration, Trajectory.StartTime,
					Result.Orientation, Result.AngularVelocity, Result.AngleOfAttack
				)
			end
			if Profiler.Enabled then AccWriteback += os_clock() - _pWb end
			continue
		end

		if EventType == PARALLEL_EVENT.Skip then
			if Profiler.Enabled then AccWriteback += os_clock() - _pWb end
			continue
		end

		FFWriteCount += 1
		WriteOffset = PackEventInto(WriteOffset, Result)

		if Result.HitInstance then
			PendingHits[PendingHitCount + 1] = CastId
			PendingHits[PendingHitCount + 2] = Result.HitInstance
			PendingHitCount += 2
		end

		if Profiler.Enabled then AccWriteback += os_clock() - _pWb end
	end

	local _pPack; if Profiler.Enabled then _pPack = os_clock() end
	FFBuffer["data"]  = BatchToString(WriteOffset, FFWriteCount)
	FFBuffer["count"] = FFWriteCount
	if Profiler.Enabled then
		Profiler.Add(Profiler.Phase.Pack, os_clock() - _pPack)
		Profiler.Add(Profiler.Phase.Lod, AccLod)
		Profiler.Add(Profiler.Phase.Writeback, AccWriteback)
		Profiler.MarkFrame()
	end

	if PendingHitCount > 0 then
		task.synchronize()
		HitInstanceEvent:Fire(PendingHits)
	end
end)

Actor.Destroying:Connect(function()
	FFConnection:Disconnect()
end)

WorkerReadyEvent:Fire()
