--!native
--!optimize 2
--!strict

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    Version: 6.2.2
]]

--[[
    BehaviorBuilder — Fluent typed configuration builder for Vetra.

    Instead of constructing raw behavior tables by hand, chain namespace
    methods and call :Build() to produce a validated, frozen VetraBehavior.

        local Behavior = BehaviorBuilder.new()
            :Physics()
                :MaxDistance(500)
                :MinSpeed(5)
            :Done()
            :Bounce()
                :Max(3)
                :Restitution(0.7)
                :Filter(function(ctx, result, vel)
                    return result.Instance:HasTag("Bouncy")
                end)
            :Done()
            :Drag()
                :Coefficient(0.003)
                :Model(BehaviorBuilder.DragModel.G7)
            :Done()
            :Build()

    Namespace overview:
        :Physics()       → MaxDistance, MaxSpeed, MinSpeed, Gravity, Acceleration,
                           RaycastParams, CastFunction, BulletMass
        :Homing()        → Filter, PositionProvider, Strength, MaxDuration, AcquisitionRadius
        :Pierce()        → Filter, Max, SpeedThreshold, SpeedRetention, NormalBias,
                           PenetrationDepth, PenetrationForce, ThicknessLimit
        :Bounce()        → Filter, Max, SpeedThreshold, Restitution, MaterialRestitution,
                           NormalPerturbation, ResetPierceOnBounce
        :HighFidelity()  → SegmentSize, FrameBudget, AdaptiveScale,
                           MinSegmentSize, MaxBouncesPerFrame
        :CornerTrap()    → TimeThreshold, PositionHistorySize, DisplacementThreshold,
                           EMAAlpha, EMAThreshold, MinProgressPerBounce
        :Cosmetic()      → Template, Container, Provider
        :Debug()         → Visualize
        :Drag()          → Coefficient, Model, SegmentInterval, CustomMachTable
        :Wind()          → Response
        :Magnus()        → SpinVector, Coefficient, SpinDecayRate
        :GyroDrift()     → Rate, Axis
        :Tumble()        → SpeedThreshold, DragMultiplier, LateralStrength,
                           OnPierce, RecoverySpeed
        :Fragmentation() → OnPierce, Count, Deviation
        :SpeedProfiles() → Thresholds, :Supersonic()→ profile, :Subsonic()→ profile
        :Trajectory()    → Provider
        :LOD()           → Distance
        :BatchTravel()   → (root-level boolean toggle, no sub-builder)
        :Clone()         → returns an independent copy of this builder
        :Impose(other)   → copies only the explicitly-set fields from other onto self

    Dirty tracking:
        Every setter marks its field name in _Dirty. :Impose() reads the source
        builder's _Dirty to copy only intentional changes — default-valued fields
        on the source are never copied, so a modifier cannot silently reset fields
        it never touched.

    All sub-builders are in sibling modules under BehaviorBuilder/.
    Types, defaults, and validation each live in their own module too.
    init.lua only wires them together — keep it that way.
]]

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService    = require(Core.Logger)
local Types         = require(script.Types)
local DEFAULTS      = require(script.Defaults)
local ValidateBuilt = require(script.Validation)

-- ─── Sub-Builder Requires ────────────────────────────────────────────────────

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

-- ─── Types ───────────────────────────────────────────────────────────────────

type BuiltBehavior = Types.BuiltBehavior
type DirtySet      = Types.DirtySet

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("BehaviorBuilder", true)

-- ─── Table helpers ───────────────────────────────────────────────────────────

