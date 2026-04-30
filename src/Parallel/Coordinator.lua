--!optimize 2
--!strict

-- ─── Coordinator ─────────────────────────────────────────────────────────────
--[[
    V4 Parallel Coordinator — actor-resident state + double-buffered SharedTable results.

    ── Double-buffer design (NeedsSync=true casts) ───────────────────────────────

    Two SharedTables per shard — "A" (index 1) and "B" (index 2).

        Frame N:   Actor writes to buffers[N % 2 + 1]        (e.g. B)
                   Coordinator reads buffers[(N-1) % 2 + 1]  (e.g. A — previous frame)

    Actor and Coordinator always operate on different buffers → zero contention,
    no locking, no CAS, no clone() needed.

    ── FF buffer design (NeedsSync=false casts) ──────────────────────────────────

    One SharedTable per shard — "VetraShard_N_FF".
    FF casts step via PreSimulation:ConnectParallel, which always completes
    before Heartbeat. The Coordinator's Step() runs on Heartbeat, so by the
    time Phase 1 polls the FF buffer, the Actor has finished writing for this
    frame. No double-buffer, no BindableEvent, no clone() needed.

    Only terminal events (Hit / DistanceEnd / SpeedEnd) are written to the FF
    buffer. Travel and Skip require no main-thread action for NeedsSync=false
    casts. NeedsSync=false casts do not fire travel signals or update cosmetic
    parts — they are pure simulation with terminal event delivery only.

    ── SharedTable allocation strategy ──────────────────────────────────────────

    ActorWorker uses WriteEventToBuffer() which reuses the SharedTable already
    sitting at Buffer[Index] from 2 frames ago (double-buffer guarantee).
    Sub-tables (Trajectory, BouncePositionHistory) are likewise reused in-place.
    After warm-up, zero SharedTable.new() calls occur per frame for steady-state
    casts. PackEvent / PackTravelEvent have been removed entirely.

    ── Per-frame main-thread cost ────────────────────────────────────────────────

    Phase 1:  O(shards) — direct SharedTable reads, no clone
    Phase 2:  O(activeCasts) cosmetics flush
    Phase 3:  spatial partition (conditional)
    Phase 4:  O(shards) wind/LOD broadcast (conditional)
    Phase 5:  O(syncCasts) — homing + provider push
    Phase 6:  O(shards with sync casts) — StepShard dispatch

]]

local Identity     = "Coordinator"
local Coordinator  = {}
Coordinator.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local RunService          = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Parallel = script.Parent
local Vetra    = script.Parent.Parent
local Core     = Vetra.Core
local Signals  = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService     = require(Core.Logger)
local Constants      = require(Core.Constants)
local FireHelpers    = require(Signals.FireHelpers)
local EventHandlers  = require(Parallel.Physics.EventHandlers)
local TypeDefinition = require(Core.TypeDefinition)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local ZERO_VECTOR               = Constants.ZERO_VECTOR
local PROVIDER_VELOCITY_EPSILON = Constants.PROVIDER_VELOCITY_EPSILON

-- ─── Constants ───────────────────────────────────────────────────────────────

local DEFAULT_SHARD_COUNT  = 4
local CoordinatorMetatable = table.freeze({ __index = Coordinator })

local ActorWorker_Client = Parallel.ActorTemplate.ActorWorker_Client
local ActorWorker_Server = Parallel.ActorTemplate.ActorWorker_Server
local WorkerTemplate     = RunService:IsClient() and ActorWorker_Client or ActorWorker_Server

-- ─── Types ───────────────────────────────────────────────────────────────────

type CastSnapshot   = TypeDefinition.CastSnapshot
type VetraCast      = TypeDefinition.VetraCast
type ResumeSyncData = TypeDefinition.ResumeSyncData

-- ─── Module ──────────────────────────────────────────────────────────────────

