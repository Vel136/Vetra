--!strict
--!optimize 2
--!native

local Vetra    = {}

local RunService = game:GetService("RunService")

local Core       = script.Core
local Physics    = script.Physics
local Registry   = script.Registry
local Signals    = script.Signals
local Simulation = script.Simulation
local Builders   = script.Builders
local Dependencies = script.Dependencies

local t                     = require(Core.TypeCheck)
local Constants             = require(Core.Constants)
local Enums                 = require(Core.Enums)
local RaycastParamsPooler   = require(Core.RaycastParamsPooler)
local BulletContext         = require(Core.BulletContext)
local Visualizer            = require(Core.TrajectoryVisualizer)
local VeSignal              = require(Dependencies.Signal)

local Kinematics            = require(Physics.Kinematics)
local DragPhysics           = require(Physics.Drag)
local CoriolisPhysics       = require(Physics.Coriolis)
local SixDOFPhysics         = require(Physics.SixDOF)

local CastRegistry          = require(Registry.CastRegistry)
local CastPool              = require(Registry.CastPool)

local FireHelpers           = require(Signals.FireHelpers)

local StepProjectile        = require(Simulation.StepProjectile)
local ResolveHitscan        = require(Simulation.ResolveHitscan)
local FrameBudget           = require(Simulation.FrameBudget)
local SpatialPartition      = require(Simulation.SpatialPartition)

local BehaviorBuilder       = require(Builders.BehaviorBuilder)

local VetraMetatable = table.freeze({ __index = Vetra})

local os_clock         = os.clock
local TERMINATE_REASON = Enums.TerminateReason

local function DefaultCast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	return workspace:Raycast(origin, direction, params)
end

local DEFAULT_BEHAVIOR = require(Builders.BehaviorBuilder.Defaults)

local function RestoreOriginalFilter(Params: RaycastParams, OriginalFilter: { Instance })
	local Restored = table.clone(OriginalFilter)
	if Params.IncludeInstances ~= nil then
		Params.IncludeInstances = Restored
	elseif Params.ExcludeInstances ~= nil then
		Params.ExcludeInstances = Restored
	else
		Params.FilterDescendantsInstances = Restored
	end
end

