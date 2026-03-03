--!native
--!optimize 2
--!strict

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    Version: 2.0.0
]]

-- ─── BehaviorBuilder ─────────────────────────────────────────────────────────
--[[
    BehaviorBuilder — Fluent typed configuration builder for Vetra.

    Instead of constructing raw behavior tables by hand:

        local Behavior = {
            MaxDistance = 300,
            MaxBounces = 3,
            Restitution = 0.6,
            CanBounceFunction = function(...) return true end,
        }

    You chain methods:

        local Behavior = BehaviorBuilder.new()
            :Physics()
                :MaxDistance(300)
                :MinSpeed(5)
                :Gravity(Vector3.new(0, 50, 0))
            :Done()
            :Bounce()
                :Max(3)
                :Restitution(0.6)
                :SpeedThreshold(20)
                :Filter(function(ctx, result, vel) return true end)
            :Done()
            :Build()

    Design Goals:
        1. Every method is typed — passing a string where a number is expected
           is a compile-time error in strict mode, not a silent runtime bug.
        2. Grouped namespaces (Physics, Bounce, Pierce, HighFidelity, Cosmetic,
           Debug) mirror the logical sections of VetraBehavior, making it clear
           which fields belong together.
        3. :Done() returns the parent builder so groups are self-contained
           and composable. You never have to mentally track which table you
           are currently configuring.
        4. :Build() performs a final validation pass and returns a frozen
           VetraBehavior table. Frozen so consumers cannot mutate it after
           the fact and produce inconsistent state mid-flight.
        5. Builders are reusable — call :Build() multiple times to produce
           independent behavior tables from the same configured builder.
           Useful for weapon archetypes where many bullets share the same
           base configuration.

    Namespace Overview:
        :Physics()      → MaxDistance, MinSpeed, Gravity, Acceleration, RaycastParams
        :Pierce()       → Filter, Max, SpeedThreshold, SpeedRetention, NormalBias
        :Bounce()       → Filter, Max, SpeedThreshold, Restitution,
                          MaterialRestitution, NormalPerturbation
        :HighFidelity() → SegmentSize, FrameBudget, AdaptiveScale,
                          MinSegmentSize, MaxBouncesPerFrame
        :CornerTrap()   → TimeThreshold, NormalDotThreshold, DisplacementThreshold
        :Cosmetic()     → Template, Container, Provider
        :Debug()        → Visualize

    Each namespace method returns a sub-builder. Sub-builders expose only the
    fields relevant to that group, preventing cross-group assignments like
    accidentally setting Restitution inside the Pierce group. Calling :Done()
    on a sub-builder returns the root BehaviorBuilder.
]]

-- ─── Services ────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── Module References ───────────────────────────────────────────────────────

local Utilities = ReplicatedStorage.Shared.Modules.Utilities
local LogService = require(Utilities.Logger)
local t = require(Utilities.TypeCheck)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local IDENTITY = "BehaviorBuilder"
local Logger = LogService.new(IDENTITY, true)

-- ─── Type Definitions ────────────────────────────────────────────────────────

-- Mirror of VetraBehavior from Vetra for self-contained typing.
-- These are all optional at the builder level — :Build() merges with defaults.
type BulletContext = any
type PierceFilter  = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
type BounceFilter  = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
type BulletProvider = () -> Instance?

type BuiltBehavior = {
	-- Physics
	Acceleration                 : Vector3,
	MaxDistance                  : number,
	RaycastParams                : RaycastParams,
	Gravity                      : Vector3,
	MinSpeed                     : number,
	-- Pierce
	CanPierceFunction            : PierceFilter?,
	MaxPierceCount               : number,
	PierceSpeedThreshold         : number,
	PenetrationSpeedRetention    : number,
	PierceNormalBias             : number,
	-- Bounce
	CanBounceFunction            : BounceFilter?,
	MaxBounces                   : number,
	ResetPierceOnBounce          : boolean,
	BounceSpeedThreshold         : number,
	Restitution                  : number,
	MaterialRestitution          : { [Enum.Material]: number },
	NormalPerturbation           : number,
	-- High Fidelity
	HighFidelitySegmentSize      : number,
	HighFidelityFrameBudget      : number,
	AdaptiveScaleFactor          : number,
	MinSegmentSize               : number,
	MaxBouncesPerFrame           : number,
	-- Corner Trap
	CornerTimeThreshold          : number,
	CornerNormalDotThreshold     : number,
	CornerDisplacementThreshold  : number,
	-- Cosmetic
	CosmeticBulletTemplate       : BasePart?,
	CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : BulletProvider?,
	-- Debug
	VisualizeCasts               : boolean,
}