function Coordinator.new(Solver: any, Config: any?)
	Config = Config or {}

	local ShardCount  = Config.ShardCount or DEFAULT_SHARD_COUNT
	local ActorParent = Config.ActorParent or Parallel

	if not WorkerTemplate then
		Logger:Error("Coordinator.new: ActorWorker script not found in Parallel/ActorTemplate")
		return nil
	end

	local Actors:       { Actor }            = {}
	local ShardBuffers: { { SharedTable } }  = {}
	local FFBuffers:    { SharedTable }      = {}  -- one per shard, polled in Phase 1

	local ShardSyncCount: { [number]: number } = {}
	for Index = 1, ShardCount do
		ShardSyncCount[Index] = 0
	end

	for Index = 1, ShardCount do
		local SharedTableA = SharedTable.new()
		local SharedTableB = SharedTable.new()
		SharedTableA["count"] = 0
		SharedTableB["count"] = 0

		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A", SharedTableA)
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B", SharedTableB)
		ShardBuffers[Index] = { SharedTableA, SharedTableB }

		-- FF buffer for this shard. Passed directly to the Actor via Init so
		-- it never needs to look it up by name. The Coordinator polls it in
		-- Phase 1 without cloning — PreSimulation:ConnectParallel finishes
		-- before Heartbeat, so the write is always complete by read time.
		-- Slot SharedTables are reused by WriteEventToBuffer in the Actor;
		-- the Coordinator only needs to reset ["count"] after draining.
		local FFBuffer        = SharedTable.new()
		FFBuffer["count"]     = 0
		FFBuffers[Index]      = FFBuffer

		local Actor  = Instance.new("Actor")
		Actor.Name   = "VetraShard_" .. Index

		local Reference  = Instance.new("ObjectValue")
		Reference.Name   = "ParallelReference"
		Reference.Value  = Parallel
		Reference.Parent = Actor

		local Worker   = WorkerTemplate:Clone()
		Worker.Parent  = Actor
		Worker.Enabled = true
		Actor.Parent   = ActorParent

		-- Defer Init so the worker script has registered its BindToMessage
		-- handlers before the message arrives. Pass all three SharedTables
		-- directly so the Actor never needs a registry lookup.
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

	return setmetatable({
		_Solver       = Solver,
		_ShardCount   = ShardCount,
		_Actors       = Actors,
		_ShardBuffers = ShardBuffers,
		_FFBuffers    = FFBuffers,

		-- CastId → ShardIndex
		_CastToShard = {} :: { [number]: number },
		_NextShard   = 1,

		-- CastId → Cast
		_CastById = {} :: { [number]: VetraCast },

		-- CastId → true for casts awaiting bounce/pierce resolution
		_SuspendedCasts = {} :: { [number]: true },

		-- Frame counter drives double-buffer slot selection.
		_FrameIndex = 0,

		-- Change-detection for broadcast messages
		_LastBroadcastWind      = ZERO_VECTOR :: Vector3,
		_LastBroadcastLODOrigin = nil         :: Vector3?,

		-- Per-cast sync flag
		_CastNeedsSync = {} :: { [number]: boolean },
		-- Running count of NeedsSync=true casts
		_SyncCastCount = 0,
		-- Per-shard count of NeedsSync=true casts.
		-- Phase 6 uses this to skip StepShard for FF-only shards.
		_ShardSyncCount = ShardSyncCount,

		_Destroyed = false,

		-- Pre-allocated reusable message table for AddCast SendMessage calls.
		_AddCastMessage = {
			Id = 0,

			TrajectoryOrigin          = Vector3.zero,
			TrajectoryInitialVelocity = Vector3.zero,
			TrajectoryAcceleration    = Vector3.zero,
			TrajectoryStartTime       = 0,

			TotalRuntime       = 0,
			DistanceCovered    = 0,
			IsSupersonic       = false,
			LastDragRecalculateTime = 0,
			SpinVector         = Vector3.zero,
			HomingElapsed      = 0,
			HomingDisengaged   = false,
			HomingAcquired     = false,
			CurrentSegmentSize = 0,
			BounceCount        = 0,
			BouncesThisFrame   = 0,
			PierceCount        = 0,
			LastBounceTime     = 0,

			IsLOD                   = false,
			LODDistance             = 0,
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

			PierceSpeedThreshold      = 0,
			PierceSpeedRetention      = 0,
			PierceNormalBias          = 0,

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

			GyroDriftRate  = nil,
			GyroDriftAxis  = nil,

			IsTumbling             = false,
			TumbleRandom           = nil,
			TumbleSpeedThreshold   = nil,
			TumbleDragMultiplier   = nil,
			TumbleLateralStrength  = nil,
			TumbleOnPierce         = false,
			TumbleRecoverySpeed    = nil,

			RaycastParams  = nil,
			VisualizeCasts = false,

			CoriolisOmega = Vector3.zero,

			NeedsSync = false,
		},
	}, CoordinatorMetatable)
