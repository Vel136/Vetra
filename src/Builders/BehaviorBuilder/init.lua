--!strict
--!optimize 2
--!native

local Core = script.Parent.Parent.Core

local Types         = require(script.Parent.Parent.Types)
local DEFAULTS      = require(script.Defaults)
local ValidateBuilt = require(script.Validation)

local PhysicsBuilder       = require(script.Physics)
local HomingBuilder        = require(script.Homing)
local PierceBuilder        = require(script.Pierce)
local BounceBuilder        = require(script.Bounce)
local HighFidelityBuilder  = require(script.HighFidelity)
local CornerTrapBuilder    = require(script.CornerTrap)
local CosmeticBuilder      = require(script.Cosmetic)
local DebugBuilder         = require(script.Debug)
local DragBuilder          = require(script.Drag)
local WindBuilder          = require(script.Wind)
local MagnusBuilder        = require(script.Magnus)
local GyroDriftBuilder     = require(script.GyroDrift)
local TumbleBuilder        = require(script.Tumble)
local FragmentationBuilder = require(script.Fragmentation)
local SpeedProfilesModule  = require(script.SpeedProfiles)
local TrajectoryBuilder    = require(script.Trajectory)
local LODBuilder           = require(script.LOD)
local SixDOFBuilder        = require(script.SixDOF)

local SpeedProfilesBuilder = SpeedProfilesModule.SpeedProfilesBuilder

type BuiltBehavior = Types.BuiltBehavior
type DirtySet      = Types.DirtySet

local TABLE_FIELDS: { [string]: boolean } = {
	MaterialRestitution = true,
	SpeedThresholds     = true,
	SupersonicProfile   = true,
	SubsonicProfile     = true,
}

local function cloneConfig(Config: BuiltBehavior): BuiltBehavior
	local Copy = table.clone(Config)
	Copy.MaterialRestitution = table.clone(Config.MaterialRestitution)
	Copy.SpeedThresholds     = table.clone(Config.SpeedThresholds)
	if Config.SupersonicProfile then
		Copy.SupersonicProfile = table.clone(Config.SupersonicProfile)
	end
	if Config.SubsonicProfile then
		Copy.SubsonicProfile = table.clone(Config.SubsonicProfile)
	end
	if Config.RaycastParams then
		local Src   = Config.RaycastParams
		local Fresh = RaycastParams.new()
		Fresh.FilterDescendantsInstances = Src.FilterDescendantsInstances
		Fresh.FilterType                 = Src.FilterType
		Fresh.IgnoreWater                = Src.IgnoreWater
		Fresh.CollisionGroup             = Src.CollisionGroup
		Fresh.IncludeInstances           = Src.IncludeInstances and table.clone(Src.IncludeInstances)
		Fresh.ExcludeInstances           = Src.ExcludeInstances and table.clone(Src.ExcludeInstances)
		Copy.RaycastParams = Fresh
	else
		Copy.RaycastParams = nil
	end
	return Copy
end

local BehaviorBuilder = {}
BehaviorBuilder.__index = BehaviorBuilder