-- ─── Defaults ────────────────────────────────────────────────────────────────
--[[
    Canonical defaults mirroring Vetra's DEFAULT_BEHAVIOR.
    Gravity is stored as a downward vector (negative Y) to match DEFAULT_GRAVITY.
    BehaviorBuilder uses this convention consistently — no sign ambiguity.
]]
local DEFAULTS: BuiltBehavior = {
	Acceleration                 = Vector3.zero,
	MaxDistance                  = 500,
	RaycastParams                = RaycastParams.new(),
	Gravity                      = Vector3.new(0, -workspace.Gravity, 0),
	MinSpeed                     = 1,

	CanPierceFunction            = nil,
	MaxPierceCount               = 3,
	PierceSpeedThreshold         = 50,
	PenetrationSpeedRetention    = 0.8,
	PierceNormalBias             = 1.0,

	CanBounceFunction            = nil,
	MaxBounces                   = 5,
	BounceSpeedThreshold         = 20,
	Restitution                  = 0.7,
	MaterialRestitution          = {},
	NormalPerturbation           = 0.0,

	HighFidelitySegmentSize      = 0.5,
	HighFidelityFrameBudget      = 4,
	AdaptiveScaleFactor          = 1.5,
	MinSegmentSize               = 0.1,
	MaxBouncesPerFrame           = 10,

	CornerTimeThreshold          = 0.002,
	CornerNormalDotThreshold     = -0.85,
	CornerDisplacementThreshold  = 0.5,

	CosmeticBulletTemplate       = nil,
	CosmeticBulletContainer      = nil,
	CosmeticBulletProvider       = nil,

	ResetPierceOnBounce 		 = false,
	VisualizeCasts               = false,
}

-- ─── Validation Helpers ──────────────────────────────────────────────────────

