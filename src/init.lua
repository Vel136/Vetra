--!native
--!optimize 2
--!strict

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    Version: 6.5
]]

-- ─── Vetra ───────────────────────────────────────────────────────────────────
--[[
    Vetra — Analytic-trajectory projectile simulation module for Roblox.

    Architecture, instance isolation, context integration, signal model, and
    performance notes are documented in full in the V2 source. Refer there for
    the authoritative design rationale.
]]
local Identity = "Vetra"
local Vetra    = {}
Vetra.__type   = Identity

-- ─── Services ────────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── References ──────────────────────────────────────────────────────────────

local Core       = script.Core
local Physics    = script.Physics
local Registry   = script.Registry
local Signals    = script.Signals
local Simulation = script.Simulation
local Builders   = script.Builders

-- ─── Module References ───────────────────────────────────────────────────────

local LogService            = require(Core.Logger)
local t                     = require(Core.TypeCheck)
local Constants             = require(Core.Constants)
local Enums                 = require(Core.Enums)
local RaycastParamsPooler   = require(Core.RaycastParamsPooler)
local BulletContext         = require(Core.BulletContext)
local VeSignal              = require(Core.VeSignal)

local Kinematics            = require(Physics.Kinematics)
local DragPhysics           = require(Physics.Drag)
local CoriolisPhysics       = require(Physics.Coriolis)  -- [CORIOLIS]
local SixDOFPhysics         = require(Physics.SixDOF)    -- [6DOF]

local CastRegistry          = require(Registry.CastRegistry)
local CastPool              = require(Registry.CastPool)

local FireHelpers           = require(Signals.FireHelpers)

local StepProjectile        = require(Simulation.StepProjectile)
local ResolveHitscan        = require(Simulation.ResolveHitscan)
local FrameBudget           = require(Simulation.FrameBudget)
local SpatialPartition      = require(Simulation.SpatialPartition)

local BehaviorBuilder       = require(Builders.BehaviorBuilder)
local VetraNet	  		    = require(script.VetraNet)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger    = LogService.new(Identity, true)
local IS_SERVER = RunService:IsServer()

-- ─── Metatables ──────────────────────────────────────────────────────────────

local VetraMetatable = table.freeze({ __index = Vetra})

-- ─── Constants ───────────────────────────────────────────────────────────────

local os_clock         = os.clock
local TERMINATE_REASON = Enums.TerminateReason

-- Fallback cast function used when the consumer does not supply a CastFunction.
-- Defined once here and assigned onto Behavior in Fire() so all call sites can
-- call Behavior.CastFunction(...) unconditionally without a nil check or `or` fallback.
local function DefaultCast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	return workspace:Raycast(origin, direction, params)
end

-- Default Behavior
local DEFAULT_BEHAVIOR = require(Builders.BehaviorBuilder.Defaults)

-- ─── Behavior Application ────────────────────────────────────────────────────

-- Fields whose values are computed inside Fire() rather than copied directly
-- from FireBehavior. The loop skips these; Fire() writes them explicitly after.
local COMPUTED_BEHAVIOR_KEYS = table.freeze({
	Acceleration         = true,
	Gravity              = true,
	RaycastParams        = true,
	OriginalFilter       = true,
	DragCoefficient      = true,
	HighFidelitySegmentSize = true,
	CastFunction            = true,
	-- Cosmetics are handled separately (provider invocation logic)
	CosmeticBulletProvider  = true,
	CosmeticBulletTemplate  = true,
	CosmeticBulletContainer = true,
	-- [6DOF] Initial angular state is resolved in Fire() based on Direction
	-- and SpinVector, so they must not be blindly copied from FireBehavior.
	InitialOrientation      = true,
	InitialAngularVelocity  = true,
})

local function ApplyBehavior(Behavior: any, FireBehavior: any)
	for Key, Default in DEFAULT_BEHAVIOR do
		if not COMPUTED_BEHAVIOR_KEYS[Key] then
			local Override = FireBehavior[Key]
			if Override ~= nil then
				Behavior[Key] = Override
			else
				Behavior[Key] = Default
			end
		end
	end
end

-- ─── Cast State Methods ───────────────────────────────────────────────────────