-- Fields whose values are tables that need deep-cloning rather than simple copy.
-- Primitive fields (numbers, booleans, strings, Vector3, functions) copy by value
-- automatically; these are the exceptions.
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
    -- SpeedProfiles are shallow tables of plain values — one level deep is enough.
    if Config.SupersonicProfile then
        Copy.SupersonicProfile = table.clone(Config.SupersonicProfile)
    end
    if Config.SubsonicProfile then
        Copy.SubsonicProfile = table.clone(Config.SubsonicProfile)
    end
    -- Fresh RaycastParams so builders never share a mutable params object.
    -- If the source had no RaycastParams set, preserve nil so Fire() can fall
    -- through to BulletContext.RaycastParams or the default.
    if Config.RaycastParams then
        local Fresh = RaycastParams.new()
        Fresh.FilterDescendantsInstances = Config.RaycastParams.FilterDescendantsInstances
        Fresh.FilterType                 = Config.RaycastParams.FilterType
        Fresh.IgnoreWater                = Config.RaycastParams.IgnoreWater
        Fresh.CollisionGroup             = Config.RaycastParams.CollisionGroup
        Copy.RaycastParams = Fresh
    else
        Copy.RaycastParams = nil
    end
    return Copy
end

-- ─── Root Builder ────────────────────────────────────────────────────────────

local BehaviorBuilder = {}
BehaviorBuilder.__index = BehaviorBuilder

export type BehaviorBuilder = typeof(setmetatable({} :: {
    _Config : BuiltBehavior,
    _Dirty  : DirtySet,
}, BehaviorBuilder))

-- ─── Constructor ─────────────────────────────────────────────────────────────

function BehaviorBuilder.new(): BehaviorBuilder
    -- Deep-copy DEFAULTS so each builder has its own config table.
    -- RaycastParams starts nil — only allocated when the user calls :RaycastParams().
    -- Fire() falls through to BulletContext.RaycastParams or the default if nil.
    -- Gravity is read live from workspace so gravity-zone changes are respected.
    local Config: BuiltBehavior = {
        Acceleration                 = DEFAULTS.Acceleration,
        MaxDistance                  = DEFAULTS.MaxDistance,
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
        PenetrationSpeedRetention    = DEFAULTS.PenetrationSpeedRetention,
        PierceNormalBias             = DEFAULTS.PierceNormalBias,
        PenetrationDepth             = DEFAULTS.PenetrationDepth,
        PenetrationForce             = DEFAULTS.PenetrationForce,
        PenetrationThicknessLimit    = DEFAULTS.PenetrationThicknessLimit,

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

        BatchTravel                  = DEFAULTS.BatchTravel,
        IsHitscan                    = DEFAULTS.IsHitscan,
        VisualizeCasts               = DEFAULTS.VisualizeCasts,
    }

    return setmetatable({ _Config = Config, _Dirty = {} }, BehaviorBuilder)
end

-- ─── Namespace Openers ───────────────────────────────────────────────────────

local function open(self: BehaviorBuilder, Builder: any): any
    return setmetatable({ _Root = self, _Config = self._Config, _Dirty = self._Dirty }, Builder)
end

function BehaviorBuilder.Physics(self: BehaviorBuilder)       return open(self, PhysicsBuilder)       end
function BehaviorBuilder.Homing(self: BehaviorBuilder)        return open(self, HomingBuilder)        end
function BehaviorBuilder.Pierce(self: BehaviorBuilder)        return open(self, PierceBuilder)        end
function BehaviorBuilder.Bounce(self: BehaviorBuilder)        return open(self, BounceBuilder)        end
function BehaviorBuilder.HighFidelity(self: BehaviorBuilder)  return open(self, HighFidelityBuilder)  end
function BehaviorBuilder.CornerTrap(self: BehaviorBuilder)    return open(self, CornerTrapBuilder)    end
function BehaviorBuilder.Cosmetic(self: BehaviorBuilder)      return open(self, CosmeticBuilder)      end
function BehaviorBuilder.Debug(self: BehaviorBuilder)         return open(self, DebugBuilder)         end
function BehaviorBuilder.Drag(self: BehaviorBuilder)          return open(self, DragBuilder)          end
function BehaviorBuilder.Wind(self: BehaviorBuilder)          return open(self, WindBuilder)          end
function BehaviorBuilder.Magnus(self: BehaviorBuilder)        return open(self, MagnusBuilder)        end
function BehaviorBuilder.GyroDrift(self: BehaviorBuilder)     return open(self, GyroDriftBuilder)     end
function BehaviorBuilder.Tumble(self: BehaviorBuilder)        return open(self, TumbleBuilder)        end
function BehaviorBuilder.Fragmentation(self: BehaviorBuilder) return open(self, FragmentationBuilder) end
function BehaviorBuilder.SpeedProfiles(self: BehaviorBuilder) return open(self, SpeedProfilesBuilder) end
function BehaviorBuilder.Trajectory(self: BehaviorBuilder)    return open(self, TrajectoryBuilder)    end
function BehaviorBuilder.LOD(self: BehaviorBuilder)           return open(self, LODBuilder)           end
function BehaviorBuilder.SixDOF(self: BehaviorBuilder)        return open(self, SixDOFBuilder)        end