function BehaviorBuilder.new(): BehaviorBuilder
	local Config: BuiltBehavior = {
		Acceleration                 = DEFAULTS.Acceleration,
		MaxDistance                  = DEFAULTS.MaxDistance,
		MaxDisplacement              = DEFAULTS.MaxDisplacement,
		MaxSpeed                     = DEFAULTS.MaxSpeed,
		RaycastParams                = nil,
		Gravity                      = Vector3.new(0, -workspace.Gravity, 0),
		MinSpeed                     = DEFAULTS.MinSpeed,

		DragCoefficient              = DEFAULTS.DragCoefficient,
		DragModel                    = DEFAULTS.DragModel,
		DragSegmentInterval          = DEFAULTS.DragSegmentInterval,
		CustomMachTable              = DEFAULTS.CustomMachTable,

		WindResponse                 = DEFAULTS.WindResponse,

		SpinVector                   = DEFAULTS.SpinVector,
		MagnusCoefficient            = DEFAULTS.MagnusCoefficient,
		SpinDecayRate                = DEFAULTS.SpinDecayRate,

		GyroDriftRate                = DEFAULTS.GyroDriftRate,
		GyroDriftAxis                = DEFAULTS.GyroDriftAxis,

		TumbleSpeedThreshold         = DEFAULTS.TumbleSpeedThreshold,
		TumbleDragMultiplier         = DEFAULTS.TumbleDragMultiplier,
		TumbleLateralStrength        = DEFAULTS.TumbleLateralStrength,
		TumbleOnPierce               = DEFAULTS.TumbleOnPierce,
		TumbleRecoverySpeed          = DEFAULTS.TumbleRecoverySpeed,

		CanHomeFunction              = DEFAULTS.CanHomeFunction,
		HomingPositionProvider       = DEFAULTS.HomingPositionProvider,
		HomingStrength               = DEFAULTS.HomingStrength,
		HomingMaxDuration            = DEFAULTS.HomingMaxDuration,
		HomingAcquisitionRadius      = DEFAULTS.HomingAcquisitionRadius,

		SpeedThresholds              = {},
		SupersonicProfile            = DEFAULTS.SupersonicProfile,
		SubsonicProfile              = DEFAULTS.SubsonicProfile,

		TrajectoryPositionProvider   = DEFAULTS.TrajectoryPositionProvider,

		BulletMass                   = DEFAULTS.BulletMass,
		CastFunction                 = DEFAULTS.CastFunction,

		CanPierceFunction            = DEFAULTS.CanPierceFunction,
		MaxPierceCount               = DEFAULTS.MaxPierceCount,
		PierceSpeedThreshold         = DEFAULTS.PierceSpeedThreshold,
		PierceSpeedRetention         = DEFAULTS.PierceSpeedRetention,
		PierceNormalBias             = DEFAULTS.PierceNormalBias,
		PierceDepth                  = DEFAULTS.PierceDepth,
		PierceForce                  = DEFAULTS.PierceForce,
		PierceThicknessLimit         = DEFAULTS.PierceThicknessLimit,

		FragmentOnPierce             = DEFAULTS.FragmentOnPierce,
		FragmentCount                = DEFAULTS.FragmentCount,
		FragmentDeviation            = DEFAULTS.FragmentDeviation,

		CanBounceFunction            = DEFAULTS.CanBounceFunction,
		MaxBounces                   = DEFAULTS.MaxBounces,
		BounceSpeedThreshold         = DEFAULTS.BounceSpeedThreshold,
		Restitution                  = DEFAULTS.Restitution,
		MaterialRestitution          = {},
		NormalPerturbation           = DEFAULTS.NormalPerturbation,
		ResetPierceOnBounce          = DEFAULTS.ResetPierceOnBounce,

		HighFidelitySegmentSize      = DEFAULTS.HighFidelitySegmentSize,
		HighFidelityFrameBudget      = DEFAULTS.HighFidelityFrameBudget,
		AdaptiveScaleFactor          = DEFAULTS.AdaptiveScaleFactor,
		MinSegmentSize               = DEFAULTS.MinSegmentSize,
		MaxBouncesPerFrame           = DEFAULTS.MaxBouncesPerFrame,

		CornerTimeThreshold          = DEFAULTS.CornerTimeThreshold,
		CornerPositionHistorySize    = DEFAULTS.CornerPositionHistorySize,
		CornerDisplacementThreshold  = DEFAULTS.CornerDisplacementThreshold,
		CornerEMAAlpha               = DEFAULTS.CornerEMAAlpha,
		CornerEMAThreshold           = DEFAULTS.CornerEMAThreshold,
		CornerMinProgressPerBounce   = DEFAULTS.CornerMinProgressPerBounce,

		LODDistance                  = DEFAULTS.LODDistance,
		LODInterval                  = DEFAULTS.LODInterval,

		SixDOFEnabled                = DEFAULTS.SixDOFEnabled,
		LiftCoefficientSlope         = DEFAULTS.LiftCoefficientSlope,
		PitchingMomentSlope          = DEFAULTS.PitchingMomentSlope,
		PitchDampingCoeff            = DEFAULTS.PitchDampingCoeff,
		RollDampingCoeff             = DEFAULTS.RollDampingCoeff,
		AoADragFactor                = DEFAULTS.AoADragFactor,
		ReferenceArea                = DEFAULTS.ReferenceArea,
		ReferenceLength              = DEFAULTS.ReferenceLength,
		AirDensity                   = DEFAULTS.AirDensity,
		MomentOfInertia              = DEFAULTS.MomentOfInertia,
		SpinMOI                      = DEFAULTS.SpinMOI,
		MaxAngularSpeed              = DEFAULTS.MaxAngularSpeed,
		InitialOrientation           = DEFAULTS.InitialOrientation,
		InitialAngularVelocity       = DEFAULTS.InitialAngularVelocity,
		CLAlphaMachTable             = DEFAULTS.CLAlphaMachTable,
		CmAlphaMachTable             = DEFAULTS.CmAlphaMachTable,
		CmqMachTable                 = DEFAULTS.CmqMachTable,
		ClpMachTable                 = DEFAULTS.ClpMachTable,

		CosmeticBulletTemplate       = DEFAULTS.CosmeticBulletTemplate,
		CosmeticBulletContainer      = DEFAULTS.CosmeticBulletContainer,
		CosmeticBulletProvider       = DEFAULTS.CosmeticBulletProvider,
		AutoDeleteCosmeticBullet     = DEFAULTS.AutoDeleteCosmeticBullet,
		CosmeticBulletNonQueryable   = DEFAULTS.CosmeticBulletNonQueryable,

		BatchTravel                  = DEFAULTS.BatchTravel,
		FireTravelEvents             = DEFAULTS.FireTravelEvents,
		IsHitscan                    = DEFAULTS.IsHitscan,
		VisualizeCasts               = DEFAULTS.VisualizeCasts,
		UserData                     = DEFAULTS.UserData,
		StaticOccupancy              = DEFAULTS.StaticOccupancy,
		DynamicOccupancy             = DEFAULTS.DynamicOccupancy,
	}

	return setmetatable({ _Config = Config, _Dirty = {} }, BehaviorBuilder)
