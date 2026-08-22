--!optimize 2
--!native

local Coordinator  = {}

local RunService          = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Parallel = script.Parent
local Vetra    = script.Parent.Parent
local Core     = Vetra.Core
local Signals  = Vetra.Signals

local Constants      = require(Core.Constants)
local FireHelpers    = require(Signals.FireHelpers)
local EventHandlers  = require(Parallel.Physics.EventHandlers)
local TypeDefinition = require(Vetra.Types)
local ResultBuffer   = require(Parallel.ResultBuffer)
local Profiler       = require(Vetra.Profiler)
local StaticOccupancy= require(script.Parent.Parent.Occupancy.StaticOccupancy)
local buffer_fromstring = buffer.fromstring
local os_clock          = os.clock

local PeekEventTag     = ResultBuffer.PeekEventTag
local ReadTravelLite   = ResultBuffer.ReadTravelLite
local EVENT_TRAVEL_LITE = ResultBuffer.EVENT_TRAVEL_LITE
local HandleTravelLite = EventHandlers.HandleTravelLite

local ReadTravelHomingLite     = ResultBuffer.ReadTravelHomingLite
local EVENT_TRAVEL_HOMING_LITE = ResultBuffer.EVENT_TRAVEL_HOMING_LITE
local HandleTravelHomingLite   = EventHandlers.HandleTravelHomingLite
local ReadThrottleState        = ResultBuffer.ReadThrottleState
local EVENT_THROTTLE_STATE     = ResultBuffer.EVENT_THROTTLE_STATE
local ReadTrajUpdateLite       = ResultBuffer.ReadTrajUpdateLite
local ReadTrajUpdate6DOFTail   = ResultBuffer.ReadTrajUpdate6DOFTail
local EVENT_TRAJ_UPDATE_LITE   = ResultBuffer.EVENT_TRAJ_UPDATE_LITE
local EVENT_TRAJ_UPDATE_6DOF   = ResultBuffer.EVENT_TRAJ_UPDATE_6DOF
local TRAJ_LITE_SIZE_C         = ResultBuffer.TRAJ_LITE_SIZE
local HandleTrajUpdateLite     = EventHandlers.HandleTrajUpdateLite

local Kinematics        = require(Vetra.Physics.Kinematics)
local PositionAtTime    = Kinematics.PositionAtTime
local VelocityAtTime    = Kinematics.VelocityAtTime
local StepSpeedProfiles = EventHandlers.StepSpeedProfiles
local PlaceCosmetic     = EventHandlers.PlaceCosmetic
local FireOnTravel      = FireHelpers.FireOnTravel

local ZERO_VECTOR               = Constants.ZERO_VECTOR
local PROVIDER_VELOCITY_EPSILON = Constants.PROVIDER_VELOCITY_EPSILON

local DEFAULT_SHARD_COUNT        = Constants.PARALLEL_DEFAULT_SHARD_COUNT
local CLOCK_ADVANCE_MAX_DELTA    = Constants.PARALLEL_CLOCK_ADVANCE_MAX_DELTA
local CoordinatorMetatable       = table.freeze({ __index = Coordinator })

local ActorWorker_Client = Parallel.ActorTemplate.ActorWorker_Client
local ActorWorker_Server = Parallel.ActorTemplate.ActorWorker_Server
local WorkerTemplate     = RunService:IsClient() and ActorWorker_Client or ActorWorker_Server

type CastSnapshot   = TypeDefinition.CastSnapshot
type VetraCast      = TypeDefinition.VetraCast
type ResumeSyncData = TypeDefinition.ResumeSyncData