function BehaviorBuilder.BatchTravel(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
    assert(type(Value) == "boolean", "BehaviorBuilder:BatchTravel — expected boolean")
    self._Config.BatchTravel = Value
    self._Dirty.BatchTravel  = true
    return self
end

function BehaviorBuilder.Hitscan(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
    assert(type(Value) == "boolean", "BehaviorBuilder:Hitscan — expected boolean")
    self._Config.IsHitscan = Value
    self._Dirty.IsHitscan  = true
    return self
end

-- ─── Clone ───────────────────────────────────────────────────────────────────

--[[
    Returns an independent BehaviorBuilder whose _Config and _Dirty are deep
    copies of this builder's. Subsequent changes to either builder do not
    affect the other.

    Use this to produce variants from a shared archetype without mutating it:

        local Base   = BehaviorBuilder.Sniper()
        local Varnt  = Base:Clone():Physics():MaxDistance(2000):Done():Build()
        -- Base is unchanged; only Varnt has MaxDistance = 2000
]]
function BehaviorBuilder.Clone(self: BehaviorBuilder): BehaviorBuilder
    local NewConfig = cloneConfig(self._Config)
    local NewDirty  = table.clone(self._Dirty)
    return setmetatable({ _Config = NewConfig, _Dirty = NewDirty }, BehaviorBuilder)
end

-- ─── Impose ──────────────────────────────────────────────────────────────────

--[[
    Copies only the explicitly-set fields from `other` onto this builder.

    "Explicitly set" means a field that had a setter called on `other` — tracked
    via `other._Dirty`. Fields still sitting at their defaults on `other` are
    never copied, so a modifier cannot silently clobber values it never touched.

    Returns self for chaining. Does not mutate `other`.

        local APMod = BehaviorBuilder.new()
            :Pierce():Max(5):SpeedRetention(0.95):Done()

        -- APMod._Dirty = { MaxPierceCount=true, PenetrationSpeedRetention=true }
        -- All other fields on APMod are defaults and will NOT be copied.

        local APSniper = BehaviorBuilder.Sniper():Clone():Impose(APMod):Build()
        -- Only MaxPierceCount and PenetrationSpeedRetention were written.
        -- MaxDistance(1500), HighFidelitySegmentSize(0.2), etc. are untouched.

    Stacking modifiers works naturally — each Impose only writes its own dirty set:

        local APHollow = BehaviorBuilder.Sniper():Clone()
            :Impose(APMod)
            :Impose(HollowMod)
            :Build()
]]
function BehaviorBuilder.Impose(self: BehaviorBuilder, Other: BehaviorBuilder): BehaviorBuilder
    assert(
        type(Other) == "table" and type(Other._Dirty) == "table" and type(Other._Config) == "table",
        "BehaviorBuilder:Impose — expected a BehaviorBuilder"
    )

    for Field in Other._Dirty do
        if TABLE_FIELDS[Field] then
            -- Deep-clone table values so self and Other never share a reference.
            local SrcValue = (Other._Config :: any)[Field]
            if SrcValue ~= nil then
                (self._Config :: any)[Field] = table.clone(SrcValue)
            else
                (self._Config :: any)[Field] = nil
            end
        else
            (self._Config :: any)[Field] = (Other._Config :: any)[Field]
        end
        -- Propagate dirty so further :Impose() or :Clone() calls include this field.
        self._Dirty[Field] = true
    end

    return self
end

-- ─── Merge ───────────────────────────────────────────────────────────────────

--[[
    Returns a new builder that is a clone of self with all provided modifiers
    applied in order. Neither self nor any modifier is mutated.

    Equivalent to self:Clone():Impose(a):Impose(b):..., but reads more naturally
    when combining a preset base with one or more modifiers at the call site.

        local Behavior = BehaviorBuilder.Sniper()
            :Merge(APMod, HollowMod)
            :Build()
]]
function BehaviorBuilder.Merge(self: BehaviorBuilder, ...: BehaviorBuilder): BehaviorBuilder
    local Result = self:Clone()
    for _, Mod in { ... } do
        Result:Impose(Mod)
    end
    return Result
end

-- ─── Inherit ─────────────────────────────────────────────────────────────────

--[[
    Creates a new builder pre-populated from a frozen VetraBehavior table,
    with every field marked dirty.

    This is the inverse of :Build() — it lets you round-trip a frozen behavior
    back into a mutable builder so you can tweak individual fields without
    reconstructing from scratch.

    Every field is marked dirty so that :Impose() / :Merge() on the resulting
    builder treats all values as intentional rather than default.

        -- Received from a registry, config file, or API
        local existing = BehaviorRegistry:Get("Sniper")

        -- Round-trip: unfreeze → tweak → refreeze
        local tweaked = BehaviorBuilder.Inherit(existing)
            :Physics():MaxDistance(2000):Done()
            :Build()
]]
function BehaviorBuilder.Inherit(Frozen: BuiltBehavior): BehaviorBuilder
    assert(type(Frozen) == "table", "BehaviorBuilder.Inherit — expected a frozen VetraBehavior table")

    -- Copy every field from the frozen table into a fresh config.
    -- cloneConfig handles RaycastParams and table-valued fields correctly.
    local Config = cloneConfig(Frozen :: any)

    -- Mark every field dirty so Impose/Merge treats all values as intentional.
    local Dirty: DirtySet = {}
    for Key in Config :: any do
        Dirty[Key] = true
    end

    return setmetatable({ _Config = Config, _Dirty = Dirty }, BehaviorBuilder)
end

-- ─── When ────────────────────────────────────────────────────────────────────

--[[
    Conditionally applies a block of builder calls without breaking the
    fluent chain. If condition is falsy the builder is returned unchanged.

    The callback receives self and must return nothing — it is called for
    its side effects on the builder, not for a return value.

        local Behavior = BehaviorBuilder.Sniper()
            :When(isRaining,   function(b) b:Wind():Response(1.5):Done() end)
            :When(isHeavyAmmo, function(b) b:Pierce():Max(5):Done() end)
            :When(isDebug,     function(b) b:Debug():Visualize(true):Done() end)
            :Build()
]]
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

-- ─── Build ───────────────────────────────────────────────────────────────────

function BehaviorBuilder.Build(self: BehaviorBuilder): BuiltBehavior?
    local Errors = ValidateBuilt(self._Config)

    if #Errors > 0 then
        Logger:Warn(string.format("BehaviorBuilder:Build — %d validation error(s):", #Errors))
        for _, Msg in ipairs(Errors) do
            Logger:Warn("  • " .. Msg)
        end
        return nil
    end

    local Final = table.clone(self._Config)
    Final.MaterialRestitution = table.clone(self._Config.MaterialRestitution)
    Final.SpeedThresholds     = table.clone(self._Config.SpeedThresholds)

    return table.freeze(Final)
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
            tostring(Key), tostring(Value)
        ))
    end,
}))