end

local function open(self: BehaviorBuilder, Builder: any): any
	return setmetatable({ _Root = self, _Config = self._Config, _Dirty = self._Dirty }, Builder)
end

function BehaviorBuilder.Physics(self: BehaviorBuilder): PhysicsBuilder.PhysicsBuilder
	return open(self, PhysicsBuilder)
end
function BehaviorBuilder.Homing(self: BehaviorBuilder): HomingBuilder.HomingBuilder
	return open(self, HomingBuilder)
end
function BehaviorBuilder.Pierce(self: BehaviorBuilder): PierceBuilder.PierceBuilder
	return open(self, PierceBuilder)
end
function BehaviorBuilder.Bounce(self: BehaviorBuilder): BounceBuilder.BounceBuilder
	return open(self, BounceBuilder)
end
function BehaviorBuilder.HighFidelity(self: BehaviorBuilder): HighFidelityBuilder.HighFidelityBuilder
	return open(self, HighFidelityBuilder)
end
function BehaviorBuilder.CornerTrap(self: BehaviorBuilder): CornerTrapBuilder.CornerTrapBuilder
	return open(self, CornerTrapBuilder)
end
function BehaviorBuilder.Cosmetic(self: BehaviorBuilder): CosmeticBuilder.CosmeticBuilder
	return open(self, CosmeticBuilder)
end
function BehaviorBuilder.Debug(self: BehaviorBuilder): DebugBuilder.DebugBuilder
	return open(self, DebugBuilder)
end
function BehaviorBuilder.Drag(self: BehaviorBuilder): DragBuilder.DragBuilder
	return open(self, DragBuilder)
