--!optimize 2
--!strict

-- ─── Coordinator ─────────────────────────────────────────────────────────────
--[[
    V4 Parallel Coordinator — actor-resident state + double-buffered SharedTable results.

    ── Double-buffer design ──────────────────────────────────────────────────────

    Two SharedTables per shard — "A" (index 1) and "B" (index 2) — registered
    under keys "VetraShard_N_A" and "VetraShard_N_B".

        Frame N:   Actor writes to buffers[N % 2 + 1]       (e.g. B)
                   Coordinator reads buffers[(N-1) % 2 + 1]  (e.g. A — previous frame)

        Frame N+1: Actor writes to buffers[(N+1) % 2 + 1]   (e.g. A)
                   Coordinator reads buffers[N % 2 + 1]      (e.g. B — previous frame)

    Actor and Coordinator always operate on different buffers → zero contention,
    no locking, no CAS. SharedTable.clone() of the read buffer gives an atomic
    snapshot of all shard results in one call.

    ── Per-frame main-thread cost ────────────────────────────────────────────────

    Apply pass:   O(shards) SharedTable reads + O(events) per shard with events
    Cosmetics:    O(activeCasts) — analytical, zero Actor communication
    Homing:       O(homingCasts) — user Lua, serial by necessity
    Dispatch:     O(shards) — one SendMessage("StepShard", delta, frameIndex) each

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
local Physics  = Vetra.Physics
local Signals  = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService      = require(Core.Logger)
local Constants       = require(Core.Constants)
local FireHelpers     = require(Signals.FireHelpers)
local EventHandlers   = require(Parallel.Physics.EventHandlers)
local TypeDefinition  = require(Core.TypeDefinition)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local cframe_new  = CFrame.new
local ZERO_VECTOR               = Constants.ZERO_VECTOR
local PROVIDER_VELOCITY_EPSILON = Constants.PROVIDER_VELOCITY_EPSILON
local PARALLEL_EVENT            = Constants.PARALLEL_EVENT

-- ─── Constants ───────────────────────────────────────────────────────────────

local DEFAULT_SHARD_COUNT  = 4
local CoordinatorMetatable = table.freeze({ __index = Coordinator })

local ActorWorker_Client = Parallel.ActorTemplate.ActorWorker_Client
local ActorWorker_Server = Parallel.ActorTemplate.ActorWorker_Server
local WorkerTemplate     = RunService:IsClient() and ActorWorker_Client or ActorWorker_Server

-- ─── Types ───────────────────────────────────────────────────────────────────

type CastSnapshot  = TypeDefinition.CastSnapshot
type VetraCast     = TypeDefinition.VetraCast
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

	local Actors: { Actor }             = {}
	local ShardBuffers: { { SharedTable } } = {}

	for Index = 1, ShardCount do
		local SharedTableA = SharedTable.new()
		local SharedTableB = SharedTable.new()
		SharedTableA["count"] = 0
		SharedTableB["count"] = 0

		-- Register BEFORE Actor starts so ActorWorker.Init can look them up
		-- immediately when it receives the Init message.
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A", SharedTableA)
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B", SharedTableB)
		ShardBuffers[Index] = { SharedTableA, SharedTableB }

		local Actor  = Instance.new("Actor")
		Actor.Name   = "VetraShard_" .. Index

		local Reference  = Instance.new('ObjectValue')
		Reference.Name   = "ParallelReference"
		Reference.Value  = Parallel
		Reference.Parent = Actor

		local Worker   = WorkerTemplate:Clone()
		Worker.Parent  = Actor
		Worker.Enabled = true
		Actor.Parent   = ActorParent

		-- Defer Init so the worker script has executed and registered its
		-- BindToMessage handlers before the message arrives.
		local ShardIndex = Index
		task.defer(function()
			Actor:SendMessage("Init", ShardBuffers[Index][1], ShardBuffers[Index][2])
		end)

		Actors[Index] = Actor
	end

	return setmetatable({
		_Solver     = Solver,
		_ShardCount = ShardCount,
		_Actors     = Actors,
		_ShardBuffers = ShardBuffers, -- { {SharedTableA, SharedTableB}, ... }

		-- CastId → ShardIndex (for targeted messages)
		_CastToShard = {} :: { [number]: number },
		_NextShard   = 1,

		-- CastId → Cast (maintained incrementally to avoid rebuilding each frame)
		_CastById = {} :: { [number]: VetraCast },

		-- CastId → true for casts awaiting bounce/pierce resolution
		_SuspendedCasts = {} :: { [number]: true },

		-- Frame counter drives double-buffer slot selection.
		-- Sent to Actors as part of StepShard so they write to the correct buffer.
		_FrameIndex = 0,

		-- Change-detection for broadcast messages
		_LastBroadcastWind      = ZERO_VECTOR :: Vector3,
		_LastBroadcastLODOrigin = nil         :: Vector3?,

		_Destroyed = false,

		-- Pre-allocated reusable table for AddCast SendMessage calls.
		-- Fields are overwritten in-place before every SendMessage("AddCast").
		-- Safe to reuse because SendMessage deep-copies into the Actor queue
		-- synchronously — the Coordinator holds no reference after the call.
		-- Eliminates one ~60-field table allocation per Fire() call.
		--
		-- Typed as CastSnapshot (the SSOT for all snapshot fields).
		-- Note: FilterType + FilterList replace RaycastParams here because
		-- RaycastParams cannot cross Actor boundaries — the Actor reconstructs
		-- its local RaycastParams on receipt.
		_AddCastMessage = {
			-- Identity
			Id = 0,

			-- Active trajectory
			TrajectoryOrigin          = Vector3.zero,
			TrajectoryInitialVelocity = Vector3.zero,
			TrajectoryAcceleration    = Vector3.zero,
			TrajectoryStartTime       = 0,

			-- Runtime scalars
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

			-- LOD / Spatial
			IsLOD                   = false,
			LODDistance             = 0,
			LODFrameAccumulator     = 0,
			LODDeltaAccumulator     = 0,
			SpatialFrameAccumulator = 0,
			SpatialDeltaAccumulator = 0,
			SpatialTier             = 1,
			LODOrigin               = nil,

			-- Bounce tracking (corner trap)
			BouncePositionHistory = nil,
			BouncePositionHead    = 0,
			VelocityDirectionEMA  = Vector3.zero,
			FirstBouncePosition   = nil,
			CornerBounceCount     = 0,

			-- Behavior: distance / speed limits
			MaxDistance        = 0,
			MinSpeed           = 0,
			MaxSpeed           = math.huge,
			MaxBounces         = 0,
			MaxBouncesPerFrame = 0,
			MaxPierceCount     = 0,

			-- Behavior: drag
			DragCoefficient     = 0,
			DragModel           = 0,
			DragSegmentInterval = 0,
			CustomMachTable     = nil,

			-- Behavior: bounce
			BounceSpeedThreshold = 0,
			Restitution          = 0,
			NormalPerturbation   = 0,
			MaterialRestitution  = nil,

			-- Behavior: pierce
			PierceSpeedThreshold      = 0,
			PenetrationSpeedRetention = 0,
			PierceNormalBias          = 0,

			-- Behavior: magnus
			MagnusCoefficient = 0,
			SpinDecayRate     = 0,

			-- Behavior: homing
			HomingStrength    = 0,
			HomingMaxDuration = 0,
			HomingTarget      = nil,

			-- Behavior: high fidelity
			HighFidelitySegmentSize = 0,
			AdaptiveScaleFactor     = 0,
			MinSegmentSize          = 0,
			HighFidelityFrameBudget = 0,

			-- Behavior: corner trap config
			CornerTimeThreshold         = 0,
			CornerDisplacementThreshold = 0,
			CornerEMAAlpha              = 0,
			CornerEMAThreshold          = 0,
			CornerMinProgressPerBounce  = 0,

			-- Callback presence flags (functions stay on main thread)
			HasCanPierceCallback = false,
			HasCanBounceCallback = false,
			HasCanHomeCallback   = false,

			-- Speed profiles
			SupersonicDragCoefficient = nil,
			SupersonicDragModel       = nil,
			SubsonicDragCoefficient   = nil,
			SubsonicDragModel         = nil,

			-- Physics environment
			BaseAcceleration = Vector3.zero,
			Wind             = Vector3.zero,
			WindResponse     = 0,

			-- Misc behavior
			GyroDriftRate  = nil,
			GyroDriftAxis  = nil,
			-- Tumble
			IsTumbling             = false,
			TumbleRandom           = nil,
			TumbleSpeedThreshold   = nil,
			TumbleDragMultiplier   = nil,
			TumbleLateralStrength  = nil,
			TumbleOnPierce         = false,
			TumbleRecoverySpeed    = nil,
			FilterType     = nil,
			FilterList     = nil,
			VisualizeCasts = false,

			-- [CORIOLIS] Zero by default; overwritten in AddCast from Solver._CoriolisOmega.
			CoriolisOmega  = Vector3.zero,
		},
	}, CoordinatorMetatable)
end

-- ─── AddCast ─────────────────────────────────────────────────────────────────

function Coordinator:AddCast(Cast: VetraCast)
	local ShardIndex              = self._NextShard
	self._NextShard               = (ShardIndex % self._ShardCount) + 1
	self._CastToShard[Cast.Id]    = ShardIndex
	self._CastById[Cast.Id]       = Cast

	local Solver          = self._Solver
	local Runtime         = Cast.Runtime
	local Behavior        = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory
	local RaycastParams   = Behavior.RaycastParams

	-- Serialize MaterialRestitution — Enum keys cannot cross Actor boundaries,
	-- so we convert them to their string representation first.
	local SerializedMaterialRestitution: { [string]: number }? = nil
	if Behavior.MaterialRestitution then
		SerializedMaterialRestitution = {}
		for Material, Value in Behavior.MaterialRestitution do
			SerializedMaterialRestitution[tostring(Material)] = Value
		end
	end

	local Message = self._AddCastMessage

	-- Identity
	Message.Id = Cast.Id

	-- Active trajectory
	Message.TrajectoryOrigin          = ActiveTrajectory.Origin
	Message.TrajectoryInitialVelocity = ActiveTrajectory.InitialVelocity
	Message.TrajectoryAcceleration    = ActiveTrajectory.Acceleration
	Message.TrajectoryStartTime       = ActiveTrajectory.StartTime

	-- Runtime scalars
	Message.TotalRuntime       = Runtime.TotalRuntime
	Message.DistanceCovered    = Runtime.DistanceCovered
	Message.IsSupersonic       = Runtime.IsSupersonic
	Message.LastDragRecalculateTime = Runtime.LastDragRecalculateTime
	Message.SpinVector         = Behavior.SpinVector
	Message.HomingElapsed      = Runtime.HomingElapsed
	Message.HomingDisengaged   = Runtime.HomingDisengaged
	Message.HomingAcquired     = Runtime.HomingAcquired
	Message.CurrentSegmentSize = Runtime.CurrentSegmentSize
	Message.BounceCount        = Runtime.BounceCount
	Message.BouncesThisFrame   = Runtime.BouncesThisFrame
	Message.PierceCount        = Runtime.PierceCount
	Message.LastBounceTime     = Runtime.LastBounceTime

	-- LOD / Spatial
	Message.IsLOD                   = Runtime.IsLOD
	Message.LODDistance             = Behavior.LODDistance
	Message.LODFrameAccumulator     = Runtime.LODFrameAccumulator
	Message.LODDeltaAccumulator     = Runtime.LODDeltaAccumulator
	Message.SpatialFrameAccumulator = Runtime.SpatialFrameAccumulator
	Message.SpatialDeltaAccumulator = Runtime.SpatialDeltaAccumulator
	Message.SpatialTier             = 1
	Message.LODOrigin               = Solver._LODOrigin

	-- Bounce tracking (corner trap)
	Message.BouncePositionHistory = Runtime.BouncePositionHistory
	Message.BouncePositionHead    = Runtime.BouncePositionHead
	Message.VelocityDirectionEMA  = Runtime.VelocityDirectionEMA
	Message.FirstBouncePosition   = Runtime.FirstBouncePosition
	Message.CornerBounceCount     = Runtime.CornerBounceCount

	-- Behavior: distance / speed limits
	Message.MaxDistance        = Behavior.MaxDistance
	Message.MinSpeed           = Behavior.MinSpeed
	Message.MaxSpeed           = Behavior.MaxSpeed
	Message.MaxBounces         = Behavior.MaxBounces
	Message.MaxBouncesPerFrame = Behavior.MaxBouncesPerFrame
	Message.MaxPierceCount     = Behavior.MaxPierceCount

	-- Behavior: drag
	Message.DragCoefficient     = Behavior.DragCoefficient
	Message.DragModel           = Behavior.DragModel
	Message.DragSegmentInterval = Behavior.DragSegmentInterval
	Message.CustomMachTable     = Behavior.CustomMachTable

	-- Behavior: bounce
	Message.BounceSpeedThreshold = Behavior.BounceSpeedThreshold
	Message.Restitution          = Behavior.Restitution
	Message.NormalPerturbation   = Behavior.NormalPerturbation
	Message.MaterialRestitution  = SerializedMaterialRestitution

	-- Behavior: pierce
	Message.PierceSpeedThreshold      = Behavior.PierceSpeedThreshold
	Message.PenetrationSpeedRetention = Behavior.PenetrationSpeedRetention
	Message.PierceNormalBias          = Behavior.PierceNormalBias

	-- Behavior: magnus
	Message.MagnusCoefficient = Behavior.MagnusCoefficient
	Message.SpinDecayRate     = Behavior.SpinDecayRate

	-- Behavior: homing
	Message.HomingStrength    = Behavior.HomingStrength
	Message.HomingMaxDuration = Behavior.HomingMaxDuration
	Message.HomingTarget      = nil

	-- Behavior: high fidelity
	Message.HighFidelitySegmentSize = Behavior.HighFidelitySegmentSize
	Message.AdaptiveScaleFactor     = Behavior.AdaptiveScaleFactor
	Message.MinSegmentSize          = Behavior.MinSegmentSize
	Message.HighFidelityFrameBudget = Behavior.HighFidelityFrameBudget

	-- Behavior: corner trap config
	Message.CornerTimeThreshold         = Behavior.CornerTimeThreshold
	Message.CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold
	Message.CornerEMAAlpha              = Behavior.CornerEMAAlpha  or 0.4
	Message.CornerEMAThreshold          = Behavior.CornerEMAThreshold or 0.15
	Message.CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce

	-- Callback presence flags
	Message.HasCanPierceCallback = Behavior.CanPierceFunction ~= nil
	Message.HasCanBounceCallback = Behavior.CanBounceFunction ~= nil
	Message.HasCanHomeCallback   = Behavior.CanHomeFunction   ~= nil

	-- Speed profiles
	Message.SupersonicDragCoefficient = Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragCoefficient or nil
	Message.SupersonicDragModel       = Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragModel       or nil
	Message.SubsonicDragCoefficient   = Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragCoefficient  or nil
	Message.SubsonicDragModel         = Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragModel        or nil

	-- Physics environment
	Message.BaseAcceleration = Solver._BaseAccelerationCache[Cast] or ZERO_VECTOR
	Message.Wind             = Solver._Wind
	Message.WindResponse     = Behavior.WindResponse

	-- Misc behavior
	Message.GyroDriftRate  = Behavior.GyroDriftRate
	Message.GyroDriftAxis  = Behavior.GyroDriftAxis
	-- Tumble — pass live Runtime state so the Actor starts in the correct tumble phase
	Message.IsTumbling            = Cast.Runtime.IsTumbling
	Message.TumbleRandom          = Cast.Runtime.TumbleRandom
	Message.TumbleSpeedThreshold  = Behavior.TumbleSpeedThreshold
	Message.TumbleDragMultiplier  = Behavior.TumbleDragMultiplier
	Message.TumbleLateralStrength = Behavior.TumbleLateralStrength
	Message.TumbleOnPierce        = Behavior.TumbleOnPierce
	Message.TumbleRecoverySpeed   = Behavior.TumbleRecoverySpeed
	Message.FilterType     = RaycastParams.FilterType
	Message.FilterList     = table.clone(RaycastParams.FilterDescendantsInstances or {})
	Message.VisualizeCasts = Behavior.VisualizeCasts

	-- [CORIOLIS] Precomputed Ω vector from the main-thread solver.
	-- Written here so the parallel Step module can read it from the snapshot
	-- without touching the solver table (unsafe across Actor boundaries).
	-- Vector3.zero when Coriolis is disabled — the per-step dot-product guard
	-- in Step.lua short-circuits at negligible cost.
	Message.CoriolisOmega  = Solver._CoriolisOmega or Vector3.zero

	self._Actors[ShardIndex]:SendMessage("AddCast", Message)
end

-- ─── RemoveCast ──────────────────────────────────────────────────────────────

function Coordinator:RemoveCast(CastId: number)
	local ShardIndex = self._CastToShard[CastId]
	if not ShardIndex then return end
	self._CastToShard[CastId]    = nil
	self._SuspendedCasts[CastId] = nil
	self._CastById[CastId]       = nil
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

	-- Advance the frame counter — drives double-buffer slot selection in both
	-- the Coordinator (read side) and the Actors (write side).
	self._FrameIndex += 1
	local FrameIndex  = self._FrameIndex

	local CosmeticParts:   { BasePart } = {}
	local CosmeticCFrames: { CFrame }   = {}
	local Suspended = self._SuspendedCasts

	-- ── 1. Apply results from the previous frame's parallel phase ─────────────
	-- Actors wrote to ShardBuffers[FrameIndex-1 % 2 + 1] last frame.
	-- We read from that slot; Actors will write to the OTHER slot this frame.
	local ReadBufferIndex = (FrameIndex - 1) % 2 + 1
	local CastById        = self._CastById

	-- Cosmetic context passed into HandleTravel so it can batch BasePart
	-- CFrame updates into the BulkMoveTo call below.
	local CosmeticCtx = { CosmeticParts = CosmeticParts, CosmeticCFrames = CosmeticCFrames }

	for ShardIndex = 1, self._ShardCount do
		local ShardTable = self._ShardBuffers[ShardIndex][ReadBufferIndex]
		local EventCount = ShardTable["count"]

		if EventCount == 0 then continue end

		-- One shallow clone per shard: converts N×M individual SharedTable
		-- field reads into a single atomic snapshot.
		local ShardSnapshot = SharedTable.clone(ShardTable)

		for EventIndex = 1, EventCount do
			local EventData = ShardSnapshot[EventIndex]
			local Cast      = CastById[EventData["Id"]]
			if not Cast or not Cast.Alive then continue end

			local Handler = EventHandlers[EventData["Event"]]

			if Handler then
				Handler(self, Solver, Cast, EventData, Terminate, CosmeticCtx)
			end
		end

		-- No explicit clear needed — the Actor overwrites count = 0 (or new
		-- events) when it writes to this buffer next time it's assigned.
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
	-- O(shards), only when value actually changed.
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

	-- ── 5. Homing + TrajectoryProvider updates (single merged pass) ───────────
	-- Merged into one O(N) pass — early-exit for casts with neither provider.
	for _, Cast in ActiveCasts do
		if not Cast.Alive or Cast.Paused    then continue end
		if Suspended[Cast.Id]               then continue end

		local NeedsHoming   = Cast.Behavior.HomingPositionProvider ~= nil
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
			local CanHome          = true
			if Cast.Behavior.CanHomeFunction then
				local Context       = Solver._CastToBulletContext[Cast]
				local Success, Result = pcall(Cast.Behavior.CanHomeFunction, Context, CurrentPosition, CurrentVelocity)
				CanHome             = Success and Result == true
			end

			local ResolvedTarget: Vector3? = nil
			if CanHome then
				Runtime.HomingProviderThread    = coroutine.running()
				local Success, Target           = pcall(Cast.Behavior.HomingPositionProvider, CurrentPosition, CurrentVelocity)
				Runtime.HomingProviderThread    = nil
				ResolvedTarget                  = (Success and typeof(Target) == "Vector3") and Target or nil
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

	-- ── 6. Dispatch — O(shards), two numbers per Actor ────────────────────────
	-- FrameDelta:  the physics step size.
	-- FrameIndex:  tells the Actor which double-buffer slot to write results into.
	-- Everything else the Actor needs is already resident in its local state.
	for Index = 1, self._ShardCount do
		self._Actors[Index]:SendMessage("StepShard", FrameDelta, FrameIndex)
	end
	-- Returns immediately. Actors step in parallel.
	-- Results are in their SharedTable buffers by the time next frame's
	-- Step() reads them — no BindableEvent, no blocking, no deep-copy.
end

-- ─── Destroy ─────────────────────────────────────────────────────────────────

function Coordinator:Destroy()
	self._Destroyed = true
	for Index, Actor in self._Actors do
		Actor:Destroy()
		-- Replace SharedTables with empty ones so the registry doesn't hold
		-- stale references and the old tables can be GC'd.
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_A", SharedTable.new())
		SharedTableRegistry:SetSharedTable("VetraShard_" .. Index .. "_B", SharedTable.new())
	end
	self._Actors        = nil
	self._ShardBuffers  = nil
	self._Solver        = nil
	self._CastToShard   = nil
	self._CastById      = nil
	self._SuspendedCasts = nil
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