--!native
--!optimize 2
--!strict

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    Version: 5.4
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
        :CornerTrap()   → TimeThreshold, PositionHistorySize, DisplacementThreshold,
                          EMAAlpha, EMAThreshold, MinProgressPerBounce
        :Cosmetic()     → Template, Container, Provider
        :Debug()        → Visualize

    Each namespace method returns a sub-builder. Sub-builders expose only the
    fields relevant to that group, preventing cross-group assignments like
    accidentally setting Restitution inside the Pierce group. Calling :Done()
    on a sub-builder returns the root BehaviorBuilder.
]]

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local t          = require(Core.TypeCheck)
local Constants  = require(Core.Constants)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local IDENTITY = "BehaviorBuilder"
local Logger   = LogService.new(IDENTITY, true)

-- ─── Type Definitions ────────────────────────────────────────────────────────

-- Mirror of VetraBehavior from Vetra for self-contained typing.
-- These are all optional at the builder level — :Build() merges with defaults.
type BulletContext  = any
type PierceFilter   = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
type BounceFilter   = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
type BulletProvider = (ctx: any) -> Instance?

type HomingFilter   = (Context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean

type BuiltBehavior = {
	-- Physics
	Acceleration                 : Vector3,
	MaxDistance                  : number,
	MaxSpeed                     : number,
	RaycastParams                : RaycastParams,
	Gravity                      : Vector3,
	MinSpeed                     : number,
	-- Homing
	CanHomeFunction              : HomingFilter?,
	-- Bullet Mass
	BulletMass                   : number,
	-- Pierce
	CanPierceFunction            : PierceFilter?,
	MaxPierceCount               : number,
	PierceSpeedThreshold         : number,
	PenetrationSpeedRetention    : number,
	PierceNormalBias             : number,
	PenetrationDepth             : number,
	PenetrationForce             : number,
	PenetrationThicknessLimit    : number,
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
	CornerPositionHistorySize    : number,
	CornerDisplacementThreshold  : number,
	CornerEMAAlpha               : number,
	CornerEMAThreshold           : number,
	CornerMinProgressPerBounce   : number,
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
-- NOTE: RaycastParams is intentionally NOT a module-level singleton here.
-- A single RaycastParams.new() at module load would be shared across all
-- builders — configuring it in one builder would silently mutate every other.
-- BehaviorBuilder.new() allocates a fresh instance per builder.
-- Gravity is likewise NOT baked here; workspace.Gravity is a runtime value
-- that can change (gravity zones, etc.). It is read in BehaviorBuilder.new().
local DEFAULTS: BuiltBehavior = {
	Acceleration                 = Vector3.zero,
	MaxDistance                  = 500,
	MaxSpeed                     = math.huge,  -- no cap; override via :Physics():MaxSpeed(n):Done()
	RaycastParams                = RaycastParams.new(), -- sentinel; overridden per-instance
	Gravity                      = Vector3.zero,        -- sentinel; overridden per-instance
	MinSpeed                     = 1,

	CanHomeFunction              = nil,
	BulletMass                   = 0,

	CastFunction                 = nil,  -- nil = use default workspace:Raycast

	CanPierceFunction            = nil,
	MaxPierceCount               = 3,
	PierceSpeedThreshold         = 50,
	PenetrationSpeedRetention    = 0.8,
	PierceNormalBias             = 1.0,
	PenetrationDepth             = 0,
	PenetrationForce             = 0,
	PenetrationThicknessLimit    = 500,

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
	CornerPositionHistorySize    = 4,
	CornerDisplacementThreshold  = 0.5,
	CornerEMAAlpha               = 0.4,
	-- Must exceed |1 - 2·α| = |1 - 0.8| = 0.2 or the canonical 2-wall trap is
	-- undetectable at the second bounce. 0.25 gives a clear margin above that.
	CornerEMAThreshold           = 0.25,
	-- Pass 4: bullet must move at least this many studs per bounce from its
	-- first contact position. 0.3 is conservative enough to avoid false positives
	-- on legitimate tight-space ricochets while catching slow-drift traps.
	CornerMinProgressPerBounce   = 0.3,

	CosmeticBulletTemplate       = nil,
	CosmeticBulletContainer      = nil,
	CosmeticBulletProvider       = nil,

	ResetPierceOnBounce          = false,
	VisualizeCasts               = false,
}

-- ─── Validation Helpers ──────────────────────────────────────────────────────

--[[
    These run during :Build() rather than per-setter call. Deferring validation
    to build time means the builder never throws mid-chain, making it easier to
    construct behaviors conditionally without try/catch gymnastics.
    Returns a list of error strings so all problems are reported at once.
]]
local function ValidateBuilt(BuiltConfig: BuiltBehavior): { string }
	local Errors = {}

	local function Expect(Condition: boolean, Message: string)
		if not Condition then
			Errors[#Errors + 1] = Message
		end
	end

	-- Physics
	Expect(BuiltConfig.MaxDistance > 0,  "MaxDistance must be > 0")
	Expect(BuiltConfig.MinSpeed   >= 0,  "MinSpeed must be >= 0")
	Expect(BuiltConfig.MaxSpeed   >  0,  "MaxSpeed must be > 0")
	Expect(BuiltConfig.MaxSpeed   >= BuiltConfig.MinSpeed,"MaxSpeed must be >= MinSpeed")

	-- Pierce
	Expect(BuiltConfig.MaxPierceCount           >= 0, "MaxPierceCount must be >= 0")
	Expect(BuiltConfig.PierceSpeedThreshold     >= 0, "PierceSpeedThreshold must be >= 0")
	Expect(BuiltConfig.PenetrationSpeedRetention >= 0 and BuiltConfig.PenetrationSpeedRetention <= 1,
		"PenetrationSpeedRetention must be in [0, 1]")
	Expect(BuiltConfig.PierceNormalBias >= 0 and BuiltConfig.PierceNormalBias <= 1,
		"PierceNormalBias must be in [0, 1]")

	-- Bounce
	Expect(BuiltConfig.MaxBounces              >= 0, "MaxBounces must be >= 0")
	Expect(BuiltConfig.BounceSpeedThreshold    >= 0, "BounceSpeedThreshold must be >= 0")
	Expect(BuiltConfig.Restitution             >= 0 and BuiltConfig.Restitution <= 1,
		"Restitution must be in [0, 1]")
	Expect(BuiltConfig.NormalPerturbation      >= 0, "NormalPerturbation must be >= 0")

	-- High Fidelity
	Expect(BuiltConfig.HighFidelitySegmentSize > 0,  "HighFidelitySegmentSize must be > 0")
	Expect(BuiltConfig.HighFidelityFrameBudget > 0,  "HighFidelityFrameBudget must be > 0")
	Expect(BuiltConfig.AdaptiveScaleFactor     > 1,  "AdaptiveScaleFactor must be > 1")
	Expect(BuiltConfig.MinSegmentSize          > 0,  "MinSegmentSize must be > 0")
	Expect(BuiltConfig.MaxBouncesPerFrame      >= 1, "MaxBouncesPerFrame must be >= 1")
	Expect(BuiltConfig.MinSegmentSize <= BuiltConfig.HighFidelitySegmentSize,"MinSegmentSize must be <= HighFidelitySegmentSize")

	-- Corner Trap
	Expect(BuiltConfig.CornerTimeThreshold         >= 0,   "CornerTimeThreshold must be >= 0")
	Expect(BuiltConfig.CornerPositionHistorySize   >= 1 and math.floor(BuiltConfig.CornerPositionHistorySize) == BuiltConfig.CornerPositionHistorySize,"CornerPositionHistorySize must be a positive integer")
	Expect(BuiltConfig.CornerDisplacementThreshold >= 0,   "CornerDisplacementThreshold must be >= 0")
	Expect(BuiltConfig.CornerEMAAlpha > 0 and BuiltConfig.CornerEMAAlpha < 1,"CornerEMAAlpha must be in (0, 1)")
	Expect(BuiltConfig.CornerEMAThreshold > math.abs(1 - 2 * BuiltConfig.CornerEMAAlpha),"CornerEMAThreshold must be > |1 - 2·CornerEMAAlpha| or the 2-wall trap is undetectable")
	Expect(BuiltConfig.CornerMinProgressPerBounce >= 0,"CornerMinProgressPerBounce must be >= 0 (set to 0 to disable Pass 4)")

	-- Cosmetic
	if BuiltConfig.CosmeticBulletProvider ~= nil and BuiltConfig.CosmeticBulletTemplate ~= nil then
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

function PhysicsBuilder.MaxDistance(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:MaxDistance — expected number")
	self._Config.MaxDistance = Value
	return self
end

function PhysicsBuilder.MinSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:MinSpeed — expected number")
	self._Config.MinSpeed = Value
	return self
end

function PhysicsBuilder.MaxSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:MaxSpeed — expected number")
	self._Config.MaxSpeed = Value
	return self
end

function PhysicsBuilder.Gravity(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
	assert(t.Vector3(Value), "PhysicsBuilder:Gravity — expected Vector3")
	self._Config.Gravity = Value
	return self
end

function PhysicsBuilder.Acceleration(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
	assert(t.Vector3(Value), "PhysicsBuilder:Acceleration — expected Vector3")
	self._Config.Acceleration = Value
	return self
end

function PhysicsBuilder.RaycastParams(self: PhysicsBuilder, Value: RaycastParams): PhysicsBuilder
	assert(typeof(Value) == "RaycastParams", "PhysicsBuilder:RaycastParams — expected RaycastParams")
	self._Config.RaycastParams = Value
	return self
end

-- Optional custom cast function. Replaces workspace:Raycast for every intersection
-- test this behavior performs. Use for Spherecast, Blockcast, or any custom test.
-- fn(origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?
-- direction is the raw displacement vector (not a unit vector).
function PhysicsBuilder.CastFunction(self: PhysicsBuilder, Value: (Vector3, Vector3, RaycastParams) -> RaycastResult?): PhysicsBuilder
	assert(type(Value) == "function", "PhysicsBuilder:CastFunction — expected function")
	self._Config.CastFunction = Value
	return self
end

function PhysicsBuilder.BulletMass(self: PhysicsBuilder, Value: number): PhysicsBuilder
	assert(t.number(Value), "PhysicsBuilder:BulletMass — expected number")
	self._Config.BulletMass = Value
	return self
end

function PhysicsBuilder.Done(self: PhysicsBuilder): any
	return self._Root
end

-- ── Homing Sub-Builder ───────────────────────────────────────────────────────

local HomingBuilder = {}
HomingBuilder.__index = HomingBuilder

export type HomingBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, HomingBuilder))

function HomingBuilder.Filter(self: HomingBuilder, Callback: HomingFilter): HomingBuilder
	assert(type(Callback) == "function", "HomingBuilder:Filter — expected function")
	self._Config.CanHomeFunction = Callback
	return self
end

function HomingBuilder.Done(self: HomingBuilder): any
	return self._Root
end

-- ── Pierce Sub-Builder ───────────────────────────────────────────────────────

local PierceBuilder = {}
PierceBuilder.__index = PierceBuilder

export type PierceBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, PierceBuilder))

function PierceBuilder.Filter(self: PierceBuilder, Callback: PierceFilter): PierceBuilder
	assert(type(Callback) == "function", "PierceBuilder:Filter — expected function")
	self._Config.CanPierceFunction = Callback
	return self
end

function PierceBuilder.Max(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:Max — expected number")
	self._Config.MaxPierceCount = Value
	return self
end

function PierceBuilder.SpeedThreshold(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:SpeedThreshold — expected number")
	self._Config.PierceSpeedThreshold = Value
	return self
end

function PierceBuilder.SpeedRetention(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:SpeedRetention — expected number")
	self._Config.PenetrationSpeedRetention = Value
	return self
end

function PierceBuilder.NormalBias(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:NormalBias — expected number")
	self._Config.PierceNormalBias = Value
	return self
end

function PierceBuilder.PenetrationDepth(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:PenetrationDepth — expected number")
	self._Config.PenetrationDepth = Value
	return self
end

function PierceBuilder.PenetrationForce(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value), "PierceBuilder:PenetrationForce — expected number")
	self._Config.PenetrationForce = Value
	return self
end

function PierceBuilder.ThicknessLimit(self: PierceBuilder, Value: number): PierceBuilder
	assert(t.number(Value) and Value > 0, "PierceBuilder:ThicknessLimit — expected number > 0")
	self._Config.PenetrationThicknessLimit = Value
	return self
end

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

function BounceBuilder.ResetPierceOnBounce(self: BounceBuilder, Value: boolean): BounceBuilder
	assert(type(Value) == "boolean", "BounceBuilder:ResetPierceOnBounce — expected boolean")
	self._Config.ResetPierceOnBounce = Value
	return self
end

function BounceBuilder.Filter(self: BounceBuilder, Callback: BounceFilter): BounceBuilder
	assert(type(Callback) == "function", "BounceBuilder:Filter — expected function")
	self._Config.CanBounceFunction = Callback
	return self
end

function BounceBuilder.Max(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:Max — expected number")
	self._Config.MaxBounces = Value
	return self
end

function BounceBuilder.SpeedThreshold(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:SpeedThreshold — expected number")
	self._Config.BounceSpeedThreshold = Value
	return self
end

function BounceBuilder.Restitution(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:Restitution — expected number")
	self._Config.Restitution = Value
	return self
end

function BounceBuilder.MaterialRestitution(
	self: BounceBuilder,
	Value: { [Enum.Material]: number }
): BounceBuilder
	assert(type(Value) == "table", "BounceBuilder:MaterialRestitution — expected table")
	self._Config.MaterialRestitution = Value
	return self
end

function BounceBuilder.NormalPerturbation(self: BounceBuilder, Value: number): BounceBuilder
	assert(t.number(Value), "BounceBuilder:NormalPerturbation — expected number")
	self._Config.NormalPerturbation = Value
	return self
end

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

function HighFidelityBuilder.SegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:SegmentSize — expected number")
	self._Config.HighFidelitySegmentSize = Value
	return self
end

function HighFidelityBuilder.FrameBudget(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:FrameBudget — expected number")
	self._Config.HighFidelityFrameBudget = Value
	return self
end

function HighFidelityBuilder.AdaptiveScale(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:AdaptiveScale — expected number")
	self._Config.AdaptiveScaleFactor = Value
	return self
end

function HighFidelityBuilder.MinSegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:MinSegmentSize — expected number")
	self._Config.MinSegmentSize = Value
	return self
end

function HighFidelityBuilder.MaxBouncesPerFrame(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
	assert(t.number(Value), "HighFidelityBuilder:MaxBouncesPerFrame — expected number")
	self._Config.MaxBouncesPerFrame = Value
	return self
end

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

function CornerTrapBuilder.TimeThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:TimeThreshold — expected number")
	self._Config.CornerTimeThreshold = Value
	return self
end

function CornerTrapBuilder.PositionHistorySize(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:PositionHistorySize — expected number")
	self._Config.CornerPositionHistorySize = Value
	return self
end

function CornerTrapBuilder.DisplacementThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:DisplacementThreshold — expected number")
	self._Config.CornerDisplacementThreshold = Value
	return self
end

function CornerTrapBuilder.EMAAlpha(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:EMAAlpha — expected number")
	self._Config.CornerEMAAlpha = Value
	return self
end

function CornerTrapBuilder.EMAThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:EMAThreshold — expected number")
	self._Config.CornerEMAThreshold = Value
	return self
end

function CornerTrapBuilder.MinProgressPerBounce(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
	assert(t.number(Value), "CornerTrapBuilder:MinProgressPerBounce — expected number >= 0")
	self._Config.CornerMinProgressPerBounce = Value
	return self
end

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

function CosmeticBuilder.Template(self: CosmeticBuilder, Value: BasePart): CosmeticBuilder
	assert(typeof(Value) == "Instance" and Value:IsA("BasePart"),
		"CosmeticBuilder:Template — expected BasePart")
	self._Config.CosmeticBulletTemplate = Value
	return self
end

function CosmeticBuilder.Container(self: CosmeticBuilder, Value: Instance): CosmeticBuilder
	assert(typeof(Value) == "Instance", "CosmeticBuilder:Container — expected Instance")
	self._Config.CosmeticBulletContainer = Value
	return self
end

function CosmeticBuilder.Provider(self: CosmeticBuilder, Callback: BulletProvider): CosmeticBuilder
	assert(type(Callback) == "function", "CosmeticBuilder:Provider — expected function")
	self._Config.CosmeticBulletProvider = Callback
	return self
end

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

function DebugBuilder.Visualize(self: DebugBuilder, Value: boolean): DebugBuilder
	assert(type(Value) == "boolean", "DebugBuilder:Visualize — expected boolean")
	self._Config.VisualizeCasts = Value
	return self
end

function DebugBuilder.Done(self: DebugBuilder): any
	return self._Root
end

-- ─── Root Builder ────────────────────────────────────────────────────────────

local BehaviorBuilder = {}
BehaviorBuilder.__index = BehaviorBuilder

export type BehaviorBuilder = typeof(setmetatable({} :: {
	_Config : BuiltBehavior,
}, BehaviorBuilder))

function BehaviorBuilder.new(): BehaviorBuilder
	-- Deep-copy DEFAULTS so each builder instance has its own config table.
	-- Shallow copy would mean all builders share the same MaterialRestitution
	-- and RaycastParams references, causing cross-instance mutations.
	-- RaycastParams is allocated fresh here (not from DEFAULTS) so no two
	-- builders ever share the same RaycastParams object.
	-- Gravity is read from workspace at construction time so that runtime
	-- gravity changes (gravity zones, zero-G, etc.) are respected.
	local BuilderConfig: BuiltBehavior = {
		Acceleration                 = DEFAULTS.Acceleration,
		MaxDistance                  = DEFAULTS.MaxDistance,
		MaxSpeed                     = DEFAULTS.MaxSpeed,
		RaycastParams                = RaycastParams.new(),                   -- fresh per builder
		Gravity                      = Vector3.new(0, -workspace.Gravity, 0), -- live read
		MinSpeed                     = DEFAULTS.MinSpeed,

		CanHomeFunction              = DEFAULTS.CanHomeFunction,
		BulletMass                   = DEFAULTS.BulletMass,

		CanPierceFunction            = DEFAULTS.CanPierceFunction,
		MaxPierceCount               = DEFAULTS.MaxPierceCount,
		PierceSpeedThreshold         = DEFAULTS.PierceSpeedThreshold,
		PenetrationSpeedRetention    = DEFAULTS.PenetrationSpeedRetention,
		PierceNormalBias             = DEFAULTS.PierceNormalBias,
		PenetrationDepth             = DEFAULTS.PenetrationDepth,
		PenetrationForce             = DEFAULTS.PenetrationForce,
		PenetrationThicknessLimit    = DEFAULTS.PenetrationThicknessLimit,

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
		ResetPierceOnBounce          = DEFAULTS.ResetPierceOnBounce,
		CornerTimeThreshold          = DEFAULTS.CornerTimeThreshold,
		CornerPositionHistorySize    = DEFAULTS.CornerPositionHistorySize,
		CornerDisplacementThreshold  = DEFAULTS.CornerDisplacementThreshold,
		CornerEMAAlpha               = DEFAULTS.CornerEMAAlpha,
		CornerEMAThreshold           = DEFAULTS.CornerEMAThreshold,
		CornerMinProgressPerBounce   = DEFAULTS.CornerMinProgressPerBounce,

		CosmeticBulletTemplate       = DEFAULTS.CosmeticBulletTemplate,
		CosmeticBulletContainer      = DEFAULTS.CosmeticBulletContainer,
		CosmeticBulletProvider       = DEFAULTS.CosmeticBulletProvider,

		VisualizeCasts               = DEFAULTS.VisualizeCasts,
	}

	return setmetatable({ _Config = BuilderConfig }, BehaviorBuilder)
end

-- ─── Namespace Openers ───────────────────────────────────────────────────────

function BehaviorBuilder.Physics(self: BehaviorBuilder): PhysicsBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, PhysicsBuilder)
end

function BehaviorBuilder.Pierce(self: BehaviorBuilder): PierceBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, PierceBuilder)
end

function BehaviorBuilder.Homing(self: BehaviorBuilder): HomingBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, HomingBuilder)
end

function BehaviorBuilder.Bounce(self: BehaviorBuilder): BounceBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, BounceBuilder)
end

function BehaviorBuilder.HighFidelity(self: BehaviorBuilder): HighFidelityBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, HighFidelityBuilder)
end

function BehaviorBuilder.CornerTrap(self: BehaviorBuilder): CornerTrapBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, CornerTrapBuilder)
end

function BehaviorBuilder.Cosmetic(self: BehaviorBuilder): CosmeticBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, CosmeticBuilder)
end

function BehaviorBuilder.Debug(self: BehaviorBuilder): DebugBuilder
	return setmetatable({ _Root = self, _Config = self._Config }, DebugBuilder)
end

-- ─── Build ───────────────────────────────────────────────────────────────────

function BehaviorBuilder.Build(self: BehaviorBuilder): BuiltBehavior?
	local ValidationErrors = ValidateBuilt(self._Config)

	if #ValidationErrors > 0 then
		Logger:Warn(string.format(
			"BehaviorBuilder:Build — %d validation error(s):",
			#ValidationErrors
			))
		for _, ErrorMessage in ipairs(ValidationErrors) do
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

return table.freeze(setmetatable(BehaviorBuilder, {
	__index = function(_, Key)
		Logger:Warn(string.format(
			"BehaviorBuilder: attempt to index nil key '%s'", tostring(Key)
			))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"BehaviorBuilder: attempt to write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
}))