--[[
    These run during :Build() rather than per-setter call. Deferring validation
    to build time means the builder never throws mid-chain, making it easier to
    construct behaviors conditionally without try/catch gymnastics.
    Returns a list of error strings so all problems are reported at once.
]]
local function ValidateBuilt(B: BuiltBehavior): { string }
	local Errors = {}

	local function Expect(Condition: boolean, Message: string)
		if not Condition then
			Errors[#Errors + 1] = Message
		end
	end

	-- Physics
	Expect(B.MaxDistance > 0,   "MaxDistance must be > 0")
	Expect(B.MinSpeed   >= 0,   "MinSpeed must be >= 0")

	-- Pierce
	Expect(B.MaxPierceCount           >= 0, "MaxPierceCount must be >= 0")
	Expect(B.PierceSpeedThreshold     >= 0, "PierceSpeedThreshold must be >= 0")
	Expect(B.PenetrationSpeedRetention >= 0 and B.PenetrationSpeedRetention <= 1,
		"PenetrationSpeedRetention must be in [0, 1]")
	Expect(B.PierceNormalBias >= 0 and B.PierceNormalBias <= 1,
		"PierceNormalBias must be in [0, 1]")

	-- Bounce
	Expect(B.MaxBounces              >= 0, "MaxBounces must be >= 0")
	Expect(B.BounceSpeedThreshold    >= 0, "BounceSpeedThreshold must be >= 0")
	Expect(B.Restitution             >= 0 and B.Restitution <= 1,
		"Restitution must be in [0, 1]")
	Expect(B.NormalPerturbation      >= 0, "NormalPerturbation must be >= 0")

	-- High Fidelity
	Expect(B.HighFidelitySegmentSize > 0,  "HighFidelitySegmentSize must be > 0")
	Expect(B.HighFidelityFrameBudget > 0,  "HighFidelityFrameBudget must be > 0")
	Expect(B.AdaptiveScaleFactor     > 1,  "AdaptiveScaleFactor must be > 1")
	Expect(B.MinSegmentSize          > 0,  "MinSegmentSize must be > 0")
	Expect(B.MaxBouncesPerFrame      >= 1, "MaxBouncesPerFrame must be >= 1")
	Expect(B.MinSegmentSize <= B.HighFidelitySegmentSize,
		"MinSegmentSize must be <= HighFidelitySegmentSize")

	-- Corner Trap
	Expect(B.CornerTimeThreshold         >= 0,   "CornerTimeThreshold must be >= 0")
	Expect(B.CornerNormalDotThreshold    >= -1 and B.CornerNormalDotThreshold <= 0,
		"CornerNormalDotThreshold must be in [-1, 0]")
	Expect(B.CornerDisplacementThreshold >= 0,   "CornerDisplacementThreshold must be >= 0")

	-- Cosmetic
	if B.CosmeticBulletProvider ~= nil and B.CosmeticBulletTemplate ~= nil then
		Errors[#Errors + 1] = "CosmeticBulletProvider and CosmeticBulletTemplate are mutually exclusive — Provider takes priority"
	end

	return Errors
end

-- ─── Sub-Builders ────────────────────────────────────────────────────────────

--[[
    Each sub-builder holds a reference back to the root BehaviorBuilder (_Root)
    and writes directly into the root's _Config table. This means:
        - There is exactly one config table per builder chain.
        - :Done() is a zero-cost return of _Root — no merging required at build time.
        - Sub-builders can be held and reused independently (advanced use case).
]]

-- ── Physics Sub-Builder ──────────────────────────────────────────────────────

local PhysicsBuilder = {}
PhysicsBuilder.__index = PhysicsBuilder

export type PhysicsBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, PhysicsBuilder))

--[=[
    :MaxDistance(studs)
    Sets the maximum distance the bullet can travel before expiring.
    Default: 500
]=]
function PhysicsBuilder.MaxDistance(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:MaxDistance — expected number")
	self._Config.MaxDistance = Value
	return self
end

--[=[
    :MinSpeed(studsPerSecond)
    If the bullet's speed falls below this value it terminates naturally.
    Default: 1
]=]
function PhysicsBuilder.MinSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:MinSpeed — expected number")
	self._Config.MinSpeed = Value
	return self
end

--[=[
    :Gravity(vector)
    Downward gravitational acceleration applied to the bullet.
    Pass a negative-Y vector for downward gravity, e.g. Vector3.new(0, -workspace.Gravity, 0).
    Default: Vector3.new(0, -workspace.Gravity, 0)
]=]
function PhysicsBuilder.Gravity(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
	assert(t.Vector3(Value), "PhysicsBuilder:Gravity — expected Vector3")
	self._Config.Gravity = Value
	return self
end

--[=[
    :Acceleration(vector)
    Extra constant acceleration layered on top of gravity (e.g. rocket thrust, wind).
    Default: Vector3.zero
]=]
function PhysicsBuilder.Acceleration(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
	assert(t.Vector3(Value), "PhysicsBuilder:Acceleration — expected Vector3")
	self._Config.Acceleration = Value
	return self
end

--[=[
    :RaycastParams(params)
    The RaycastParams used for all raycasts during this cast's lifetime.
    The solver clones these internally — the original is never mutated.
    Default: RaycastParams.new()
]=]
function PhysicsBuilder.RaycastParams(self: PhysicsBuilder, Value: RaycastParams): PhysicsBuilder
	assert(typeof(Value) == "RaycastParams", "PhysicsBuilder:RaycastParams — expected RaycastParams")
	self._Config.RaycastParams = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder to continue chaining other groups.
]=]
function PhysicsBuilder.Done(self: PhysicsBuilder): any
	return self._Root
end

-- ── Pierce Sub-Builder ───────────────────────────────────────────────────────

local PierceBuilder = {}
PierceBuilder.__index = PierceBuilder

export type PierceBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, PierceBuilder))