end
function BehaviorBuilder.Wind(self: BehaviorBuilder): WindBuilder.WindBuilder
	return open(self, WindBuilder)
end
function BehaviorBuilder.Magnus(self: BehaviorBuilder): MagnusBuilder.MagnusBuilder
	return open(self, MagnusBuilder)
end
function BehaviorBuilder.GyroDrift(self: BehaviorBuilder): GyroDriftBuilder.GyroDriftBuilder
	return open(self, GyroDriftBuilder)
end
function BehaviorBuilder.Tumble(self: BehaviorBuilder): TumbleBuilder.TumbleBuilder
	return open(self, TumbleBuilder)
end
function BehaviorBuilder.Fragmentation(self: BehaviorBuilder): FragmentationBuilder.FragmentationBuilder
	return open(self, FragmentationBuilder)
end
function BehaviorBuilder.SpeedProfiles(self: BehaviorBuilder): SpeedProfilesModule.SpeedProfilesBuilder
	return open(self, SpeedProfilesBuilder)
end
function BehaviorBuilder.Trajectory(self: BehaviorBuilder): TrajectoryBuilder.TrajectoryBuilder
	return open(self, TrajectoryBuilder)
end
function BehaviorBuilder.LOD(self: BehaviorBuilder): LODBuilder.LODBuilder
	return open(self, LODBuilder)
end
function BehaviorBuilder.SixDOF(self: BehaviorBuilder): SixDOFBuilder.SixDOFBuilder
	return open(self, SixDOFBuilder)
end