local CAST_STATE_METHODS = {
	GetPosition = function(self)
		local ActiveTrajectory = self.Runtime.ActiveTrajectory
		local ElapsedTime      = self.Runtime.TotalRuntime - ActiveTrajectory.StartTime

		return Kinematics.PositionAtTime(ElapsedTime, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
	end,

	GetVelocity = function(self)
		local ActiveTrajectory = self.Runtime.ActiveTrajectory
		local ElapsedTime      = self.Runtime.TotalRuntime - ActiveTrajectory.StartTime
		return Kinematics.VelocityAtTime(ElapsedTime, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
	end,

	GetAcceleration = function(self)
		return self.Runtime.ActiveTrajectory.Acceleration
	end,

	Pause = function(self)
		self.Paused = true
	end,

	Resume = function(self)
		self.Paused = false
	end,

	IsPaused = function(self)
		return self.Paused
	end,

	SetPosition     = function(self, NewPosition)     Kinematics.ModifyTrajectory(self, nil,         nil,             NewPosition) end,
	SetVelocity     = function(self, NewVelocity)     Kinematics.ModifyTrajectory(self, NewVelocity, nil,             nil)         end,
	SetAcceleration = function(self, NewAcceleration) Kinematics.ModifyTrajectory(self, nil,         NewAcceleration, nil)         end,

	AddPosition = function(self, PositionDelta)
		Kinematics.ModifyTrajectory(self, nil, nil, self:GetPosition() + PositionDelta)
	end,
	AddVelocity = function(self, VelocityDelta)
		Kinematics.ModifyTrajectory(self, self:GetVelocity() + VelocityDelta, nil, nil)
	end,
	AddAcceleration = function(self, AccelerationDelta)
		Kinematics.ModifyTrajectory(self, nil, self:GetAcceleration() + AccelerationDelta, nil)
	end,

	ResetBounceState = function(self)
		table.clear(self.Runtime.BouncePositionHistory)
		self.Runtime.BouncePositionHead   = 0
		self.Runtime.LastBounceTime       = -math.huge
		self.Runtime.VelocityDirectionEMA = Constants.ZERO_VECTOR
	end,
	Terminate = function(self)
		if not self.Alive then return end
		local Solver = self._Solver
		if not Solver then return end
		Solver._Terminate(Solver, self, TERMINATE_REASON.Manual)
	end,
	ResetPierceState = function(self)
		local BehaviorConfig = self.Behavior
		self.Runtime.PiercedInstances = {}
		self.Runtime.PierceCount      = 0
		BehaviorConfig.RaycastParams.FilterDescendantsInstances = table.clone(BehaviorConfig.OriginalFilter)
	end,

	-- ── 6DOF Cast Methods ────────────────────────────────────────────────────
	-- These return sensible defaults when 6DOF is disabled so consumers do
	-- not need to nil-guard.

	GetOrientation = function(self): CFrame
		return self.Runtime.Orientation
	end,

	GetAngularVelocity = function(self): Vector3
		return self.Runtime.AngularVelocity
	end,

	GetAngleOfAttack = function(self): number
		return self.Runtime.AngleOfAttack
	end,

	SetOrientation = function(self, NewOrientation: CFrame)
		self.Runtime.Orientation = NewOrientation
	end,

	SetAngularVelocity = function(self, NewAngularVelocity: Vector3)
		self.Runtime.AngularVelocity = NewAngularVelocity
	end,
}

-- Now that CAST_STATE_METHODS is defined, declare the shared metatable.
-- Every Cast object uses this identical table — CastPool stamps it at
-- Acquire() time instead of allocating a fresh table per Fire() call.
local CAST_SHARED_METATABLE = table.freeze({ __index = CAST_STATE_METHODS })

-- ─── Public Types ─────────────────────────────────────────────────────────────

local VetraTypes = require(script.Types)

export type Cast           = VetraTypes.Cast
export type TerminateReason = VetraTypes.TerminateReason
export type Signals        = VetraTypes.Signals
export type Solver         = VetraTypes.Solver

type BulletContextPublic = BulletContext.BulletContext

-- ─── Terminate ───────────────────────────────────────────────────────────────

local function Terminate(SolverRef: any, Cast: any, TerminationReason: string?)
	if not Cast.Alive then return end
	Cast.Alive = false
	Cast._Solver = nil

	Cast.Behavior.RaycastParams.FilterDescendantsInstances = table.clone(Cast.Behavior.OriginalFilter)
	SolverRef._ParamsPooler:Release(Cast.Behavior.RaycastParams)

	if Cast.Runtime.CosmeticBulletObject then
		if Cast.Behavior.AutoDeleteCosmeticBullet then
			Cast.Runtime.CosmeticBulletObject:Destroy()
		end
		Cast.Runtime.CosmeticBulletObject = nil
	end

	local LinkedBulletContext = SolverRef._CastToBulletContext[Cast]
	if LinkedBulletContext then
		LinkedBulletContext.CosmeticBulletObject = nil
		if LinkedBulletContext.Alive then
			LinkedBulletContext:Terminate()
		end
		SolverRef._BulletContextToCast[LinkedBulletContext] = nil
		SolverRef._CastToBulletContext[Cast]                = nil
	end
	SolverRef._BaseAccelerationCache[Cast] = nil

	CastRegistry.Remove(SolverRef, Cast)

	-- Return the Cast table tree to the pool for reuse on the next Fire().
	-- ResetRuntime runs at Acquire() time, not here, so Release() is cheap —
	-- it only pushes the reference onto the free list.
	CastPool.Release(SolverRef._CastPool, Cast)
end

function Vetra.SetWind(self: any, WindVector: Vector3)
	assert(t.Vector3(WindVector), "SetWind: expected Vector3")
	self._Wind = WindVector
end

function Vetra.SetLODOrigin(self: any, LODOrigin: Vector3?)
	self._LODOrigin = LODOrigin
end

function Vetra.SetInterestPoints(self: any, Points: { Vector3 })
	-- Validate input is a table. Individual entries are not type-checked per
	-- element to avoid O(n) cost on every call — bad entries produce NaN cell
	-- keys which are simply ignored by GetTier's grid lookup.
	if not t.table(Points) then
		Logger:Warn("SetInterestPoints: expected table of Vector3")
		return
	end
	-- Replace the array contents in-place rather than swapping the reference.
	-- SpatialPartition.Rebuild holds a direct reference to _InterestPoints so
	-- swapping the table out from under it would cause Rebuild to read the
	-- stale previous frame's points.
	local Current = self._InterestPoints
	table.clear(Current)
	for Index, Point in Points do
		Current[Index] = Point
	end
end

function Vetra.GetSignals(self: Solver): Signals
	return self.Signals
end

--[[
    SetCoriolisConfig(latitude, scale)

    Reconfigure the solver's Coriolis effect. Ω is precomputed here and
    cached on the solver so math.sin / math.cos never run in the per-frame
    step loop.

    Parameters
        latitude  number   Geographic latitude in degrees.
                           Positive  = northern hemisphere.
                           Negative  = southern hemisphere.
                           0         = equator (horizontal E/W deflection only)
                           90 / -90  = poles (deflection rotates the ground track)
        scale     number   Exaggeration multiplier on Earth's actual ω.
                           0    = disabled (zero overhead, the default)
                           500  = subtle; detectable only at long range
                           1000 = clearly perceptible at ~300 studs
                           3000 = strong, map-defining mechanic

    Expose as a map-level config rather than a per-gun config — the Coriolis
    effect is an environment property that affects every bullet the same way.

    Example
        -- Arctic map — strong northern deflection
        Solver:SetCoriolisConfig(75, 1200)

        -- Equatorial map — purely horizontal east/west drift
        Solver:SetCoriolisConfig(0, 800)

        -- Disable entirely
        Solver:SetCoriolisConfig(45, 0)
]]
function Vetra.SetCoriolisConfig(self: any, latitude: number, scale: number)
	assert(t.number(latitude), "SetCoriolisConfig: latitude must be a number")
	assert(t.number(scale),    "SetCoriolisConfig: scale must be a number")
	self._CoriolisOmega = CoriolisPhysics.ComputeOmega(latitude, scale)
end

function Vetra.Fire(self: Solver, FireBulletContext: BulletContextPublic, FireBehavior: any): Cast
	if not t.Vector3(FireBulletContext.Origin) or not t.Vector3(FireBulletContext.Direction) or not t.number(FireBulletContext.Speed) then
		Logger:Warn("Fire: Context requires Origin (Vector3), Direction (Vector3), Speed (number)")
		return nil
	end

	FireBehavior = FireBehavior or {}

	-- CastFunction is serial-exclusive. Functions cannot cross Actor boundaries
	-- via SendMessage serialization, so the parallel solver cannot honour this
	-- field. Warn early rather than silently falling back to workspace:Raycast.
	if self._Coordinator and FireBehavior.CastFunction ~= nil then
		Logger:Warn("Fire: CastFunction is serial-exclusive and will be ignored by the parallel solver. Use Factory.new() instead, or remove CastFunction from your FireBehavior.")
	end

	local DefaultGravity  = Vector3.new(0, -workspace.Gravity, 0)
	local ResolvedGravity = DefaultGravity
	if FireBehavior.Gravity and FireBehavior.Gravity.Magnitude > 0 then
		ResolvedGravity = FireBehavior.Gravity
	end

	local BaseAcceleration = ResolvedGravity + if FireBehavior.Acceleration ~= nil then FireBehavior.Acceleration else DEFAULT_BEHAVIOR.Acceleration

	local WindContribution = Constants.ZERO_VECTOR
	if self._Wind and self._Wind.Magnitude > 0 then
		local WindResponse
		if FireBehavior.WindResponse ~= nil then
			WindResponse = FireBehavior.WindResponse
		else
			WindResponse = DEFAULT_BEHAVIOR.WindResponse
		end
		WindContribution   = self._Wind * WindResponse
	end

	local EffectiveAcceleration = BaseAcceleration + WindContribution

	local DragCoefficient
	if FireBehavior.DragCoefficient ~= nil then
		DragCoefficient = FireBehavior.DragCoefficient
	else
		DragCoefficient = DEFAULT_BEHAVIOR.DragCoefficient
	end

	-- Priority: BulletContext.RaycastParams → Behavior.RaycastParams → default empty params
	local _EffectiveParams = FireBulletContext.RaycastParams or FireBehavior.RaycastParams or DEFAULT_BEHAVIOR.RaycastParams
	local AcquiredParams = self._ParamsPooler:Acquire(_EffectiveParams)
	if not AcquiredParams then
		-- ParamsPooler.Acquire never actually returns nil in current
		-- implementation (it falls through to RaycastParams.new() on exhaustion).
		-- But IF it ever became reachable, using the caller's original
		-- RaycastParams object directly would be catastrophic: pierce mutations
		-- would dirty it and Release() would permanently inject it into the pool.
		-- Allocate a fresh object and copy the relevant settings instead.
		Logger:Warn("Fire: RaycastParams pool exhausted — allocating fresh instance")

		AcquiredParams       = RaycastParams.new()
		AcquiredParams.FilterType = _EffectiveParams.FilterType
		AcquiredParams.FilterDescendantsInstances = table.clone(_EffectiveParams.FilterDescendantsInstances or {})
	end

	local InitialTrajectory = {
		StartTime       = 0,
		EndTime         = -1,
		Origin          = FireBulletContext.Origin,
		InitialVelocity = FireBulletContext.Direction.Unit * FireBulletContext.Speed,
		Acceleration    = EffectiveAcceleration,
		IsSampled       = false,
		SampledFn       = nil,
	}

	self._NextCastId       += 1
	local CastId            = self._NextCastId
	local CastStartTime     = workspace:GetServerTimeNow()

	-- Acquire a Cast table from the pool. ResetRuntime runs inside Acquire,
	-- so Runtime fields are already zeroed when we get the object back.
	-- We only need to write Behavior fields below — they are unique per Fire().
	local InitialSegmentSize
	if FireBehavior.HighFidelitySegmentSize ~= nil then
		InitialSegmentSize = FireBehavior.HighFidelitySegmentSize
	else
		InitialSegmentSize = DEFAULT_BEHAVIOR.HighFidelitySegmentSize
	end
	local IsSupersonic       = FireBulletContext.Speed >= Constants.SPEED_OF_SOUND

	local Cast = CastPool.Acquire(
		self._CastPool,
		CastId,
		CastStartTime,
		InitialTrajectory,
		InitialSegmentSize,
		IsSupersonic,
		CAST_SHARED_METATABLE
	)
	Cast._Solver = self

	if FireBulletContext.__solverData and t.table(FireBulletContext.__solverData) then
		FireBulletContext.__solverData.Cast = Cast
	end

	self.Signals.OnFire:FireSync(FireBulletContext, FireBehavior)

	-- ── Behavior ─────────────────────────────────────────────────────────────
	-- Apply all plain override-or-default fields in one loop, then overwrite
	-- the fields that require computed values below.
	local Behavior = Cast.Behavior
	ApplyBehavior(Behavior, FireBehavior)

	-- Callback fields — nil in DEFAULT_BEHAVIOR so pairs() skips them entirely.
	-- Must be assigned explicitly; bare assignment preserves intentional nil.
	Behavior.CanPierceFunction          = FireBehavior.CanPierceFunction
	Behavior.CanBounceFunction          = FireBehavior.CanBounceFunction
	Behavior.CanHomeFunction            = FireBehavior.CanHomeFunction
	Behavior.HomingPositionProvider     = FireBehavior.HomingPositionProvider
	Behavior.TrajectoryPositionProvider = FireBehavior.TrajectoryPositionProvider
	Behavior.GyroDriftRate              = FireBehavior.GyroDriftRate
	Behavior.GyroDriftAxis              = FireBehavior.GyroDriftAxis
	Behavior.TumbleSpeedThreshold       = FireBehavior.TumbleSpeedThreshold
	Behavior.TumbleDragMultiplier       = FireBehavior.TumbleDragMultiplier
	Behavior.TumbleLateralStrength      = FireBehavior.TumbleLateralStrength
	Behavior.TumbleOnPierce             = FireBehavior.TumbleOnPierce
	Behavior.TumbleRecoverySpeed        = FireBehavior.TumbleRecoverySpeed
	Behavior.SupersonicProfile          = FireBehavior.SupersonicProfile
	Behavior.SubsonicProfile            = FireBehavior.SubsonicProfile

	-- Computed fields — written explicitly because they depend on values
	-- resolved earlier in Fire() rather than coming straight from FireBehavior.
	local SourceParams = _EffectiveParams
	local SourceFilter = SourceParams.FilterDescendantsInstances or {}
	Behavior.Acceleration            = EffectiveAcceleration
	Behavior.Gravity                 = ResolvedGravity
	Behavior.RaycastParams           = AcquiredParams
	Behavior.OriginalFilter          = table.freeze(table.clone(SourceFilter))
	Behavior.DragCoefficient         = DragCoefficient
	Behavior.HighFidelitySegmentSize = InitialSegmentSize
	if self._Coordinator then
		Behavior.CastFunction = DefaultCast
	else
		Behavior.CastFunction = FireBehavior.CastFunction or DefaultCast
	end

	-- Cosmetics — stored for the provider invocation below.
	local CosmeticBulletProvider  = FireBehavior.CosmeticBulletProvider
	local CosmeticBulletTemplate  = FireBehavior.CosmeticBulletTemplate
	local CosmeticBulletContainer = FireBehavior.CosmeticBulletContainer
	Behavior.CosmeticBulletProvider  = CosmeticBulletProvider
	Behavior.CosmeticBulletTemplate  = CosmeticBulletTemplate
	Behavior.CosmeticBulletContainer = CosmeticBulletContainer

	if CosmeticBulletProvider ~= nil then
		if not t.callback(CosmeticBulletProvider) then
			Logger:Warn("Fire: CosmeticBulletProvider must be a function")
		else
			if CosmeticBulletTemplate then
				Logger:Warn("Fire: CosmeticBulletTemplate ignored because Provider is set")
			end
			local ProviderStartTime                 = os_clock()
			local ProviderSucceeded, ProviderResult = pcall(CosmeticBulletProvider, FireBulletContext)
			if os_clock() - ProviderStartTime > Constants.PROVIDER_TIMEOUT then
				Logger:Warn("Fire: CosmeticBulletProvider took too long — avoid yielding")
			end
			if not ProviderSucceeded then
				Logger:Warn("Fire: CosmeticBulletProvider errored: " .. tostring(ProviderResult))
			elseif ProviderResult then
				ProviderResult.Parent                    = CosmeticBulletContainer
				Cast.Runtime.CosmeticBulletObject        = ProviderResult
				FireBulletContext.CosmeticBulletObject   = ProviderResult
			end
		end
	elseif CosmeticBulletTemplate then
		local CosmeticBulletClone                    = CosmeticBulletTemplate:Clone()
		CosmeticBulletClone.Parent                   = CosmeticBulletContainer
		Cast.Runtime.CosmeticBulletObject            = CosmeticBulletClone
		FireBulletContext.CosmeticBulletObject        = CosmeticBulletClone
	end

	-- ── PierceForce initialisation ──────────────────────────────────────
	-- Seed the remaining-force budget on Runtime so Pierce.ResolveChain can
	-- decrement it without needing to read Behavior.PierceForce each time.
	-- nil means "disabled" — Pierce checks for nil before decrementing.
	local PierceForceValue = Behavior.PierceForce
	Cast.Runtime.PierceForceRemaining = (PierceForceValue and PierceForceValue > 0) and PierceForceValue or nil

	-- ── 6DOF angular state initialisation ────────────────────────────────────
	-- When SixDOFEnabled is true, seed the cast's orientation and angular
	-- velocity from the behavior config. If not provided, derive sensible
	-- defaults: orientation from the fire direction, angular velocity from
	-- the existing SpinVector (so Magnus and 6DOF can coexist).
	if Behavior.SixDOFEnabled then
		local InitDir = FireBulletContext.Direction.Unit
		local InitialOrientation = FireBehavior.InitialOrientation
		if InitialOrientation then
			Cast.Runtime.Orientation = InitialOrientation
		else
			-- Default: body forward = fire direction (look-at with world up).
			Cast.Runtime.Orientation = CFrame.lookAt(Vector3.zero, InitDir) - Vector3.zero
		end

		local InitialAngVel = FireBehavior.InitialAngularVelocity
		if InitialAngVel then
			Cast.Runtime.AngularVelocity = InitialAngVel
		elseif Behavior.SpinVector and Behavior.SpinVector:Dot(Behavior.SpinVector) > 1e-6 then
			-- Seed from SpinVector so existing Magnus configs get angular state.
			-- SpinVector is in world-frame rad/s along the spin axis — project
			-- onto the body forward to get the roll rate, keep the rest as wobble.
			Cast.Runtime.AngularVelocity = Behavior.SpinVector
		else
			Cast.Runtime.AngularVelocity = Vector3.zero
		end

		Cast.Runtime.AngleOfAttack    = 0
		Cast.Runtime.SixDOFAccumulator = 0
	end

	-- ── Registration ─────────────────────────────────────────────────────────

	CastRegistry.Register(self, Cast)
	self._CastToBulletContext[Cast]              = FireBulletContext
	self._BulletContextToCast[FireBulletContext] = Cast
	self._BaseAccelerationCache[Cast]            = BaseAcceleration

	if FireBulletContext.__solverData and t.table(FireBulletContext.__solverData) then
		FireBulletContext.__solverData.Terminate = function()
			Terminate(self, Cast, TERMINATE_REASON.Manual)
		end
	end

	FireHelpers.FireOnSegmentOpen(self, Cast, InitialTrajectory)

	if Cast.Behavior.IsHitscan then
		-- Hitscan resolves synchronously here — no frame-loop involvement.
		-- This works in both coordinator and non-coordinator mode, since the
		-- Coordinator's Step() never sees the cast and StepProjectile would
		-- only reach it a frame late.
		ResolveHitscan.Execute(self, Cast)
	elseif self._Coordinator then
		self._Coordinator:AddCast(Cast)
	end

	return Cast
end

function Vetra.Destroy(self: any)
	if self._Destroyed then Logger:Error("Destroy: already destroyed") return end
	self._Destroyed = true

	if self._FrameEvent and t.RBXScriptConnection(self._FrameEvent) then
		self._FrameEvent:Disconnect()
		self._FrameEvent = nil
	end

	local ActiveCasts = self._ActiveCasts
	for CastIndex = #ActiveCasts, 1, -1 do
		local Cast = ActiveCasts[CastIndex]
		if Cast and Cast.Alive then
			local TerminateSucceeded, TerminateError = pcall(Terminate, self, Cast, TERMINATE_REASON.Manual)
			if not TerminateSucceeded then Logger:Warn("Destroy: Terminate failed — " .. tostring(TerminateError)) end
		end
	end

	for _, Signal in self.Signals do
		Signal:Destroy()
	end
	self._ParamsPooler:Destroy()
	self._ParamsPooler = nil
	self._ActiveCasts            = nil
	self._CastToBulletContext    = nil
	self._BulletContextToCast    = nil
	self._BaseAccelerationCache  = nil
	self.Signals                 = nil
	self._FrameBudget            = nil
	self._TravelBatch            = nil
	self._SpatialGrid            = nil
	self._InterestPoints         = nil
	self._SpatialConfig          = nil
	self._CastPool               = nil
	self._CoriolisOmega          = nil  -- [CORIOLIS]

	setmetatable(self, nil)
	table.freeze(self)
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

local Factory = {}
Factory.__type          = Identity
Factory.BehaviorBuilder = BehaviorBuilder
Factory.BulletContext   = BulletContext
Factory.VetraNet        = VetraNet
Factory.Enums           = Enums
function Factory.new(FactoryConfig: any?): Solver
	local ResolvedConfig  = FactoryConfig or {}
	local SpatialConfig   = SpatialPartition.ResolveConfig(ResolvedConfig.SpatialPartition)

	local SolverInstance = setmetatable({
		_ActiveCasts            = {},
		_CastToBulletContext    = setmetatable({}, { __mode = "k" }),
		_BulletContextToCast    = setmetatable({}, { __mode = "k" }),
		_BaseAccelerationCache  = setmetatable({}, { __mode = "k" }),
		_FrameBudget            = FrameBudget.new(),
		_TravelBatch            = {},
		_Wind                   = Constants.ZERO_VECTOR,
		_LODOrigin              = nil :: Vector3?,
		_Terminate              = nil :: any,
		_Destroyed              = false,
		_ParamsPooler 			= RaycastParamsPooler.new(),
		_NextCastId             = 0,

		-- [CORIOLIS] Precomputed Ω vector. Zero by default (Coriolis disabled).
		-- Updated by Vetra:SetCoriolisConfig(latitude, scale).
		_CoriolisOmega          = Vector3.zero,

		-- ── Spatial partition ─────────────────────────────────────────────
		_SpatialConfig          = SpatialConfig,
		_SpatialGrid            = {},   -- [cellKey] = tier, rebuilt every UpdateInterval frames
		_InterestPoints         = {},   -- { Vector3 } — set each frame by consumer via SetInterestPoints
		_SpatialFrameCounter    = 0,    -- frames since last grid rebuild

		-- ── Cast pool ────────────────────────────────────────────────────
		_CastPool               = CastPool.new(),

		Signals = {
			OnFire                   = VeSignal.new(),
			OnHit                    = VeSignal.new(),
			OnTravel                 = VeSignal.new(),
			OnTravelBatch            = VeSignal.new(),
			OnPierce                 = VeSignal.new(),
			OnBounce                 = VeSignal.new(),
			OnTerminated             = VeSignal.new(),
			OnPreBounce              = VeSignal.new(),
			OnMidBounce              = VeSignal.new(),
			OnPrePierce         = VeSignal.new(),
			OnMidPierce         = VeSignal.new(),
			OnSpeedThresholdCrossed  = VeSignal.new(),
			OnPreTermination         = VeSignal.new(),
			OnSegmentOpen            = VeSignal.new(),
			OnBranchSpawned          = VeSignal.new(),
			OnHomingDisengaged       = VeSignal.new(),
			OnTumbleBegin            = VeSignal.new(),
			OnTumbleEnd              = VeSignal.new(),
		},

		_FrameEvent = nil,
	}, VetraMetatable)

	SolverInstance._Terminate = Terminate

	local FrameEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	local Connection = FrameEvent:Connect(function(FrameDelta: number)
		StepProjectile.StepProjectile(SolverInstance, FrameDelta)
	end)
	SolverInstance._FrameEvent = Connection

	return SolverInstance
end


-- ─── Factory.newParallel ─────────────────────────────────────────────────────
--[[
    V4 Parallel Solver factory.

    Creates a Solver whose per-frame simulation runs across N Roblox Actors
    (true multi-core parallelism via Parallel Luau).

    All physics computation — raycasts, drag, Magnus, homing, bounce math,
    corner-trap detection — runs in parallel. Signal firing, user callbacks
    (CanPierce / CanBounce / HomingPositionProvider), and cosmetic updates
    are flushed on the main thread after each parallel pass.

    Config fields:
        ShardCount      number    Number of Actor shards. Default: 4.
                                  Tune to your server's core count.
        ActorParent     Instance  Where to parent Actor instances.
                                  Default: workspace.
        SpatialPartition table    Same as Factory.new() spatial config.
        [all other Factory.new() fields are also accepted]

    Drop-in compatible:
        The returned solver exposes the identical API as Factory.new().
        Fire(), SetWind(), SetLODOrigin(), SetInterestPoints(), GetSignals(),
        Destroy() — all unchanged.

    Benchmark guidance:
        Parallel overhead breaks even around 50–100 active bullets.
        Below that threshold Factory.new() may be faster.
        Above ~200 bullets with physics features enabled (Magnus, homing,
        high-fidelity resimulation) the parallel version scales significantly
        better because the raycast cost dominates.

    Example:
        local Vetra = require(ReplicatedStorage.Vetra)

        local Solver = Vetra.newParallel({
            ShardCount = 6,
            SpatialPartition = { FallbackTier = Vetra.SPATIAL_TIERS.COLD },
        })
        Solver:GetSignals().OnHit:Connect(function(ctx, result, vel)
            -- same as always
        end)
        Solver:Fire(BulletContext, Behavior)
]]
function Factory.newParallel(FactoryConfig: any?): Solver
	local ResolvedConfig = FactoryConfig or {}
	local SpatialConfig  = SpatialPartition.ResolveConfig(ResolvedConfig.SpatialPartition)

	-- Lazy-require Coordinator so non-parallel users pay zero cost.
	local Coordinator = require(script.Parallel.Coordinator)

	-- Build the solver instance with the same fields as Factory.new().
	local SolverInstance = setmetatable({
		_ActiveCasts            = {},
		_CastToBulletContext    = setmetatable({}, { __mode = "k" }),
		_BulletContextToCast    = setmetatable({}, { __mode = "k" }),
		_BaseAccelerationCache  = setmetatable({}, { __mode = "k" }),
		_FrameBudget            = FrameBudget.new(),
		_TravelBatch            = {},
		_Wind                   = Constants.ZERO_VECTOR,
		_LODOrigin              = nil :: Vector3?,
		_Terminate              = nil :: any,
		_Destroyed              = false,
		_ParamsPooler           = RaycastParamsPooler.new(),
		_NextCastId             = 0,

		-- [CORIOLIS] Precomputed Ω vector. Zero by default (Coriolis disabled).
		-- Updated by Vetra:SetCoriolisConfig(latitude, scale).
		_CoriolisOmega          = Vector3.zero,

		-- Spatial partition
		_SpatialConfig          = SpatialConfig,
		_SpatialGrid            = {},
		_InterestPoints         = {},
		_SpatialFrameCounter    = 0,

		-- Cast pool
		_CastPool               = CastPool.new(),

		Signals = {
			OnFire                   = VeSignal.new(),
			OnHit                    = VeSignal.new(),
			OnTravel                 = VeSignal.new(),
			OnTravelBatch            = VeSignal.new(),
			OnPierce                 = VeSignal.new(),
			OnBounce                 = VeSignal.new(),
			OnTerminated             = VeSignal.new(),
			OnPreBounce              = VeSignal.new(),
			OnMidBounce              = VeSignal.new(),
			OnPrePierce         = VeSignal.new(),
			OnMidPierce         = VeSignal.new(),
			OnSpeedThresholdCrossed  = VeSignal.new(),
			OnPreTermination         = VeSignal.new(),
			OnSegmentOpen            = VeSignal.new(),
			OnBranchSpawned         = VeSignal.new(),
			OnHomingDisengaged       = VeSignal.new(),
			OnTumbleBegin            = VeSignal.new(),
			OnTumbleEnd              = VeSignal.new(),
		},

		_FrameEvent   = nil,
		_Coordinator  = nil :: any,
	}, VetraMetatable)

	SolverInstance._Terminate = Terminate

	-- Build the Coordinator (creates Actor pool).
	local CoordInstance = Coordinator.new(SolverInstance, {
		ShardCount  = ResolvedConfig.ShardCount,
		ActorParent = ResolvedConfig.ActorParent,
	})

	if not CoordInstance then
		Logger:Error("Factory.newParallel: Coordinator construction failed — falling back to serial solver")
		-- Clean up the abandoned parallel instance before returning the fallback.
		SolverInstance._ParamsPooler:Destroy()
		for _, Signal in SolverInstance.Signals do
			Signal:Destroy()
		end
		return Factory.new(FactoryConfig)
	end

	SolverInstance._Coordinator = CoordInstance

	-- Wrap _Terminate so Actor workers are notified when a cast ends,
	-- allowing them to clean up their cached RaycastParams.
	local _baseTerm = SolverInstance._Terminate
	SolverInstance._Terminate = function(solver, cast, reason)
		_baseTerm(solver, cast, reason)
		if CoordInstance and not CoordInstance._Destroyed then
			CoordInstance:RemoveCast(cast.Id)
		end
	end

	-- Connect Heartbeat to Coordinator.Step instead of StepProjectile.
	local FrameEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	local Connection = FrameEvent:Connect(function(FrameDelta: number)
		CoordInstance:Step(FrameDelta)
	end)
	SolverInstance._FrameEvent = Connection

	return SolverInstance
end

-- ─── Module Return ───────────────────────────────────────────────────────────

export type VetraModule = {
	new          : (config: any?) -> Solver,
	newParallel  : (config: any?) -> Solver,
	BehaviorBuilder : typeof(BehaviorBuilder),
	BulletContext   : typeof(BulletContext),
	VetraNet        : typeof(VetraNet),
	Enums           : typeof(Enums),
}

return table.freeze(Factory)