--[=[
    :Filter(callback)
    A function called for each hit. Return true to allow piercing.
    Signature: (Context, RaycastResult, Velocity: Vector3) -> boolean
    Default: nil (no piercing)
]=]
function PierceBuilder.Filter(self: PierceBuilder, Callback: PierceFilter): PierceBuilder
	assert(type(Callback) == "function", "PierceBuilder:Filter — expected function")
	self._Config.CanPierceFunction = Callback
	return self
end

--[=[
    :Max(count)
    Maximum number of surfaces the bullet can pierce before stopping.
    Default: 3
]=]
function PierceBuilder.Max(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:Max — expected number")
	self._Config.MaxPierceCount = Value
	return self
end

--[=[
    :SpeedThreshold(studsPerSecond)
    Minimum speed required for a pierce to be attempted.
    Default: 50
]=]
function PierceBuilder.SpeedThreshold(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:SpeedThreshold — expected number")
	self._Config.PierceSpeedThreshold = Value
	return self
end

--[=[
    :SpeedRetention(fraction)
    Fraction of speed retained after each pierce. Must be in [0, 1].
    0.8 means 20% of speed is lost per pierce.
    Default: 0.8
]=]
function PierceBuilder.SpeedRetention(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:SpeedRetention — expected number")
	self._Config.PenetrationSpeedRetention = Value
	return self
end

--[=[
    :NormalBias(value)
    Restricts piercing to impacts above a minimum head-on angle. Must be in [0, 1].
    1.0 = all angles allowed. 0.0 = only perfectly perpendicular impacts.
    Default: 1.0
]=]
function PierceBuilder.NormalBias(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:NormalBias — expected number")
	self._Config.PierceNormalBias = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function PierceBuilder.Done(self: PierceBuilder): any
	return self._Root
end

-- ── Bounce Sub-Builder ───────────────────────────────────────────────────────

local BounceBuilder = {}
BounceBuilder.__index = BounceBuilder

export type BounceBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, BounceBuilder))

--[=[
    :ResetPierceOnBounce(enabled)
    When true, pierce state (filter, PiercedInstances, PierceCount) is
    automatically reset after each confirmed bounce, restoring the full
    pierce budget for the new arc. Required for bounce + pierce combinations
    where the post-bounce trajectory should be able to re-detect previously
    pierced surfaces.
    Default: false
]=]
function BounceBuilder.ResetPierceOnBounce(self: BounceBuilder, Value: boolean): BounceBuilder
    assert(type(Value) == "boolean", "BounceBuilder:ResetPierceOnBounce — expected boolean")
    self._Config.ResetPierceOnBounce = Value
    return self
end

--[=[
    :Filter(callback)
    A function called for each hit. Return true to allow bouncing.
    Signature: (Context, RaycastResult, Velocity: Vector3) -> boolean
    Default: nil (no bouncing)
]=]
function BounceBuilder.Filter(self: BounceBuilder, Callback: BounceFilter): BounceBuilder
	assert(type(Callback) == "function", "BounceBuilder:Filter — expected function")
	self._Config.CanBounceFunction = Callback
	return self
end

--[=[
    :Max(count)
    Maximum total bounces across the bullet's entire lifetime.
    Default: 5
]=]
function BounceBuilder.Max(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:Max — expected number")
	self._Config.MaxBounces = Value
	return self
end

--[=[
    :SpeedThreshold(studsPerSecond)
    Minimum speed required for a bounce to be attempted.
    Default: 20
]=]
function BounceBuilder.SpeedThreshold(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:SpeedThreshold — expected number")
	self._Config.BounceSpeedThreshold = Value
	return self
end

--[=[
    :Restitution(fraction)
    Fraction of speed retained after each bounce. Must be in [0, 1].
    1.0 = perfectly elastic. 0.0 = bullet stops on first contact.
    Default: 0.7
]=]
function BounceBuilder.Restitution(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:Restitution — expected number")
	self._Config.Restitution = Value
	return self
end

--[=[
    :MaterialRestitution(map)
    Per-material restitution multipliers, keyed by Enum.Material.
    Overrides base Restitution for specific surface types.
    Example: { [Enum.Material.Concrete] = 0.5, [Enum.Material.Plastic] = 0.9 }
    Default: {}
]=]
function BounceBuilder.MaterialRestitution(
	self: BounceBuilder,
	Value: { [Enum.Material]: number }
): BounceBuilder
	assert(type(Value) == "table", "BounceBuilder:MaterialRestitution — expected table")
	self._Config.MaterialRestitution = Value
	return self
end

--[=[
    :NormalPerturbation(amount)
    Adds random noise to the surface normal before reflecting.
    Simulates rough or irregular surfaces. 0 = clean mirror reflection.
    Default: 0.0
]=]
function BounceBuilder.NormalPerturbation(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:NormalPerturbation — expected number")
	self._Config.NormalPerturbation = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function BounceBuilder.Done(self: BounceBuilder): any
	return self._Root
end

-- ── HighFidelity Sub-Builder ─────────────────────────────────────────────────

local HighFidelityBuilder = {}
HighFidelityBuilder.__index = HighFidelityBuilder

export type HighFidelityBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, HighFidelityBuilder))

--[=[
    :SegmentSize(studs)
    Starting sub-segment length for high-fidelity raycasting.
    Smaller values = more raycasts per frame = better thin-surface detection.
    Default: 0.5
]=]
function HighFidelityBuilder.SegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:SegmentSize — expected number")
	self._Config.HighFidelitySegmentSize = Value
	return self
end

--[=[
    :FrameBudget(milliseconds)
    Maximum milliseconds this cast may spend on sub-segment raycasts per frame.
    Default: 4
]=]
function HighFidelityBuilder.FrameBudget(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:FrameBudget — expected number")
	self._Config.HighFidelityFrameBudget = Value
	return self
end

--[=[
    :AdaptiveScale(factor)
    Multiplier applied when coarsening or refining segment size adaptively.
    Must be > 1. Higher values adapt faster but less precisely.
    Default: 1.5
]=]
function HighFidelityBuilder.AdaptiveScale(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:AdaptiveScale — expected number")
	self._Config.AdaptiveScaleFactor = Value
	return self
end

--[=[
    :MinSegmentSize(studs)
    Hard floor for adaptive segment size reduction. Must be <= SegmentSize.
    Default: 0.1
]=]
function HighFidelityBuilder.MinSegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:MinSegmentSize — expected number")
	self._Config.MinSegmentSize = Value
	return self
end

--[=[
    :MaxBouncesPerFrame(count)
    Maximum bounces allowed across all sub-segments within a single frame step.
    Prevents a bullet from exhausting its lifetime bounce budget in one frame.
    Default: 10
]=]
function HighFidelityBuilder.MaxBouncesPerFrame(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:MaxBouncesPerFrame — expected number")
	self._Config.MaxBouncesPerFrame = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function HighFidelityBuilder.Done(self: HighFidelityBuilder): any
	return self._Root
end

-- ── CornerTrap Sub-Builder ───────────────────────────────────────────────────

local CornerTrapBuilder = {}
CornerTrapBuilder.__index = CornerTrapBuilder

export type CornerTrapBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, CornerTrapBuilder))

--[=[
    :TimeThreshold(seconds)
    Two bounces within this interval are flagged as a corner trap.
    Default: 0.002
]=]
function CornerTrapBuilder.TimeThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:TimeThreshold — expected number")
	self._Config.CornerTimeThreshold = Value
	return self
end

--[=[
    :NormalDotThreshold(value)
    If two consecutive surface normals have a dot product below this value
    they are considered opposing (trapped). Must be in [-1, 0].
    Default: -0.85
]=]
function CornerTrapBuilder.NormalDotThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:NormalDotThreshold — expected number")
	self._Config.CornerNormalDotThreshold = Value
	return self
end

--[=[
    :DisplacementThreshold(studs)
    Minimum distance between successive bounce contact points.
    Below this the bullet is considered stuck.
    Default: 0.5
]=]
function CornerTrapBuilder.DisplacementThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:DisplacementThreshold — expected number")
	self._Config.CornerDisplacementThreshold = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function CornerTrapBuilder.Done(self: CornerTrapBuilder): any
	return self._Root
end

-- ── Cosmetic Sub-Builder ─────────────────────────────────────────────────────

local CosmeticBuilder = {}
CosmeticBuilder.__index = CosmeticBuilder

export type CosmeticBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, CosmeticBuilder))

--[=[
    :Template(part)
    A BasePart cloned once per Fire() call as the visible bullet.
    Mutually exclusive with :Provider(). Provider takes priority if both are set.
    Default: nil
]=]
function CosmeticBuilder.Template(self: CosmeticBuilder, Value: BasePart): CosmeticBuilder
	assert(typeof(Value) == "Instance" and Value:IsA("BasePart"),
		"CosmeticBuilder:Template — expected BasePart")
	self._Config.CosmeticBulletTemplate = Value
	return self
end

--[=[
    :Container(instance)
    Parent for the cosmetic bullet object. Defaults to workspace if nil.
    Default: nil (workspace)
]=]
function CosmeticBuilder.Container(self: CosmeticBuilder, Value: Instance): CosmeticBuilder
	assert(typeof(Value) == "Instance", "CosmeticBuilder:Container — expected Instance")
	self._Config.CosmeticBulletContainer = Value
	return self
end

--[=[
    :Provider(callback)
    A function called once per Fire() that returns the cosmetic bullet Instance.
    Use this for object pooling or procedural creation. Must be synchronous.
    Takes priority over :Template() if both are set.
    Signature: () -> Instance?
    Default: nil
]=]
function CosmeticBuilder.Provider(self: CosmeticBuilder, Callback: BulletProvider): CosmeticBuilder
	assert(type(Callback) == "function", "CosmeticBuilder:Provider — expected function")
	self._Config.CosmeticBulletProvider = Callback
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function CosmeticBuilder.Done(self: CosmeticBuilder): any
	return self._Root
end

-- ── Debug Sub-Builder ────────────────────────────────────────────────────────

local DebugBuilder = {}
DebugBuilder.__index = DebugBuilder

export type DebugBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, DebugBuilder))

--[=[
    :Visualize(enabled)
    Enables the debug visualizer for cast segments, normals, bounces, and
    corner traps. Zero runtime cost when false.
    Default: false
]=]
function DebugBuilder.Visualize(self: DebugBuilder, Value: boolean): DebugBuilder
	assert(type(Value) == "boolean", "DebugBuilder:Visualize — expected boolean")
	self._Config.VisualizeCasts = Value
	return self
end

--[=[
    :Done()
    Returns the root BehaviorBuilder.
]=]
function DebugBuilder.Done(self: DebugBuilder): any
	return self._Root
end

-- ─── Root Builder ────────────────────────────────────────────────────────────

local BehaviorBuilder = {}
BehaviorBuilder.__index = BehaviorBuilder

export type BehaviorBuilder = typeof(setmetatable({} :: {
	_Config : BuiltBehavior,
}, BehaviorBuilder))

--[=[
    BehaviorBuilder.new()

    Creates a new builder pre-populated with all default values.
    Call namespace methods to open a group, chain setters within it,
    call :Done() to return here, then :Build() to produce the final table.

    Example:

        local MyBehavior = BehaviorBuilder.new()
            :Physics()
                :MaxDistance(400)
                :MinSpeed(10)
            :Done()
            :Bounce()
                :Max(4)
                :Restitution(0.65)
                :Filter(function(ctx, result, vel)
                    return result.Instance:HasTag("Bouncy")
                end)
            :Done()
            :HighFidelity()
                :SegmentSize(0.3)
            :Done()
            :Build()
]=]
function BehaviorBuilder.new(): BehaviorBuilder
	-- Deep-copy DEFAULTS so each builder instance has its own config table.
	-- Shallow copy would mean all builders share the same MaterialRestitution
	-- and RaycastParams references, causing cross-instance mutations.
	local Config: BuiltBehavior = {
		Acceleration                 = DEFAULTS.Acceleration,
		MaxDistance                  = DEFAULTS.MaxDistance,
		RaycastParams                = DEFAULTS.RaycastParams,
		Gravity                      = DEFAULTS.Gravity,
		MinSpeed                     = DEFAULTS.MinSpeed,

		CanPierceFunction            = DEFAULTS.CanPierceFunction,
		MaxPierceCount               = DEFAULTS.MaxPierceCount,
		PierceSpeedThreshold         = DEFAULTS.PierceSpeedThreshold,
		PenetrationSpeedRetention    = DEFAULTS.PenetrationSpeedRetention,
		PierceNormalBias             = DEFAULTS.PierceNormalBias,

		CanBounceFunction            = DEFAULTS.CanBounceFunction,
		MaxBounces                   = DEFAULTS.MaxBounces,
		BounceSpeedThreshold         = DEFAULTS.BounceSpeedThreshold,
		Restitution                  = DEFAULTS.Restitution,
		MaterialRestitution          = {},  -- always a fresh table
		NormalPerturbation           = DEFAULTS.NormalPerturbation,

		HighFidelitySegmentSize      = DEFAULTS.HighFidelitySegmentSize,
		HighFidelityFrameBudget      = DEFAULTS.HighFidelityFrameBudget,
		AdaptiveScaleFactor          = DEFAULTS.AdaptiveScaleFactor,
		MinSegmentSize               = DEFAULTS.MinSegmentSize,
		MaxBouncesPerFrame           = DEFAULTS.MaxBouncesPerFrame,
		ResetPierceOnBounce 		 = DEFAULTS.ResetPierceOnBounce,
		CornerTimeThreshold          = DEFAULTS.CornerTimeThreshold,
		CornerNormalDotThreshold     = DEFAULTS.CornerNormalDotThreshold,
		CornerDisplacementThreshold  = DEFAULTS.CornerDisplacementThreshold,

		CosmeticBulletTemplate       = DEFAULTS.CosmeticBulletTemplate,
		CosmeticBulletContainer      = DEFAULTS.CosmeticBulletContainer,
		CosmeticBulletProvider       = DEFAULTS.CosmeticBulletProvider,

		VisualizeCasts               = DEFAULTS.VisualizeCasts,
	}

	return setmetatable({ _Config = Config }, BehaviorBuilder)
end

-- ─── Namespace Openers ───────────────────────────────────────────────────────
--[[
    Each opener constructs a sub-builder that writes into the root's _Config
    and holds a _Root back-reference for :Done(). The sub-builder is returned
    directly so the caller can immediately chain its methods.
]]

--[=[
    :Physics()
    Opens the Physics configuration group.
    Available methods: MaxDistance, MinSpeed, Gravity, Acceleration, RaycastParams
]=]
function BehaviorBuilder.Physics(self: BehaviorBuilder): PhysicsBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, PhysicsBuilder)
end