function BehaviorBuilder.BatchTravel(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
	assert(type(Value) == "boolean", "BehaviorBuilder:BatchTravel — expected boolean")
	self._Config.BatchTravel = Value
	self._Dirty.BatchTravel  = true
	return self
end

function BehaviorBuilder.FireTravelEvents(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
	assert(type(Value) == "boolean", "BehaviorBuilder:FireTravelEvents — expected boolean")
	self._Config.FireTravelEvents = Value
	self._Dirty.FireTravelEvents  = true
	return self
end

function BehaviorBuilder.Hitscan(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
	assert(type(Value) == "boolean", "BehaviorBuilder:Hitscan — expected boolean")
	self._Config.IsHitscan = Value
	self._Dirty.IsHitscan  = true
	return self
end

function BehaviorBuilder.UserData(self: BehaviorBuilder, Value: any): BehaviorBuilder
	self._Config.UserData = Value
	self._Dirty.UserData  = true
	return self
end

function BehaviorBuilder.StaticOccupancy(self: BehaviorBuilder, Grid: any): BehaviorBuilder
	assert(
		Grid == nil or (type(Grid) == "table" and type(Grid.SegmentClear) == "function"),
		"BehaviorBuilder:StaticOccupancy — expected a StaticOccupancy instance or nil"
	)
	self._Config.StaticOccupancy = Grid
	self._Dirty.StaticOccupancy  = true
	return self
end

function BehaviorBuilder.DynamicOccupancy(self: BehaviorBuilder, Set: any): BehaviorBuilder
	assert(
		Set == nil or (type(Set) == "table" and type(Set.SegmentClear) == "function"),
		"BehaviorBuilder:DynamicOccupancy — expected a DynamicOccupancy instance or nil"
	)
	self._Config.DynamicOccupancy = Set
	self._Dirty.DynamicOccupancy  = true
	return self
end

function BehaviorBuilder.Clone(self: BehaviorBuilder): BehaviorBuilder
	local NewConfig = cloneConfig(self._Config)
	local NewDirty  = table.clone(self._Dirty)
	return setmetatable({ _Config = NewConfig, _Dirty = NewDirty }, BehaviorBuilder)
end

function BehaviorBuilder.Impose(self: BehaviorBuilder, Other: BehaviorBuilder): BehaviorBuilder
	assert(
		type(Other) == "table" and type(Other._Dirty) == "table" and type(Other._Config) == "table",
		"BehaviorBuilder:Impose — expected a BehaviorBuilder"
	)

	for Field in Other._Dirty do
		if TABLE_FIELDS[Field] then
			local SrcValue = (Other._Config :: any)[Field]
			if SrcValue ~= nil then
				(self._Config :: any)[Field] = table.clone(SrcValue)
			else
				(self._Config :: any)[Field] = nil
			end
		else
			(self._Config :: any)[Field] = (Other._Config :: any)[Field]
		end
		self._Dirty[Field] = true
	end

	return self
end

function BehaviorBuilder.Merge(self: BehaviorBuilder, ...: BehaviorBuilder): BehaviorBuilder
	local Result = self:Clone()
	for _, Mod in { ... } do
		Result:Impose(Mod)
	end
	return Result
end

function BehaviorBuilder.Inherit(Frozen: BuiltBehavior): BehaviorBuilder
	assert(type(Frozen) == "table", "BehaviorBuilder.Inherit — expected a frozen VetraBehavior table")

	local Config = cloneConfig(Frozen :: any)

	local Dirty: DirtySet = {}
	for Key in Config :: any do
		Dirty[Key] = true
	end

	return setmetatable({ _Config = Config, _Dirty = Dirty }, BehaviorBuilder)
end

function BehaviorBuilder.When(
	self: BehaviorBuilder,
	Condition: any,
	Fn: (BehaviorBuilder) -> ()
): BehaviorBuilder
	assert(type(Fn) == "function", "BehaviorBuilder:When — expected function as second argument")
	if Condition then
		Fn(self)
	end
	return self
end

function BehaviorBuilder.Build(self: BehaviorBuilder): BuiltBehavior?
	local Errors = ValidateBuilt(self._Config)

	if #Errors > 0 then
		warn(string.format("BehaviorBuilder:Build — %d validation error(s):", #Errors))
		for _, Msg in ipairs(Errors) do
			warn("  • " .. Msg)
		end
		return nil
	end

	local Final = table.clone(self._Config)
	Final.MaterialRestitution = table.clone(self._Config.MaterialRestitution)
	Final.SpeedThresholds     = table.clone(self._Config.SpeedThresholds)

	return Final
end

function BehaviorBuilder.Sniper(): BehaviorBuilder
	return BehaviorBuilder.new()
		:Physics()
			:MaxDistance(1500)
			:MinSpeed(50)
		:Done()
		:Pierce()
			:Max(3)
			:SpeedThreshold(200)
			:SpeedRetention(0.9)
			:NormalBias(0.8)
			:Filter(function(_ctx, _result, _vel) return true end)
		:Done()
		:HighFidelity()
			:SegmentSize(0.2)
			:FrameBudget(2)
		:Done()
end

function BehaviorBuilder.Grenade(): BehaviorBuilder
	return BehaviorBuilder.new()
		:Physics()
			:MaxDistance(400)
			:MinSpeed(2)
		:Done()
		:Bounce()
			:Max(6)
			:SpeedThreshold(10)
			:Restitution(0.55)
			:NormalPerturbation(0.05)
			:Filter(function(_ctx, _result, _vel) return true end)
		:Done()
		:CornerTrap()
			:TimeThreshold(0.005)
			:DisplacementThreshold(0.3)
		:Done()
		:HighFidelity()
			:SegmentSize(0.4)
		:Done()
end

function BehaviorBuilder.Pistol(): BehaviorBuilder
	return BehaviorBuilder.new()
		:Physics()
			:MaxDistance(300)
			:MinSpeed(5)
		:Done()
		:Pierce()
			:Max(1)
			:SpeedThreshold(80)
			:SpeedRetention(0.75)
			:Filter(function(_ctx, _result, _vel) return true end)
		:Done()
end

export type BehaviorBuilder = typeof(setmetatable({} :: {
	_Config : BuiltBehavior,
	_Dirty  : DirtySet,
}, BehaviorBuilder))

return table.freeze(BehaviorBuilder)