end

-- ─── AddCast ─────────────────────────────────────────────────────────────────

function Coordinator:AddCast(Cast: VetraCast)
	local ShardIndex           = self._NextShard
	self._NextShard            = (ShardIndex % self._ShardCount) + 1
	self._CastToShard[Cast.Id] = ShardIndex
	self._CastById[Cast.Id]    = Cast

	local Solver           = self._Solver
	local Runtime          = Cast.Runtime
	local Behavior         = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory
	local RaycastParams    = Behavior.RaycastParams

	local HasCallbacks = Behavior.CanBounceFunction          ~= nil
		or Behavior.CanPierceFunction          ~= nil
		or Behavior.CanHomeFunction            ~= nil
		or Behavior.HomingPositionProvider     ~= nil
		or Behavior.TrajectoryPositionProvider ~= nil

	local NeedsSync = Behavior.FireTravelEvents == true or HasCallbacks
	self._CastNeedsSync[Cast.Id] = NeedsSync
	if NeedsSync then
		self._SyncCastCount             += 1
		self._ShardSyncCount[ShardIndex] = (self._ShardSyncCount[ShardIndex] or 0) + 1
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
	Message.CornerEMAAlpha              = Behavior.CornerEMAAlpha  or 0.4
	Message.CornerEMAThreshold          = Behavior.CornerEMAThreshold or 0.15
	Message.CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce

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
	Message.TumbleRandom          = Cast.Runtime.TumbleRandom
	Message.TumbleSpeedThreshold  = Behavior.TumbleSpeedThreshold
	Message.TumbleDragMultiplier  = Behavior.TumbleDragMultiplier
	Message.TumbleLateralStrength = Behavior.TumbleLateralStrength
	Message.TumbleOnPierce        = Behavior.TumbleOnPierce
	Message.TumbleRecoverySpeed   = Behavior.TumbleRecoverySpeed

	Message.RaycastParams  = RaycastParams
	Message.VisualizeCasts = Behavior.VisualizeCasts

	Message.CoriolisOmega = Solver._CoriolisOmega or Vector3.zero
	Message.NeedsSync     = NeedsSync

	self._Actors[ShardIndex]:SendMessage("AddCast", Message)
end

-- ─── RemoveCast ──────────────────────────────────────────────────────────────

function Coordinator:RemoveCast(CastId: number)
	local ShardIndex = self._CastToShard[CastId]
	if not ShardIndex then return end
	self._CastToShard[CastId]    = nil
	self._SuspendedCasts[CastId] = nil
	self._CastById[CastId]       = nil
	if self._CastNeedsSync[CastId] then
		self._SyncCastCount             -= 1
		self._ShardSyncCount[ShardIndex] -= 1
	end
	self._CastNeedsSync[CastId] = nil
	self._Actors[ShardIndex]:SendMessage("RemoveCast", CastId)
end

-- ─── _UpdateFilter ───────────────────────────────────────────────────────────

function Coordinator:_UpdateFilter(Cast: VetraCast)
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	self._Actors[ShardIndex]:SendMessage(
		"UpdateFilter",
		Cast.Id,
		Cast.Behavior.RaycastParams.FilterDescendantsInstances
	)