--[=[
    :Pierce()
    Opens the Pierce configuration group.
    Available methods: Filter, Max, SpeedThreshold, SpeedRetention, NormalBias
]=]
function BehaviorBuilder.Pierce(self: BehaviorBuilder): PierceBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, PierceBuilder)
end

--[=[
    :Bounce()
    Opens the Bounce configuration group.
    Available methods: Filter, Max, SpeedThreshold, Restitution,
                       MaterialRestitution, NormalPerturbation,
                       ResetPierceOnBounce
]=]
function BehaviorBuilder.Bounce(self: BehaviorBuilder): BounceBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, BounceBuilder)
end

--[=[
    :HighFidelity()
    Opens the HighFidelity configuration group.
    Available methods: SegmentSize, FrameBudget, AdaptiveScale,
                       MinSegmentSize, MaxBouncesPerFrame
]=]
function BehaviorBuilder.HighFidelity(self: BehaviorBuilder): HighFidelityBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, HighFidelityBuilder)
end

--[=[
    :CornerTrap()
    Opens the CornerTrap configuration group.
    Available methods: TimeThreshold, NormalDotThreshold, DisplacementThreshold
]=]
function BehaviorBuilder.CornerTrap(self: BehaviorBuilder): CornerTrapBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, CornerTrapBuilder)
end