function Coordinator.new(Solver: any, Config: any?)
	Config = Config or {}

	local ShardCount  = Config.ShardCount or DEFAULT_SHARD_COUNT
	local ActorParent = Config.ActorParent or Parallel

	if not WorkerTemplate then
		error("Coordinator.new: ActorWorker script not found in Parallel/ActorTemplate")
		return nil
	end

	local Actors:       { Actor }            = {}
	local ShardBuffers: { { SharedTable } }  = {}
	local FFBuffers:    { SharedTable }      = {}

	local HitInstances: { [number]: Instance } = {}
	local HitConns:     { RBXScriptConnection } = {}

	local OccGridBlobs: { [number]: string } = {}
	local ReadyConns:   { RBXScriptConnection } = {}

	local ShardSyncCount: { [number]: number } = {}
	for Index = 1, ShardCount do
		ShardSyncCount[Index] = 0
	end

	local Self

	Self = setmetatable({
		_Solver       = Solver,
		_ShardCount   = ShardCount,
		_Actors       = Actors,
		_ShardBuffers = ShardBuffers,
		_FFBuffers    = FFBuffers,

		_HitInstances = HitInstances,
		_HitConns     = HitConns,

		_CastToShard = {} :: { [number]: number },
		_NextShard   = 1,

		_CastById = {} :: { [number]: VetraCast },

		_SuspendedCasts = {} :: { [number]: true },

		_FrameIndex = 0,

		_LastBroadcastWind      = ZERO_VECTOR :: Vector3,
		_LastBroadcastLODOrigin = nil         :: Vector3?,

		_CastNeedsSync  = {} :: { [number]: boolean },
		_SyncCastCount  = 0,
		_ShardSyncCount = ShardSyncCount,

		_CastsWithProviders     = {} :: { [number]: VetraCast },
		_CastsWithProviderCount = 0,

		_Destroyed = false,

		_Ready        = false,
		_PendingCasts = {} :: { VetraCast },

		_DynOccIds       = setmetatable({}, { __mode = "k" }) :: { [any]: number },
		_NextDynOccId    = 0,
		_DynOccInstances = {} :: { [number]: { Occ: any, ShapeST: SharedTable, XformST: SharedTable, BoundST: SharedTable, WorldST: SharedTable, ShapeIds: { [number]: true } } },

		_OccGridIds    = setmetatable({}, { __mode = "k" }) :: { [any]: number },
		_NextOccGridId = 0,
		_OccGridBlobs  = OccGridBlobs,
		_ReadyConns    = ReadyConns,

		_AddCastMessage = {
			Id = 0,

			TrajectoryOrigin          = Vector3.zero,
			TrajectoryInitialVelocity = Vector3.zero,
			TrajectoryAcceleration    = Vector3.zero,
			TrajectoryStartTime       = 0,

			TotalRuntime            = 0,
			DistanceCovered         = 0,
			SpawnOrigin             = Vector3.zero,
			IsSupersonic            = false,
			LastDragRecalculateTime = 0,
			SpinVector              = Vector3.zero,
			HomingElapsed           = 0,
			HomingDisengaged        = false,
			HomingAcquired          = false,
			CurrentSegmentSize      = 0,
			BounceCount             = 0,
			BouncesThisFrame        = 0,
			PierceCount             = 0,
			LastBounceTime          = 0,

			IsLOD                   = false,
			LODDistance             = 0,
			LODInterval             = 3,
			LODFrameAccumulator     = 0,
			LODDeltaAccumulator     = 0,
			SpatialFrameAccumulator = 0,
			SpatialDeltaAccumulator = 0,
			SpatialTier             = 1,
			LODOrigin               = nil,

			BouncePositionHistory = nil,
			BouncePositionHead    = 0,
			VelocityDirectionEMA  = Vector3.zero,
			FirstBouncePosition   = nil,
			CornerBounceCount     = 0,

			MaxDistance        = 0,
			MaxDisplacement    = 0,
			MinSpeed           = 0,
			MaxSpeed           = math.huge,
			MaxBounces         = 0,
			MaxBouncesPerFrame = 0,
			MaxPierceCount     = 0,

			DragCoefficient     = 0,
			DragModel           = 0,
			DragSegmentInterval = 0,
			CustomMachTable     = nil,

			BounceSpeedThreshold = 0,
			Restitution          = 0,
			NormalPerturbation   = 0,
			MaterialRestitution  = nil,

			PierceSpeedThreshold = 0,
			PierceSpeedRetention = 0,
			PierceNormalBias     = 0,

			MagnusCoefficient = 0,
			SpinDecayRate     = 0,

			HomingStrength    = 0,
			HomingMaxDuration = 0,
			HomingTarget      = nil,

			HighFidelitySegmentSize = 0,
			AdaptiveScaleFactor     = 0,
			MinSegmentSize          = 0,
			HighFidelityFrameBudget = 0,

			CornerTimeThreshold         = 0,
			CornerDisplacementThreshold = 0,
			CornerEMAAlpha              = 0,
			CornerEMAThreshold          = 0,
			CornerMinProgressPerBounce  = 0,
			CornerPositionHistorySize   = 4,

			HasCanPierceCallback = false,
			HasCanBounceCallback = false,
			HasCanHomeCallback   = false,

			SupersonicDragCoefficient = nil,
			SupersonicDragModel       = nil,
			SubsonicDragCoefficient   = nil,
			SubsonicDragModel         = nil,

			BaseAcceleration = Vector3.zero,
			Wind             = Vector3.zero,
			WindResponse     = 0,

			GyroDriftRate = nil,
			GyroDriftAxis = nil,

			IsTumbling            = false,
			TumbleRandom          = nil,
			TumbleSpeedThreshold  = nil,
			TumbleDragMultiplier  = nil,
			TumbleLateralStrength = nil,
			TumbleOnPierce        = false,
			TumbleRecoverySpeed   = nil,

			RaycastParams  = nil,
			VisualizeCasts = false,

			CoriolisOmega = Vector3.zero,

			NeedsSync = false,

			StaticOccupancyId  = 0,
			DynamicOccupancyId = 0,

			SixDOFEnabled        = false,
			Orientation          = CFrame.identity,
			AngularVelocity      = Vector3.zero,
			AngleOfAttack        = 0,
			LiftCoefficientSlope = 0,
			PitchingMomentSlope  = 0,
			PitchDampingCoeff    = 0,
			RollDampingCoeff     = 0,
			AoADragFactor        = 0,
			ReferenceArea        = 0,
			ReferenceLength      = 0,
			AirDensity           = 0,
			MomentOfInertia      = 0,
			SpinMOI              = 0,
			MaxAngularSpeed      = 0,
			BulletMass           = 0,
			CLAlphaMachTable     = nil,
			CmAlphaMachTable     = nil,
			CmqMachTable         = nil,
			ClpMachTable         = nil,
		},
	}, CoordinatorMetatable)

	for Index = 1, ShardCount do
		local SharedTableA = SharedTable.new()
		local SharedTableB = SharedTable.new()
		SharedTableA["count"] = 0
		SharedTableB["count"] = 0

		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A", SharedTableA)
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B", SharedTableB)
		ShardBuffers[Index] = { SharedTableA, SharedTableB }

		local FFBuffer    = SharedTable.new()
		FFBuffer["count"] = 0
		FFBuffers[Index]  = FFBuffer

		local Actor  = Instance.new("Actor")
		Actor.Name   = "VetraShard_" .. Index

		local Reference  = Instance.new("ObjectValue")
		Reference.Name   = "ParallelReference"
		Reference.Value  = Parallel
		Reference.Parent = Actor

		local HitEvent  = Instance.new("BindableEvent")
		HitEvent.Name   = "HitInstanceEvent"
		HitEvent.Parent = Actor

		HitConns[Index] = HitEvent.Event:Connect(function(Payload: { any })
			for PairIndex = 1, #Payload, 2 do
				HitInstances[Payload[PairIndex]] = Payload[PairIndex + 1]
			end
		end)

		local ReadyEvent  = Instance.new("BindableEvent")
		ReadyEvent.Name   = "WorkerReadyEvent"
		ReadyEvent.Parent = Actor

		ReadyConns[Index] = ReadyEvent.Event:Connect(function()
			for GridId, Blob in OccGridBlobs do
				Actor:SendMessage("RegisterOccupancyGrid", GridId, Blob)
			end
			if Self then
				for DynId, Record in Self._DynOccInstances do
					Actor:SendMessage("RegisterDynamicOcc", DynId, Record.ShapeST, Record.XformST, Record.BoundST, Record.WorldST)
				end
			end
		end)

		local Worker   = WorkerTemplate:Clone()
		Worker.Parent  = Actor
		Worker.Enabled = true
		Actor.Parent   = ActorParent

		local ShardIndex = Index
		task.defer(function()

			Actor:SendMessage(
				"Init",
				ShardBuffers[ShardIndex][1],
				ShardBuffers[ShardIndex][2],
				FFBuffers[ShardIndex]
			)

		end)

		Actors[Index] = Actor
	end

	task.defer(function()
		if Self._Destroyed then return end
		Self._Ready = true
		local pending = Self._PendingCasts
		if #pending > 0 then
			local drained = pending
			Self._PendingCasts = {}
			for _, Cast in drained do
				if Cast.Alive then
					Self:_SendAddCast(Cast)
				end
			end
		end
	end)

	return Self