end

-- ─── _ResumeCast ─────────────────────────────────────────────────────────────

function Coordinator:_ResumeCast(Cast: VetraCast, SyncData: ResumeSyncData)
	self._SuspendedCasts[Cast.Id] = nil
	local ShardIndex = self._CastToShard[Cast.Id]
	if not ShardIndex then return end
	self._Actors[ShardIndex]:SendMessage("ResumeCast", Cast.Id, SyncData)
end

-- ─── Step ────────────────────────────────────────────────────────────────────

function Coordinator:Step(FrameDelta: number)

	-- ── 0. Early exit ─────────────────────────────────────────────────────────
	local ActiveCasts = self._Solver._ActiveCasts
	if #ActiveCasts == 0 then return end

	local Solver    = self._Solver
	local Terminate = Solver._Terminate

	self._FrameIndex += 1
	local FrameIndex  = self._FrameIndex

	local CosmeticParts:   { BasePart } = {}
	local CosmeticCFrames: { CFrame }   = {}
	local Suspended = self._SuspendedCasts

	-- ── 1. Apply results ──────────────────────────────────────────────────────
	-- Sync casts: read the double-buffer slot the Actor wrote last frame.
	-- The Actor writes slot [FrameIndex % 2 + 1] and we read
	-- [(FrameIndex-1) % 2 + 1] — always opposite, no clone needed.
	-- Slot SharedTables are reused in-place by WriteEventToBuffer in the Actor;
	-- the Coordinator reads them without modification.
	--
	-- FF casts: poll the FF buffer directly. PreSimulation:ConnectParallel
	-- always completes before Heartbeat, so the write is guaranteed done.
	-- After draining, reset ["count"] to 0 so the Actor starts fresh next
	-- PreSimulation (slot SharedTables are retained for reuse).
	local ReadBufferIndex = (FrameIndex - 1) % 2 + 1
	local CastById        = self._CastById
	local CosmeticCtx     = { CosmeticParts = CosmeticParts, CosmeticCFrames = CosmeticCFrames }

	for ShardIndex = 1, self._ShardCount do

		-- ── Sync cast results (double-buffered) ───────────────────────────
		local ShardTable  = self._ShardBuffers[ShardIndex][ReadBufferIndex]
		local EventCount  = ShardTable["count"]

		if EventCount > 0 then
			for EventIndex = 1, EventCount do
				local EventData = ShardTable[EventIndex]
				local Cast      = CastById[EventData["Id"]]
				if not Cast or not Cast.Alive then continue end
				local Handler = EventHandlers[EventData["Event"]]
				if Handler then
					Handler(self, Solver, Cast, EventData, Terminate, CosmeticCtx)
				end
			end
		end

		-- ── FF cast results (single buffer, polled) ───────────────────────
		local FFTable    = self._FFBuffers[ShardIndex]
		local FFCount    = FFTable["count"]

		if FFCount > 0 then
			for EventIndex = 1, FFCount do
				local EventData = FFTable[EventIndex]
				local Cast      = CastById[EventData["Id"]]
				if not Cast or not Cast.Alive then continue end
				local Handler = EventHandlers[EventData["Event"]]
				if Handler then
					Handler(self, Solver, Cast, EventData, Terminate, nil)
				end
			end
			-- Reset count so the Actor's WriteEventToBuffer cursor starts at 1
			-- next PreSimulation. Slot SharedTables are intentionally retained —
			-- they will be reused in-place with zero allocations next frame.
			FFTable["count"] = 0
		end
	end

	-- ── 2. BulkMoveTo cosmetics flush ─────────────────────────────────────────
	if #CosmeticParts > 0 then
		workspace:BulkMoveTo(
			CosmeticParts, CosmeticCFrames,
			Enum.BulkMoveMode.FireCFrameChanged
		)
	end
	FireHelpers.FlushTravelBatch(Solver)

	-- ── 3. Spatial partition rebuild ──────────────────────────────────────────
	local SpatialConfig = Solver._SpatialConfig
	if SpatialConfig and SpatialConfig.Enabled then
		Solver._SpatialFrameCounter = (Solver._SpatialFrameCounter or 0) + 1
		if Solver._SpatialFrameCounter >= SpatialConfig.UpdateInterval then
			Solver._SpatialFrameCounter = 0
			local SpatialPartition      = require(Vetra.Simulation.SpatialPartition)
			SpatialPartition.Rebuild(Solver)
		end
	end

	-- ── 4. Wind / LODOrigin change-detection broadcast ────────────────────────
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

	-- ── 5. Homing + TrajectoryProvider updates ────────────────────────────────
	-- Only runs when at least one active cast requires main-thread sync.
	if self._SyncCastCount > 0 then
		for _, Cast in ActiveCasts do
			if not Cast.Alive or Cast.Paused    then continue end
			if Suspended[Cast.Id]               then continue end
			if not self._CastNeedsSync[Cast.Id] then continue end

			local NeedsHoming   = Cast.Behavior.HomingPositionProvider     ~= nil
			local NeedsProvider = Cast.Behavior.TrajectoryPositionProvider ~= nil
			if not NeedsHoming and not NeedsProvider then continue end

			local ShardIndex = self._CastToShard[Cast.Id]
			if not ShardIndex then continue end

			local Runtime          = Cast.Runtime
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local ElapsedTime      = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CurrentPosition  = ActiveTrajectory.Origin
				+ ActiveTrajectory.InitialVelocity * ElapsedTime
				+ ActiveTrajectory.Acceleration    * (ElapsedTime * ElapsedTime * 0.5)
			local CurrentVelocity  = ActiveTrajectory.InitialVelocity
				+ ActiveTrajectory.Acceleration * ElapsedTime

			if NeedsHoming then
				local CanHome = true
				if Cast.Behavior.CanHomeFunction then
					local Context         = Solver._CastToBulletContext[Cast]
					local Success, Result = pcall(Cast.Behavior.CanHomeFunction, Context, CurrentPosition, CurrentVelocity)
					CanHome               = Success and Result == true
				end

				local ResolvedTarget: Vector3? = nil
				if CanHome then
					Runtime.HomingProviderThread = coroutine.running()
					local Success, Target        = pcall(Cast.Behavior.HomingPositionProvider, CurrentPosition, CurrentVelocity)
					Runtime.HomingProviderThread = nil
					ResolvedTarget               = (Success and typeof(Target) == "Vector3") and Target or nil
				end

				self._Actors[ShardIndex]:SendMessage("UpdateHoming", Cast.Id, ResolvedTarget)
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

	-- ── 6. Dispatch ───────────────────────────────────────────────────────────
	-- Only shards with NeedsSync=true casts receive StepShard.
	-- Shards with only FF casts are stepped autonomously via ConnectParallel
	-- and do not need a dispatch message.
	local ShardSyncCount_ = self._ShardSyncCount
	for Index = 1, self._ShardCount do
		if ShardSyncCount_[Index] > 0 then
			self._Actors[Index]:SendMessage("StepShard", FrameDelta, FrameIndex)
		end
	end
end

-- ─── Destroy ─────────────────────────────────────────────────────────────────

function Coordinator:Destroy()
	self._Destroyed = true
	for Index, Actor in self._Actors do
		Actor:Destroy()
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A",  SharedTable.new())
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B",  SharedTable.new())
	end
	self._Actors         = nil
	self._ShardBuffers   = nil
	self._FFBuffers      = nil
	self._Solver         = nil
	self._CastToShard    = nil
	self._CastById       = nil
	self._SuspendedCasts = nil
	self._CastNeedsSync  = nil
	self._ShardSyncCount = nil
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local ModuleMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Coordinator: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Coordinator: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Coordinator, ModuleMetatable)