--[=[
    :Cosmetic()
    Opens the Cosmetic configuration group.
    Available methods: Template, Container, Provider
]=]
function BehaviorBuilder.Cosmetic(self: BehaviorBuilder): CosmeticBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, CosmeticBuilder)
end

--[=[
    :Debug()
    Opens the Debug configuration group.
    Available methods: Visualize
]=]
function BehaviorBuilder.Debug(self: BehaviorBuilder): DebugBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, DebugBuilder)
end

-- ─── Build ───────────────────────────────────────────────────────────────────

--[=[
    BehaviorBuilder:Build()

    Validates the current configuration and returns a frozen BuiltBehavior table
    ready to pass to Vetra:Fire().

    Validation errors are all collected and logged together so the caller sees
    every problem at once rather than fixing them one at a time. If any errors
    exist, :Build() returns nil and logs each error individually.

    The returned table is frozen (table.freeze) to prevent accidental mutation
    after the fact. Passing a frozen behavior to Fire() means the solver can
    read it without defensive copies on every field access.

    :Build() does NOT consume the builder — calling it multiple times produces
    independent frozen tables from the same configuration. This is intentional:
    weapon archetypes can configure a builder once and call :Build() per
    projectile type that shares the base config with minor overrides applied
    before each build.

    Returns:
        BuiltBehavior | nil
            The frozen behavior table, or nil if validation failed.
]=]
function BehaviorBuilder.Build(self: BehaviorBuilder): BuiltBehavior?
	local Errors = ValidateBuilt(self._Config)

	if #Errors > 0 then
		Logger:Warn(string.format(
			"BehaviorBuilder:Build — %d validation error(s):",
			#Errors
			))
		for _, ErrorMessage in ipairs(Errors) do
			Logger:Warn("  • " .. ErrorMessage)
		end
		return nil
	end

	-- Produce a shallow copy so the builder's _Config remains mutable for
	-- subsequent :Build() calls. Freezing _Config directly would prevent the
	-- builder from being reused.
	local FinalConfig = table.clone(self._Config)
	-- MaterialRestitution needs its own clone so the frozen table's inner
	-- table is not shared with the builder's mutable copy.
	FinalConfig.MaterialRestitution = table.clone(self._Config.MaterialRestitution)

	return table.freeze(FinalConfig)