local COMPUTED_BEHAVIOR_KEYS = table.freeze({
	Acceleration            = true,
	Gravity                 = true,
	RaycastParams           = true,
	OriginalFilter          = true,
	DragCoefficient         = true,
	HighFidelitySegmentSize = true,
	CastFunction            = true,
	CosmeticBulletProvider  = true,
	CosmeticBulletTemplate  = true,
	CosmeticBulletContainer = true,
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

local function PropagateTrajectory(Cast: any)
	local Solver = Cast._Solver
	if Solver and Solver._Coordinator then
		Solver._Coordinator:_ModifyTrajectory(Cast)
	end
end

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

	SetPosition     = function(self, NewPosition)     Kinematics.ModifyTrajectory(self, nil,         nil,             NewPosition) PropagateTrajectory(self) end,
	SetVelocity     = function(self, NewVelocity)     Kinematics.ModifyTrajectory(self, NewVelocity, nil,             nil)         PropagateTrajectory(self) end,
	SetAcceleration = function(self, NewAcceleration) Kinematics.ModifyTrajectory(self, nil,         NewAcceleration, nil)         PropagateTrajectory(self) end,

	AddPosition = function(self, PositionDelta)
		Kinematics.ModifyTrajectory(self, nil, nil, self:GetPosition() + PositionDelta)
		PropagateTrajectory(self)
	end,
	AddVelocity = function(self, VelocityDelta)
		Kinematics.ModifyTrajectory(self, self:GetVelocity() + VelocityDelta, nil, nil)
		PropagateTrajectory(self)
	end,
	AddAcceleration = function(self, AccelerationDelta)
		Kinematics.ModifyTrajectory(self, nil, self:GetAcceleration() + AccelerationDelta, nil)
		PropagateTrajectory(self)
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
		RestoreOriginalFilter(BehaviorConfig.RaycastParams, BehaviorConfig.OriginalFilter)
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_UpdateFilter(self)
		end
	end,

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
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_UpdateOrientation(self)
		end
	end,

	SetAngularVelocity = function(self, NewAngularVelocity: Vector3)
		self.Runtime.AngularVelocity = NewAngularVelocity
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_UpdateOrientation(self)
		end
	end,

	SuspendFrame = function(self, Frames: number)
		if Frames <= 0 then return end
		self.Runtime.SuspendFramesRemaining += Frames
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_SuspendCast(self, self.Runtime.SuspendFramesRemaining, self.Runtime.SuspendTimeRemaining)
		end
	end,

	SuspendTime = function(self, Seconds: number)
		if Seconds <= 0 then return end
		self.Runtime.SuspendTimeRemaining += Seconds
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_SuspendCast(self, self.Runtime.SuspendFramesRemaining, self.Runtime.SuspendTimeRemaining)
		end
	end,

	ClearSuspend = function(self)
		self.Runtime.SuspendFramesRemaining = 0
		self.Runtime.SuspendTimeRemaining   = 0
		local Solver = self._Solver
		if Solver and Solver._Coordinator then
			Solver._Coordinator:_SuspendCast(self, 0, 0)
		end
	end,

	IsSuspended = function(self): boolean
		return self.Runtime.SuspendFramesRemaining > 0 or self.Runtime.SuspendTimeRemaining > 0
	end,
}

local CAST_SHARED_METATABLE = table.freeze({ __index = CAST_STATE_METHODS })

local VetraTypes = require(script.Types)

export type Cast            = VetraTypes.Cast
export type TerminateReason = VetraTypes.TerminateReason
export type Signals         = VetraTypes.Signals
export type Solver          = VetraTypes.Solver

type BulletContextPublic = BulletContext.BulletContext

local function Terminate(SolverRef: any, Cast: any, TerminationReason: string?)
	if not Cast.Alive then return end

	FireHelpers.FireOnTerminated(SolverRef, Cast, TerminationReason)

	Cast.Alive = false
	Cast._Solver = nil

	RestoreOriginalFilter(Cast.Behavior.RaycastParams, Cast.Behavior.OriginalFilter)
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
	if not t.table(Points) then
		warn("SetInterestPoints: expected table of Vector3")
		return
	end
	local Current = self._InterestPoints
	table.clear(Current)
	for Index, Point in Points do
		Current[Index] = Point
	end
end

function Vetra.GetSignals(self: Solver): Signals
	return self.Signals
end

function Vetra.SetCoriolisConfig(self: any, latitude: number, scale: number)
	assert(t.number(latitude), "SetCoriolisConfig: latitude must be a number")
	assert(t.number(scale),    "SetCoriolisConfig: scale must be a number")
	self._CoriolisOmega = CoriolisPhysics.ComputeOmega(latitude, scale)
end

function Vetra.Fire(self: Solver, FireBulletContext: BulletContextPublic, FireBehavior: any): Cast
	if not t.Vector3(FireBulletContext.Origin) or not t.Vector3(FireBulletContext.Direction) or not t.number(FireBulletContext.Speed) then
		warn("Fire: Context requires Origin (Vector3), Direction (Vector3), Speed (number)")
		return nil
	end

	FireBehavior = FireBehavior or {}

	if self._Coordinator and FireBehavior.CastFunction ~= nil then
		warn("Fire: CastFunction is serial-exclusive and will be ignored by the parallel solver. Use Factory.new() instead, or remove CastFunction from your FireBehavior.")
	end

	local DefaultGravity  = Vector3.new(0, -workspace.Gravity, 0)
	local ResolvedGravity = DefaultGravity
	if FireBehavior.Gravity ~= nil then
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
		WindContribution = self._Wind * WindResponse
	end

	local EffectiveAcceleration = BaseAcceleration + WindContribution

	local DragCoefficient
	if FireBehavior.DragCoefficient ~= nil then
		DragCoefficient = FireBehavior.DragCoefficient
	else
		DragCoefficient = DEFAULT_BEHAVIOR.DragCoefficient
	end

	local _EffectiveParams = FireBulletContext.RaycastParams or FireBehavior.RaycastParams or DEFAULT_BEHAVIOR.RaycastParams
	local AcquiredParams = self._ParamsPooler:Acquire(_EffectiveParams)
	if not AcquiredParams then
		warn("Fire: RaycastParams pool exhausted — allocating fresh instance")
		AcquiredParams       = RaycastParams.new()
		AcquiredParams.FilterType = _EffectiveParams.FilterType
		AcquiredParams.FilterDescendantsInstances = table.clone(_EffectiveParams.FilterDescendantsInstances or {})
		AcquiredParams.IncludeInstances = _EffectiveParams.IncludeInstances and table.clone(_EffectiveParams.IncludeInstances)
		AcquiredParams.ExcludeInstances = _EffectiveParams.ExcludeInstances and table.clone(_EffectiveParams.ExcludeInstances)
	end

	local InitialTrajectory = {
		StartTime       = 0,
		EndTime         = -1,
		Origin          = FireBulletContext.Origin,
		InitialVelocity = FireBulletContext.Direction.Unit * FireBulletContext.Speed,
		Acceleration    = EffectiveAcceleration,
	}

	self._NextCastId       += 1
	local CastId            = self._NextCastId
	local CastStartTime     = workspace:GetServerTimeNow()

	local InitialSegmentSize
	if FireBehavior.HighFidelitySegmentSize ~= nil then
		InitialSegmentSize = FireBehavior.HighFidelitySegmentSize
	else
		InitialSegmentSize = DEFAULT_BEHAVIOR.HighFidelitySegmentSize
	end
	local IsSupersonic = FireBulletContext.Speed >= Constants.SPEED_OF_SOUND

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

	local Behavior = Cast.Behavior
	ApplyBehavior(Behavior, FireBehavior)

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
	Behavior.StaticOccupancy            = FireBehavior.StaticOccupancy
	Behavior.DynamicOccupancy           = FireBehavior.DynamicOccupancy
	Behavior.CustomMachTable            = FireBehavior.CustomMachTable
	Behavior.CLAlphaMachTable           = FireBehavior.CLAlphaMachTable
	Behavior.CmAlphaMachTable           = FireBehavior.CmAlphaMachTable
	Behavior.CmqMachTable               = FireBehavior.CmqMachTable
	Behavior.ClpMachTable               = FireBehavior.ClpMachTable

	local SourceParams = _EffectiveParams
	local SourceFilter =
		SourceParams.IncludeInstances
		or SourceParams.ExcludeInstances
		or SourceParams.FilterDescendantsInstances
		or {}
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

	local CosmeticBulletProvider  = FireBehavior.CosmeticBulletProvider
	local CosmeticBulletTemplate  = FireBehavior.CosmeticBulletTemplate
	local CosmeticBulletContainer = FireBehavior.CosmeticBulletContainer
	Behavior.CosmeticBulletProvider  = CosmeticBulletProvider
	Behavior.CosmeticBulletTemplate  = CosmeticBulletTemplate
	Behavior.CosmeticBulletContainer = CosmeticBulletContainer

	if CosmeticBulletProvider ~= nil then
		if not t.callback(CosmeticBulletProvider) then
			warn("Fire: CosmeticBulletProvider must be a function")
		else
			if CosmeticBulletTemplate then
				warn("Fire: CosmeticBulletTemplate ignored because Provider is set")
			end
			local ProviderStartTime                 = os_clock()
			local ProviderSucceeded, ProviderResult = pcall(CosmeticBulletProvider, FireBulletContext)
			if os_clock() - ProviderStartTime > Constants.PROVIDER_TIMEOUT then
				warn("Fire: CosmeticBulletProvider took too long — avoid yielding")
			end
			if not ProviderSucceeded then
				warn("Fire: CosmeticBulletProvider errored: " .. tostring(ProviderResult))
			elseif ProviderResult then
				ProviderResult.Parent                    = CosmeticBulletContainer
				Cast.Runtime.CosmeticBulletObject        = ProviderResult
				FireBulletContext.CosmeticBulletObject   = ProviderResult
			end
		end
	elseif CosmeticBulletTemplate then
		local CosmeticBulletClone                    = CosmeticBulletTemplate:Clone()
		if Behavior.CosmeticBulletNonQueryable then
			CosmeticBulletClone.CanQuery = false
			CosmeticBulletClone.CanTouch = false
		end
		CosmeticBulletClone.Parent                   = CosmeticBulletContainer
		Cast.Runtime.CosmeticBulletObject            = CosmeticBulletClone
		FireBulletContext.CosmeticBulletObject        = CosmeticBulletClone
	end

	local PierceForceValue = Behavior.PierceForce
	Cast.Runtime.PierceForceRemaining = (PierceForceValue and PierceForceValue > 0) and PierceForceValue or nil

	if Behavior.SixDOFEnabled then
		local InitDir = FireBulletContext.Direction.Unit
		local InitialOrientation = FireBehavior.InitialOrientation
		if InitialOrientation then
			Cast.Runtime.Orientation = InitialOrientation
		else
			Cast.Runtime.Orientation = CFrame.lookAt(Vector3.zero, InitDir) - Vector3.zero
		end

		local InitialAngVel = FireBehavior.InitialAngularVelocity
		if InitialAngVel then
			Cast.Runtime.AngularVelocity = InitialAngVel
		elseif Behavior.SpinVector and Behavior.SpinVector:Dot(Behavior.SpinVector) > 1e-6 then
			Cast.Runtime.AngularVelocity = Behavior.SpinVector
		else
			Cast.Runtime.AngularVelocity = Vector3.zero
		end

		Cast.Runtime.AngleOfAttack    = 0
		Cast.Runtime.SixDOFAccumulator = 0
	end

	CastRegistry.Register(self, Cast)
	self._CastToBulletContext[Cast]              = FireBulletContext
	self._BulletContextToCast[FireBulletContext] = Cast
	self._BaseAccelerationCache[Cast]            = BaseAcceleration

	if FireBulletContext.__solverData and t.table(FireBulletContext.__solverData) then
		FireBulletContext.__solverData.Terminate = function()
			Terminate(self, Cast, TERMINATE_REASON.Manual)
		end
	end

	if Behavior.VisualizeCasts then
		Visualizer.Origin(FireBulletContext.Origin)
	end

	FireHelpers.FireOnSegmentOpen(self, Cast, InitialTrajectory)

	if Cast.Behavior.IsHitscan then
		ResolveHitscan.Execute(self, Cast)
	elseif self._Coordinator then
		self._Coordinator:AddCast(Cast)
	end

	return Cast
end

function Vetra.Destroy(self: any)
	if self._Destroyed then error("Destroy: already destroyed") return end
	self._Destroyed = true

	if self._FrameEvent and t.RBXScriptConnection(self._FrameEvent) then
		self._FrameEvent:Disconnect()
		self._FrameEvent = nil
	end

	if self._Coordinator then
		self._Coordinator:Destroy()
	end

	local ActiveCasts = self._ActiveCasts
	for CastIndex = #ActiveCasts, 1, -1 do
		local Cast = ActiveCasts[CastIndex]
		if Cast and Cast.Alive then
			local TerminateSucceeded, TerminateError = pcall(Terminate, self, Cast, TERMINATE_REASON.Manual)
			if not TerminateSucceeded then warn("Destroy: Terminate failed — " .. tostring(TerminateError)) end
		end
	end

	for _, Signal in self.Signals do
		Signal:Destroy()
	end
	self._ParamsPooler:Destroy()
	self._ParamsPooler           = nil
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
	self._CoriolisOmega          = nil

	setmetatable(self, nil)
	table.freeze(self)
end

local Factory = {}
Factory.BehaviorBuilder = BehaviorBuilder
Factory.BulletContext   = BulletContext
Factory.Enums           = Enums
Factory.StaticOccupancy = require(script.Occupancy.StaticOccupancy)
Factory.VoxelBaker      = require(script.Occupancy.VoxelBaker)
Factory.OccupancyChunks = require(script.Occupancy.OccupancyChunks)
Factory.DynamicOccupancy = require(script.Occupancy.DynamicOccupancy)
Factory.Profiler        = require(script.Profiler)
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
		_ParamsPooler           = RaycastParamsPooler.new(),
		_NextCastId             = 0,
		_CoriolisOmega          = Vector3.zero,
		_SpatialConfig          = SpatialConfig,
		_SpatialGrid            = {},
		_InterestPoints         = {},
		_SpatialFrameCounter    = 0,
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
			OnPrePierce              = VeSignal.new(),
			OnMidPierce              = VeSignal.new(),
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

	local Connection = RunService.PreSimulation:Connect(function(FrameDelta: number)
		StepProjectile.StepProjectile(SolverInstance, FrameDelta)
	end)
	SolverInstance._FrameEvent = Connection

	return SolverInstance
end

function Factory.newParallel(FactoryConfig: any?): Solver
	local ResolvedConfig = FactoryConfig or {}
	local SpatialConfig  = SpatialPartition.ResolveConfig(ResolvedConfig.SpatialPartition)

	local Coordinator = require(script.Parallel.Coordinator)

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
		_CoriolisOmega          = Vector3.zero,
		_SpatialConfig          = SpatialConfig,
		_SpatialGrid            = {},
		_InterestPoints         = {},
		_SpatialFrameCounter    = 0,
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
			OnPrePierce              = VeSignal.new(),
			OnMidPierce              = VeSignal.new(),
			OnSpeedThresholdCrossed  = VeSignal.new(),
			OnPreTermination         = VeSignal.new(),
			OnSegmentOpen            = VeSignal.new(),
			OnBranchSpawned          = VeSignal.new(),
			OnHomingDisengaged       = VeSignal.new(),
			OnTumbleBegin            = VeSignal.new(),
			OnTumbleEnd              = VeSignal.new(),
		},

		_FrameEvent   = nil,
		_Coordinator  = nil :: any,
	}, VetraMetatable)

	SolverInstance._Terminate = Terminate

	local CoordInstance = Coordinator.new(SolverInstance, {
		ShardCount  = ResolvedConfig.ShardCount,
		ActorParent = ResolvedConfig.ActorParent,
	})

	if not CoordInstance then
		error("Factory.newParallel: Coordinator construction failed — falling back to serial solver")
		SolverInstance._ParamsPooler:Destroy()
		for _, Signal in SolverInstance.Signals do
			Signal:Destroy()
		end
		return Factory.new(FactoryConfig)
	end

	SolverInstance._Coordinator = CoordInstance

	local _baseTerm = SolverInstance._Terminate
	SolverInstance._Terminate = function(solver, cast, reason)
		_baseTerm(solver, cast, reason)
		if CoordInstance and not CoordInstance._Destroyed then
			CoordInstance:RemoveCast(cast.Id)
		end
	end

	local Connection = RunService.PreSimulation:Connect(function(FrameDelta: number)
		CoordInstance:Step(FrameDelta)
	end)
	SolverInstance._FrameEvent = Connection

	return SolverInstance
end


return table.freeze(Factory)