end

function Coordinator:AddCast(Cast: VetraCast)
	if not self._Ready then
		self._PendingCasts[#self._PendingCasts + 1] = Cast
		return
	end
	self:_SendAddCast(Cast)
end

function Coordinator:_EnsureOccGridShipped(Grid: any): number
	if Grid == nil then return 0 end
	local existing = self._OccGridIds[Grid]
	if existing then return existing end

	local id = self._NextOccGridId + 1
	self._NextOccGridId = id
	self._OccGridIds[Grid] = id

	local _pSer = os_clock()
	local blob = require(script.Parent.Parent.Occupancy.StaticOccupancy).Serialize(Grid)
	local SerializeMs = (os_clock() - _pSer) * 1000

	self._OccGridBlobs[id] = blob

	local _pSend = os_clock()
	for Index = 1, self._ShardCount do
		self._Actors[Index]:SendMessage("RegisterOccupancyGrid", id, blob)
	end
	local SendMs = (os_clock() - _pSend) * 1000

	print(string.format(
		"[Vetra][OccShip] grid=%d voxels=%d blob=%.1fKB | Serialize %.2fms | SendMessage x%d %.2fms | total %.2fms",
		id, Grid.count or -1, #blob / 1024,
		SerializeMs, self._ShardCount, SendMs, SerializeMs + SendMs
	))

	return id
end

function Coordinator:_EnsureDynamicOccShipped(DynOcc: any): number
	if DynOcc == nil then return 0 end
	local existing = self._DynOccIds[DynOcc]
	if existing then return existing end

	local id = self._NextDynOccId + 1
	self._NextDynOccId = id
	self._DynOccIds[DynOcc] = id

	local ShapeST = SharedTable.new()
	local XformST = SharedTable.new()
	local BoundST = SharedTable.new()
	local WorldST = SharedTable.new()
	local ShapeIds: { [number]: true } = {}
	for shapeId, blob in DynOcc._shapes do
		ShapeST[shapeId] = blob
		ShapeIds[shapeId] = true
	end
	for xformId, blob in DynOcc._xforms do
		XformST[xformId] = blob
	end
	for slot, value in DynOcc._bounds do
		BoundST[slot] = value
	end
	for slot, value in DynOcc._world do
		WorldST[slot] = value
	end
	self._DynOccInstances[id] = { Occ = DynOcc, ShapeST = ShapeST, XformST = XformST, BoundST = BoundST, WorldST = WorldST, ShapeIds = ShapeIds }

	for Index = 1, self._ShardCount do
		self._Actors[Index]:SendMessage("RegisterDynamicOcc", id, ShapeST, XformST, BoundST, WorldST)
	end
	return id
end

function Coordinator:SetProfilerEnabled(Enabled: boolean)
	for Index = 1, self._ShardCount do
		self._Actors[Index]:SendMessage("SetProfiler", Enabled)
	end

	if Enabled then
		Profiler.Reset()
		Profiler.Enabled = true
	else
		Profiler.Enabled = false
		Profiler.Report("Vetra Main Thread (Coordinator)")
	end
end

function Coordinator:_SendAddCast(Cast: VetraCast)
	local ShardIndex           = self._NextShard
	self._NextShard            = (ShardIndex % self._ShardCount) + 1
	self._CastToShard[Cast.Id] = ShardIndex
	self._CastById[Cast.Id]    = Cast

	local Solver           = self._Solver
	local Runtime          = Cast.Runtime
	local Behavior         = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory
	local RaycastParams    = Behavior.RaycastParams

	local StaticOccupancyId  = self:_EnsureOccGridShipped(Behavior.StaticOccupancy)
	local DynamicOccupancyId = self:_EnsureDynamicOccShipped(Behavior.DynamicOccupancy)

	local HasProviders = Behavior.HomingPositionProvider     ~= nil
		or Behavior.TrajectoryPositionProvider ~= nil

	local HasCallbacks = Behavior.CanBounceFunction ~= nil
		or Behavior.CanPierceFunction ~= nil
		or Behavior.CanHomeFunction   ~= nil
		or HasProviders

	local NeedsSync = HasCallbacks or Behavior.VisualizeCasts == true

	self._CastNeedsSync[Cast.Id] = NeedsSync
	if NeedsSync then
		self._SyncCastCount             += 1
		self._ShardSyncCount[ShardIndex] = (self._ShardSyncCount[ShardIndex] or 0) + 1
	end

	if HasProviders then
		self._CastsWithProviders[Cast.Id] = Cast
		self._CastsWithProviderCount     += 1
	end

	local SerializedMaterialRestitution: { [string]: number }? = nil
	if Behavior.MaterialRestitution then
		SerializedMaterialRestitution = {}
		for Material, Value in Behavior.MaterialRestitution do
			SerializedMaterialRestitution[tostring(Material)] = Value
		end
	end

	local Message = self._AddCastMessage

	Message.Id = Cast.Id

	Message.TrajectoryOrigin          = ActiveTrajectory.Origin
	Message.TrajectoryInitialVelocity = ActiveTrajectory.InitialVelocity
	Message.TrajectoryAcceleration    = ActiveTrajectory.Acceleration
	Message.TrajectoryStartTime       = ActiveTrajectory.StartTime

	Message.TotalRuntime            = Runtime.TotalRuntime
	Message.DistanceCovered         = Runtime.DistanceCovered
	Message.SpawnOrigin             = Runtime.SpawnOrigin
	Message.IsSupersonic            = Runtime.IsSupersonic
	Message.LastDragRecalculateTime = Runtime.LastDragRecalculateTime
	Message.SpinVector              = Behavior.SpinVector
	Message.HomingElapsed           = Runtime.HomingElapsed
	Message.HomingDisengaged        = Runtime.HomingDisengaged
	Message.HomingAcquired          = Runtime.HomingAcquired
	Message.CurrentSegmentSize      = Runtime.CurrentSegmentSize
	Message.BounceCount             = Runtime.BounceCount
	Message.BouncesThisFrame        = Runtime.BouncesThisFrame
	Message.PierceCount             = Runtime.PierceCount
	Message.LastBounceTime          = Runtime.LastBounceTime

	Message.IsLOD                   = Runtime.IsLOD
	Message.LODDistance             = Behavior.LODDistance
	Message.LODInterval             = Behavior.LODInterval
	Message.LODFrameAccumulator     = Runtime.LODFrameAccumulator
	Message.LODDeltaAccumulator     = Runtime.LODDeltaAccumulator
	Message.SpatialFrameAccumulator = Runtime.SpatialFrameAccumulator
	Message.SpatialDeltaAccumulator = Runtime.SpatialDeltaAccumulator
	Message.SpatialTier             = 1
	Message.LODOrigin               = Solver._LODOrigin

	Message.BouncePositionHistory = Runtime.BouncePositionHistory
	Message.BouncePositionHead    = Runtime.BouncePositionHead
	Message.VelocityDirectionEMA  = Runtime.VelocityDirectionEMA
	Message.FirstBouncePosition   = Runtime.FirstBouncePosition
	Message.CornerBounceCount     = Runtime.CornerBounceCount

	Message.MaxDistance        = Behavior.MaxDistance
	Message.MaxDisplacement    = Behavior.MaxDisplacement
	Message.MinSpeed           = Behavior.MinSpeed
	Message.MaxSpeed           = Behavior.MaxSpeed
	Message.MaxBounces         = Behavior.MaxBounces
	Message.MaxBouncesPerFrame = Behavior.MaxBouncesPerFrame
	Message.MaxPierceCount     = Behavior.MaxPierceCount

	Message.DragCoefficient     = Behavior.DragCoefficient
	Message.DragModel           = Behavior.DragModel
	Message.DragSegmentInterval = Behavior.DragSegmentInterval
	Message.CustomMachTable     = Behavior.CustomMachTable

	Message.BounceSpeedThreshold = Behavior.BounceSpeedThreshold
	Message.Restitution          = Behavior.Restitution
	Message.NormalPerturbation   = Behavior.NormalPerturbation
	Message.MaterialRestitution  = SerializedMaterialRestitution

	Message.PierceSpeedThreshold = Behavior.PierceSpeedThreshold
	Message.PierceSpeedRetention = Behavior.PierceSpeedRetention
	Message.PierceNormalBias     = Behavior.PierceNormalBias

	Message.MagnusCoefficient = Behavior.MagnusCoefficient
	Message.SpinDecayRate     = Behavior.SpinDecayRate

	Message.HomingStrength    = Behavior.HomingStrength
	Message.HomingMaxDuration = Behavior.HomingMaxDuration
	Message.HomingTarget      = nil

	Message.HighFidelitySegmentSize = Behavior.HighFidelitySegmentSize
	Message.AdaptiveScaleFactor     = Behavior.AdaptiveScaleFactor
	Message.MinSegmentSize          = Behavior.MinSegmentSize
	Message.HighFidelityFrameBudget = Behavior.HighFidelityFrameBudget

	Message.CornerTimeThreshold         = Behavior.CornerTimeThreshold
	Message.CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold
	Message.CornerEMAAlpha              = Behavior.CornerEMAAlpha     or 0.4
	Message.CornerEMAThreshold          = Behavior.CornerEMAThreshold or 0.25
	Message.CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce
	Message.CornerPositionHistorySize   = Behavior.CornerPositionHistorySize

	Message.HasCanPierceCallback = Behavior.CanPierceFunction ~= nil
	Message.HasCanBounceCallback = Behavior.CanBounceFunction ~= nil
	Message.HasCanHomeCallback   = Behavior.CanHomeFunction   ~= nil

	Message.SupersonicDragCoefficient = Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragCoefficient or nil
	Message.SupersonicDragModel       = Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragModel       or nil
	Message.SubsonicDragCoefficient   = Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragCoefficient  or nil
	Message.SubsonicDragModel         = Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragModel        or nil

	Message.BaseAcceleration = Solver._BaseAccelerationCache[Cast] or ZERO_VECTOR
	Message.Wind             = Solver._Wind
	Message.WindResponse     = Behavior.WindResponse

	Message.GyroDriftRate = Behavior.GyroDriftRate
	Message.GyroDriftAxis = Behavior.GyroDriftAxis

	Message.IsTumbling            = Cast.Runtime.IsTumbling
	Message.TumbleSpeedThreshold  = Behavior.TumbleSpeedThreshold
	Message.TumbleDragMultiplier  = Behavior.TumbleDragMultiplier
	Message.TumbleLateralStrength = Behavior.TumbleLateralStrength
	Message.TumbleOnPierce        = Behavior.TumbleOnPierce
	Message.TumbleRecoverySpeed   = Behavior.TumbleRecoverySpeed

	Message.RaycastParams  = RaycastParams
	Message.VisualizeCasts = Behavior.VisualizeCasts

	Message.CoriolisOmega = Solver._CoriolisOmega or Vector3.zero
	Message.NeedsSync     = NeedsSync

	Message.StaticOccupancyId  = StaticOccupancyId
	Message.DynamicOccupancyId = DynamicOccupancyId

	Message.SixDOFEnabled        = Behavior.SixDOFEnabled == true
	Message.Orientation          = Runtime.Orientation
	Message.AngularVelocity      = Runtime.AngularVelocity
	Message.AngleOfAttack        = Runtime.AngleOfAttack
	Message.LiftCoefficientSlope = Behavior.LiftCoefficientSlope
	Message.PitchingMomentSlope  = Behavior.PitchingMomentSlope
	Message.PitchDampingCoeff    = Behavior.PitchDampingCoeff
	Message.RollDampingCoeff     = Behavior.RollDampingCoeff
	Message.AoADragFactor        = Behavior.AoADragFactor
	Message.ReferenceArea        = Behavior.ReferenceArea
	Message.ReferenceLength      = Behavior.ReferenceLength
	Message.AirDensity           = Behavior.AirDensity
	Message.MomentOfInertia      = Behavior.MomentOfInertia
	Message.SpinMOI              = Behavior.SpinMOI
	Message.MaxAngularSpeed      = Behavior.MaxAngularSpeed
	Message.BulletMass           = Behavior.BulletMass
	Message.CLAlphaMachTable     = Behavior.CLAlphaMachTable
	Message.CmAlphaMachTable     = Behavior.CmAlphaMachTable
	Message.CmqMachTable         = Behavior.CmqMachTable
	Message.ClpMachTable         = Behavior.ClpMachTable

	self._Actors[ShardIndex]:SendMessage("AddCast", Message)
end

function Coordinator:RemoveCast(CastId: number)
	local ShardIndex = self._CastToShard[CastId]
	if not ShardIndex then return end
	self._CastToShard[CastId]    = nil
	self._SuspendedCasts[CastId] = nil
	self._CastById[CastId]       = nil
	self._HitInstances[CastId]   = nil
	if self._CastNeedsSync[CastId] then
		self._SyncCastCount             -= 1
		self._ShardSyncCount[ShardIndex] -= 1
	end
	self._CastNeedsSync[CastId] = nil
	if self._CastsWithProviders[CastId] then
		self._CastsWithProviders[CastId] = nil
		self._CastsWithProviderCount    -= 1
	end
	self._Actors[ShardIndex]:SendMessage("RemoveCast", CastId)
end

local FILTER_KIND_LEGACY  = 0
local FILTER_KIND_INCLUDE = 1
local FILTER_KIND_EXCLUDE = 2

function Coordinator:_UpdateFilter(Cast: VetraCast)
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end

	local Params = Cast.Behavior.RaycastParams
	local Kind, List
	if Params.IncludeInstances ~= nil then
		Kind, List = FILTER_KIND_INCLUDE, Params.IncludeInstances
	elseif Params.ExcludeInstances ~= nil then
		Kind, List = FILTER_KIND_EXCLUDE, Params.ExcludeInstances
	else
		Kind, List = FILTER_KIND_LEGACY, Params.FilterDescendantsInstances
	end

	self._Actors[ShardIndex]:SendMessage("UpdateFilter", Cast.Id, List, Kind)
end

function Coordinator:_SuspendCast(Cast: VetraCast, FramesRemaining: number, TimeRemaining: number)
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	self._Actors[ShardIndex]:SendMessage("SuspendCast", Cast.Id, FramesRemaining, TimeRemaining)
end

function Coordinator:_ModifyTrajectory(Cast: VetraCast)
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	local Active = Cast.Runtime.ActiveTrajectory
	self._Actors[ShardIndex]:SendMessage(
		"ModifyTrajectory",
		Cast.Id,
		Active.Origin,
		Active.InitialVelocity,
		Active.Acceleration
	)
end

function Coordinator:_UpdateOrientation(Cast: VetraCast)
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	local Runtime = Cast.Runtime
	self._Actors[ShardIndex]:SendMessage(
		"UpdateOrientation",
		Cast.Id,
		Runtime.Orientation,
		Runtime.AngularVelocity
	)
end

function Coordinator:_ResumeCast(Cast: VetraCast, SyncData: ResumeSyncData)
	self._SuspendedCasts[Cast.Id] = nil
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	self._Actors[ShardIndex]:SendMessage("ResumeCast", Cast.Id, SyncData)
end

function Coordinator:Step(FrameDelta: number)
	local ActiveCasts = self._Solver._ActiveCasts
	if #ActiveCasts == 0 then return end

	local ClockDelta = FrameDelta
	if ClockDelta > CLOCK_ADVANCE_MAX_DELTA then
		ClockDelta = CLOCK_ADVANCE_MAX_DELTA
	end

	local CosmeticParts:   { BasePart } = {}
	local CosmeticCFrames: { CFrame }   = {}
	local CosmeticCtx     = { CosmeticParts = CosmeticParts, CosmeticCFrames = CosmeticCFrames }

	local Solver_       = self._Solver
	local CastNeedsSync = self._CastNeedsSync
	local Suspended     = self._SuspendedCasts

	local TravelSignals   = Solver_.Signals
	local TravelWanted    = TravelSignals.OnTravel:HasListeners()
		or TravelSignals.OnTravelBatch:HasListeners()
	local ThresholdsWanted = TravelSignals.OnSpeedThresholdCrossed:HasListeners()
	for _, Cast in ActiveCasts do
		if Cast.Alive and not Cast.Paused and not CastNeedsSync[Cast.Id] then
			local Runtime = Cast.Runtime

			local UserSuspended = false
			if Runtime.SuspendFramesRemaining > 0 then
				Runtime.SuspendFramesRemaining -= 1
				UserSuspended = true
			end
			if Runtime.SuspendTimeRemaining > 0 then
				Runtime.SuspendTimeRemaining -= FrameDelta
				if Runtime.SuspendTimeRemaining < 0 then Runtime.SuspendTimeRemaining = 0 end
				UserSuspended = true
			end

			if UserSuspended then
				Runtime.SuspendDeltaAccumulator += ClockDelta
			elseif not Suspended[Cast.Id] then
				Runtime.TotalRuntime = Runtime.TotalRuntime + ClockDelta + Runtime.SuspendDeltaAccumulator
				Runtime.SuspendDeltaAccumulator = 0

				if not Runtime.IsThrottled then
					Runtime.ConfirmedRuntime = Runtime.TotalRuntime
				end
			end

			local Behavior        = Cast.Behavior
			local SpeedThresholds = Behavior.SpeedThresholds
			local CosmeticObject  = Runtime.CosmeticBulletObject
			if (TravelWanted and Behavior.FireTravelEvents)
				or CosmeticObject ~= nil
				or (ThresholdsWanted and SpeedThresholds ~= nil and #SpeedThresholds > 0)
			then
				local ReportRuntime = Runtime.ConfirmedRuntime or Runtime.TotalRuntime
				if ReportRuntime > Runtime.TotalRuntime then
					ReportRuntime = Runtime.TotalRuntime
				end

				local Trajectory  = Runtime.ActiveTrajectory
				local ElapsedTime = ReportRuntime - Trajectory.StartTime
				local Position    = PositionAtTime(
					ElapsedTime, Trajectory.Origin, Trajectory.InitialVelocity, Trajectory.Acceleration
				)
				local Velocity = VelocityAtTime(
					ElapsedTime, Trajectory.InitialVelocity, Trajectory.Acceleration
				)

				StepSpeedProfiles(Solver_, Cast, Velocity)
				FireOnTravel(Solver_, Cast, Position, Velocity)
				if CosmeticObject ~= nil then
					local Orientation = Behavior.SixDOFEnabled and Runtime.Orientation or nil
					PlaceCosmetic(Cast, Position, Velocity, Orientation, CosmeticCtx)
				end
			end
		end
	end

	for _, Record in self._DynOccInstances do
		local DynOcc  = Record.Occ
		local ShapeST = Record.ShapeST
		local XformST = Record.XformST
		local BoundST = Record.BoundST
		local WorldST = Record.WorldST
		local ShapeIds = Record.ShapeIds

		DynOcc:UpdateTransforms()

		local shapes = DynOcc._shapes
		local xforms = DynOcc._xforms
		local bounds = DynOcc._bounds
		local world  = DynOcc._world

		WorldST[1] = world[1]; WorldST[2] = world[2]; WorldST[3] = world[3]
		WorldST[4] = world[4]; WorldST[5] = world[5]; WorldST[6] = world[6]

		for _, id in DynOcc._active do
			XformST[id] = xforms[id]
			local b = id * 6
			BoundST[b - 5] = bounds[b - 5]; BoundST[b - 4] = bounds[b - 4]; BoundST[b - 3] = bounds[b - 3]
			BoundST[b - 2] = bounds[b - 2]; BoundST[b - 1] = bounds[b - 1]; BoundST[b]     = bounds[b]
		end

		for id, blob in shapes do
			if not ShapeIds[id] and xforms[id] ~= nil then
				ShapeST[id]  = blob
				ShapeIds[id] = true
			end
		end

		for id in ShapeIds do
			if shapes[id] == nil then
				ShapeST[id]  = nil
				XformST[id]  = nil
				local b = id * 6
				BoundST[b - 5] = nil; BoundST[b - 4] = nil; BoundST[b - 3] = nil
				BoundST[b - 2] = nil; BoundST[b - 1] = nil; BoundST[b]     = nil
				ShapeIds[id] = nil
			end
		end
	end

	local Solver    = self._Solver
	local Terminate = Solver._Terminate

	self._FrameIndex += 1
	local FrameIndex  = self._FrameIndex

	local ReadBufferIndex = (FrameIndex - 1) % 2 + 1
	local CastById        = self._CastById
	local HitInstances    = self._HitInstances

	local ProfEnabled = Profiler.Enabled
	local AccUnpack   = 0
	local AccDispatch = 0
	local EventTally  = 0

	for ShardIndex = 1, self._ShardCount do
		local ShardTable = self._ShardBuffers[ShardIndex][ReadBufferIndex]
		local EventCount = ShardTable["count"]

		if EventCount > 0 then
			local Data   = ShardTable["data"]
			local Buffer = buffer_fromstring(Data)
			local Offset = ResultBuffer.HEADER_SIZE
			for _ = 1, EventCount do
				if PeekEventTag(Buffer, Offset) == EVENT_TRAVEL_LITE then
					local _pU; if ProfEnabled then _pU = os_clock() end
					local CastId, Position, Velocity, TotalRuntime
					CastId, Position, Velocity, TotalRuntime, Offset = ReadTravelLite(Buffer, Offset)
					if ProfEnabled then AccUnpack += os_clock() - _pU end
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local _pD; if ProfEnabled then _pD = os_clock() end
						HandleTravelLite(Solver, Cast, Position, Velocity, TotalRuntime, CosmeticCtx)
						if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
					end
					continue
				end

				if PeekEventTag(Buffer, Offset) == EVENT_TRAVEL_HOMING_LITE then
					local _pU; if ProfEnabled then _pU = os_clock() end
					local CastId, Position, Velocity, TotalRuntime, HomingElapsed, TrajOrigin, TrajStartTime
					CastId, Position, Velocity, TotalRuntime, HomingElapsed, TrajOrigin, TrajStartTime, Offset =
						ReadTravelHomingLite(Buffer, Offset)
					if ProfEnabled then AccUnpack += os_clock() - _pU end
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local _pD; if ProfEnabled then _pD = os_clock() end
						HandleTravelHomingLite(
							Solver, Cast, Position, Velocity, TotalRuntime,
							HomingElapsed, TrajOrigin, TrajStartTime, CosmeticCtx
						)
						if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
					end
					continue
				end

				local _pU; if ProfEnabled then _pU = os_clock() end
				local EventData
				EventData, Offset = ResultBuffer.UnpackEvent(Buffer, Offset)
				if ProfEnabled then AccUnpack += os_clock() - _pU end
				local CastId = EventData.Id
				local Cast   = CastById[CastId]
				if not Cast or not Cast.Alive then continue end
				local Recovered = HitInstances[CastId]
				CosmeticCtx.HitInstance = Recovered
				if Recovered ~= nil then
					HitInstances[CastId] = nil
				end
				local Handler = EventHandlers[EventData.Event]
				if Handler then
					local _pD; if ProfEnabled then _pD = os_clock() end
					Handler(self, Solver, Cast, EventData, Terminate, CosmeticCtx)
					if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
				end
			end
			ShardTable["count"] = 0
		end

		local FFTable = self._FFBuffers[ShardIndex]
		local FFCount = FFTable["count"]

		if FFCount > 0 then
			local Data   = FFTable["data"]
			local Buffer = buffer_fromstring(Data)
			local Offset = ResultBuffer.HEADER_SIZE
			for _ = 1, FFCount do
				if PeekEventTag(Buffer, Offset) == EVENT_THROTTLE_STATE then
					local CastId, TotalRuntime, IsThrottled
					CastId, TotalRuntime, IsThrottled, Offset = ReadThrottleState(Buffer, Offset)
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local R = Cast.Runtime
						R.IsThrottled      = IsThrottled
						R.ConfirmedRuntime = TotalRuntime
					end
					continue
				end

				if PeekEventTag(Buffer, Offset) == EVENT_TRAVEL_LITE then
					local _pU; if ProfEnabled then _pU = os_clock() end
					local CastId, Position, Velocity, TotalRuntime
					CastId, Position, Velocity, TotalRuntime, Offset = ReadTravelLite(Buffer, Offset)
					if ProfEnabled then AccUnpack += os_clock() - _pU end
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local _pD; if ProfEnabled then _pD = os_clock() end
						HandleTravelLite(Solver, Cast, Position, Velocity, TotalRuntime, CosmeticCtx)
						if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
					end
					continue
				end

				if PeekEventTag(Buffer, Offset) == EVENT_TRAVEL_HOMING_LITE then
					local _pU; if ProfEnabled then _pU = os_clock() end
					local CastId, Position, Velocity, TotalRuntime, HomingElapsed, TrajOrigin, TrajStartTime
					CastId, Position, Velocity, TotalRuntime, HomingElapsed, TrajOrigin, TrajStartTime, Offset =
						ReadTravelHomingLite(Buffer, Offset)
					if ProfEnabled then AccUnpack += os_clock() - _pU end
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local _pD; if ProfEnabled then _pD = os_clock() end
						HandleTravelHomingLite(
							Solver, Cast, Position, Velocity, TotalRuntime,
							HomingElapsed, TrajOrigin, TrajStartTime, CosmeticCtx
						)
						if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
					end
					continue
				end

				local TrajTag = PeekEventTag(Buffer, Offset)
				if TrajTag == EVENT_TRAJ_UPDATE_LITE or TrajTag == EVENT_TRAJ_UPDATE_6DOF then
					local _pU; if ProfEnabled then _pU = os_clock() end
					local CastId, TotalRuntime, DistanceCovered, TrajOrigin, TrajVelocity, TrajAccel, TrajStartTime =
						ReadTrajUpdateLite(Buffer, Offset)
					local Orientation, AngularVelocity, AngleOfAttack
					if TrajTag == EVENT_TRAJ_UPDATE_6DOF then
						Orientation, AngularVelocity, AngleOfAttack, Offset = ReadTrajUpdate6DOFTail(Buffer, Offset)
					else
						Offset += TRAJ_LITE_SIZE_C
					end
					if ProfEnabled then AccUnpack += os_clock() - _pU end
					local Cast = CastById[CastId]
					if Cast and Cast.Alive then
						local _pD; if ProfEnabled then _pD = os_clock() end
						HandleTrajUpdateLite(
							Cast, TotalRuntime, DistanceCovered,
							TrajOrigin, TrajVelocity, TrajAccel, TrajStartTime,
							Orientation, AngularVelocity, AngleOfAttack
						)
						if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
					end
					continue
				end

				local _pU; if ProfEnabled then _pU = os_clock() end
				local EventData
				EventData, Offset = ResultBuffer.UnpackEvent(Buffer, Offset)
				if ProfEnabled then AccUnpack += os_clock() - _pU end
				local CastId = EventData.Id
				local Cast   = CastById[CastId]
				if not Cast or not Cast.Alive then continue end
				local Recovered = HitInstances[CastId]
				CosmeticCtx.HitInstance = Recovered
				if Recovered ~= nil then
					HitInstances[CastId] = nil
				end
				local Handler = EventHandlers[EventData.Event]
				if Handler then
					local _pD; if ProfEnabled then _pD = os_clock() end
					Handler(self, Solver, Cast, EventData, Terminate, CosmeticCtx)
					if ProfEnabled then AccDispatch += os_clock() - _pD; EventTally += 1 end
				end
			end
			FFTable["count"] = 0
		end
	end

	if ProfEnabled then
		Profiler.Add(Profiler.Phase.CoordUnpack, AccUnpack)
		Profiler.Add(Profiler.Phase.CoordDispatch, AccDispatch)
		Profiler.CountN(Profiler.Counter.CoordEvents, EventTally)
	end

	if #CosmeticParts > 0 then
		local _pC; if ProfEnabled then _pC = os_clock() end
		workspace:BulkMoveTo(
			CosmeticParts, CosmeticCFrames,
			Enum.BulkMoveMode.FireCFrameChanged
		)
		if ProfEnabled then Profiler.Add(Profiler.Phase.CoordCosmetic, os_clock() - _pC) end
	end

	local _pF; if ProfEnabled then _pF = os_clock() end
	FireHelpers.FlushTravelBatch(Solver)
	if ProfEnabled then Profiler.Add(Profiler.Phase.CoordFlush, os_clock() - _pF) end

	if ProfEnabled then Profiler.MarkFrame() end

	local SpatialConfig = Solver._SpatialConfig
	if SpatialConfig and SpatialConfig.Enabled then
		Solver._SpatialFrameCounter = (Solver._SpatialFrameCounter or 0) + 1
		if Solver._SpatialFrameCounter >= SpatialConfig.UpdateInterval then
			Solver._SpatialFrameCounter = 0
			local SpatialPartition      = require(Vetra.Simulation.SpatialPartition)
			SpatialPartition.Rebuild(Solver)

			local Keys:  { number } = {}
			local Tiers: { number } = {}
			local _n = 0
			for Key, Tier in Solver._SpatialGrid do
				_n += 1
				Keys[_n]  = Key
				Tiers[_n] = Tier
			end
			for Index = 1, self._ShardCount do
				self._Actors[Index]:SendMessage(
					"UpdateSpatialGrid",
					Keys, Tiers, SpatialConfig.CellSize, SpatialConfig.FallbackTier
				)
			end
		end
	end

	local Wind = Solver._Wind
	if Wind ~= self._LastBroadcastWind then
		self._LastBroadcastWind = Wind
		for Index = 1, self._ShardCount do
			self._Actors[Index]:SendMessage("UpdateWind", Wind)
		end
	end

	local LODOrigin = Solver._LODOrigin
	if LODOrigin ~= self._LastBroadcastLODOrigin then
		self._LastBroadcastLODOrigin = LODOrigin
		for Index = 1, self._ShardCount do
			self._Actors[Index]:SendMessage("UpdateLODOrigin", LODOrigin)
		end
	end

	local _pP0 = 0
	if ProfEnabled then _pP0 = os_clock() end

	local AccProvUser = 0
	local AccProvSend = 0
	local AccProvMath = 0

	if self._CastsWithProviderCount > 0 then
		for CastId, Cast in self._CastsWithProviders do
			if not Cast.Alive or Cast.Paused then continue end
			if Suspended[CastId]             then continue end

			local NeedsHoming   = Cast.Behavior.HomingPositionProvider     ~= nil
			local NeedsProvider = Cast.Behavior.TrajectoryPositionProvider ~= nil

			if NeedsHoming and Cast.Runtime.HomingDisengaged then
				NeedsHoming = false
			end
			if not NeedsHoming and not NeedsProvider then continue end

			local ShardIndex = self._CastToShard[CastId]
			if not ShardIndex then continue end

			local _pM; if ProfEnabled then _pM = os_clock() end
			local Runtime          = Cast.Runtime
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local ElapsedTime      = (Runtime.TotalRuntime + FrameDelta) - ActiveTrajectory.StartTime
			local CurrentPosition  = ActiveTrajectory.Origin
				+ ActiveTrajectory.InitialVelocity * ElapsedTime
				+ ActiveTrajectory.Acceleration    * (ElapsedTime * ElapsedTime * 0.5)
			local CurrentVelocity  = ActiveTrajectory.InitialVelocity
				+ ActiveTrajectory.Acceleration * ElapsedTime
			if ProfEnabled then AccProvMath += os_clock() - _pM end

			if NeedsHoming then
				local CanHome = true
				if Cast.Behavior.CanHomeFunction then
					local Context         = Solver._CastToBulletContext[Cast]
					local _pU1; if ProfEnabled then _pU1 = os_clock() end
					local Success, Result = pcall(Cast.Behavior.CanHomeFunction, Context, CurrentPosition, CurrentVelocity)
					if ProfEnabled then AccProvUser += os_clock() - _pU1 end
					if not Success then
						warn(`CanHomeFunction errored for cast {Cast.Id} — homing skipped this frame: {Result}`)
					end
					CanHome               = Success and Result == true
				end

				local ResolvedTarget: Vector3? = nil
				if CanHome then
					Runtime.HomingProviderThread = coroutine.running()
					local _pU2; if ProfEnabled then _pU2 = os_clock() end
					local Success, Target        = pcall(Cast.Behavior.HomingPositionProvider, CurrentPosition, CurrentVelocity)
					if ProfEnabled then AccProvUser += os_clock() - _pU2 end
					Runtime.HomingProviderThread = nil
					ResolvedTarget               = (Success and typeof(Target) == "Vector3") and Target or nil

					if not Success then
						warn(`HomingPositionProvider errored for cast {Cast.Id} — homing skipped this frame: {Target}`)
					end

					if Success and ResolvedTarget == nil and Runtime.HomingAcquired then
						Runtime.HomingDisengaged = true
						FireHelpers.FireOnHomingDisengaged(Solver, Cast)
					end

					if ResolvedTarget and not Runtime.HomingAcquired then
						local AcquisitionRadius = Cast.Behavior.HomingAcquisitionRadius
						local Acquired
						if AcquisitionRadius <= 0 then
							Acquired = true
						else
							local ToTarget = ResolvedTarget - CurrentPosition
							Acquired = ToTarget:Dot(ToTarget) <= AcquisitionRadius * AcquisitionRadius
						end

						if Acquired then
							Runtime.HomingAcquired = true
							self._Actors[ShardIndex]:SendMessage("UpdateHomingAcquired", Cast.Id, true)
						end
					end

					if not Runtime.HomingAcquired then
						ResolvedTarget = nil
					end
				end

				local _pS; if ProfEnabled then _pS = os_clock() end
				self._Actors[ShardIndex]:SendMessage("UpdateHoming", Cast.Id, ResolvedTarget)
				if ProfEnabled then AccProvSend += os_clock() - _pS end
			end

			if NeedsProvider then
				local Provider    = Cast.Behavior.TrajectoryPositionProvider
				local LastTime    = Runtime.TotalRuntime
				local CurrentTime = Runtime.TotalRuntime + FrameDelta

				Runtime.TrajectoryProviderThread    = coroutine.running()
				local SuccessLast, LastPosition     = pcall(Provider, LastTime)
				Runtime.TrajectoryProviderThread    = nil

				Runtime.TrajectoryProviderThread    = coroutine.running()
				local SuccessCurrent, CurrentPos    = pcall(Provider, CurrentTime)
				Runtime.TrajectoryProviderThread    = nil

				local ProviderVelocity: Vector3? = nil
				if SuccessCurrent and typeof(CurrentPos) == "Vector3" then
					Runtime.TrajectoryProviderThread      = coroutine.running()
					local SuccessForward, ForwardPosition = pcall(Provider, CurrentTime + PROVIDER_VELOCITY_EPSILON)
					Runtime.TrajectoryProviderThread      = nil
					if SuccessForward and typeof(ForwardPosition) == "Vector3" then
						ProviderVelocity = (ForwardPosition - CurrentPos) / PROVIDER_VELOCITY_EPSILON
					end
				end

				self._Actors[ShardIndex]:SendMessage(
					"UpdateProviderPositions",
					Cast.Id,
					(SuccessLast    and typeof(LastPosition) == "Vector3") and LastPosition or nil,
					(SuccessCurrent and typeof(CurrentPos)   == "Vector3") and CurrentPos   or nil,
					ProviderVelocity
				)
			end
		end
	end

	if ProfEnabled then
		Profiler.Add(Profiler.Phase.CoordProvider, os_clock() - _pP0)
		Profiler.Add(Profiler.Phase.CoordProvUser, AccProvUser)
		Profiler.Add(Profiler.Phase.CoordProvSend, AccProvSend)
		Profiler.Add(Profiler.Phase.CoordProvMath, AccProvMath)
	end

	local ShardSyncCount_ = self._ShardSyncCount
	for Index = 1, self._ShardCount do
		if ShardSyncCount_[Index] > 0 then
			self._Actors[Index]:SendMessage("StepShard", FrameDelta, FrameIndex)
		end
	end
end

function Coordinator:Destroy()
	self._Destroyed = true
	for _, Conn in self._HitConns do
		Conn:Disconnect()
	end
	for _, Conn in self._ReadyConns do
		Conn:Disconnect()
	end
	for Index, Actor in self._Actors do
		Actor:Destroy()
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A",  SharedTable.new())
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B",  SharedTable.new())
	end
	self._Actors         = nil
	self._ReadyConns     = nil
	self._OccGridBlobs   = nil
	self._DynOccInstances = nil
	self._DynOccIds       = nil
	self._ShardBuffers   = nil
	self._FFBuffers      = nil
	self._Solver         = nil
	self._CastToShard    = nil
	self._CastById       = nil
	self._SuspendedCasts = nil
	self._CastNeedsSync  = nil
	self._CastsWithProviders     = nil
	self._CastsWithProviderCount = 0
	self._ShardSyncCount = nil
	self._HitInstances   = nil
	self._HitConns       = nil
end

return table.freeze(Coordinator)