end

-- ─── Convenience Presets ─────────────────────────────────────────────────────
--[[
    Static preset constructors for common projectile archetypes.
    Each returns a fully configured BehaviorBuilder ready for further
    customisation or immediate :Build(). They demonstrate intended usage
    and serve as starting points for weapon-specific tuning.
]]

--[=[
    BehaviorBuilder.Sniper()
    High-velocity, long-range, pierce-capable. No bouncing.
    Suitable for rifles and anti-materiel weapons.
]=]
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
		:Filter(function(_ctx, _result, _vel)
			return true
		end)
		:Done()
		:HighFidelity()
		:SegmentSize(0.2)
		:FrameBudget(2)
		:Done()
end

--[=[
    BehaviorBuilder.Grenade()
    Low-speed, gravity-affected, bouncy. No piercing.
    Suitable for thrown grenades, bouncing explosives.
]=]
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
		:Filter(function(_ctx, _result, _vel)
			return true
		end)
		:Done()
		:CornerTrap()
		:TimeThreshold(0.005)
		:DisplacementThreshold(0.3)
		:Done()
		:HighFidelity()
		:SegmentSize(0.4)
		:Done()
end

--[=[
    BehaviorBuilder.Pistol()
    Standard short-to-mid range. Single pierce, no bounce.
    Suitable for handguns and SMGs.
]=]
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
		:Filter(function(_ctx, _result, _vel)
			return true
		end)
		:Done()
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(BehaviorBuilder, {
	__index = function(_, Key)
		Logger:Warn(string.format(
			"BehaviorBuilder: attempt to index nil key '%s'", tostring(Key)
			))
	end,
	__newindex = function(_, Key)
		Logger:Error(string.format(
			"BehaviorBuilder: attempt to write to protected key '%s'", tostring(Key)
			))
	end,
})