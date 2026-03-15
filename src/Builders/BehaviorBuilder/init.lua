--!native
--!optimize 2
--!strict

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    Version: 5.5
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

    All sub-builders are in sibling modules under BehaviorBuilder/.
    Types, defaults, and validation each live in their own module too.
    init.lua only wires them together — keep it that way.
]]

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService  = require(Core.Logger)
local Types       = require(script.Types)
local DEFAULTS    = require(script.Defaults)
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

local SpeedProfilesBuilder = SpeedProfilesModule.SpeedProfilesBuilder

-- ─── Types ───────────────────────────────────────────────────────────────────

type BuiltBehavior = Types.BuiltBehavior

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("BehaviorBuilder", true)

-- ─── Root Builder ────────────────────────────────────────────────────────────

local BehaviorBuilder = {}
BehaviorBuilder.__index = BehaviorBuilder

export type BehaviorBuilder = typeof(setmetatable({} :: {
    _Config : BuiltBehavior,
}, BehaviorBuilder))

-- ─── Constructor ─────────────────────────────────────────────────────────────

function BehaviorBuilder.new(): BehaviorBuilder
    -- Deep-copy DEFAULTS so each builder has its own config table.
    -- RaycastParams is allocated fresh (never shared across builders).
    -- Gravity is read live from workspace so gravity-zone changes are respected.
    local Config: BuiltBehavior = {
        Acceleration                 = DEFAULTS.Acceleration,
        MaxDistance                  = DEFAULTS.MaxDistance,
        MaxSpeed                     = DEFAULTS.MaxSpeed,
        RaycastParams                = RaycastParams.new(),
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

        SpeedThresholds              = {},  -- fresh per builder
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
        MaterialRestitution          = {},  -- fresh per builder
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

        CosmeticBulletTemplate       = DEFAULTS.CosmeticBulletTemplate,
        CosmeticBulletContainer      = DEFAULTS.CosmeticBulletContainer,
        CosmeticBulletProvider       = DEFAULTS.CosmeticBulletProvider,

        BatchTravel                  = DEFAULTS.BatchTravel,
        VisualizeCasts               = DEFAULTS.VisualizeCasts,
    }

    return setmetatable({ _Config = Config }, BehaviorBuilder)
end

-- ─── Namespace Openers ───────────────────────────────────────────────────────

local function open(self: BehaviorBuilder, Builder: any): any
    return setmetatable({ _Root = self, _Config = self._Config }, Builder)
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

-- BatchTravel is a single boolean toggle — no sub-builder needed.
function BehaviorBuilder.BatchTravel(self: BehaviorBuilder, Value: boolean): BehaviorBuilder
    assert(type(Value) == "boolean", "BehaviorBuilder:BatchTravel — expected boolean")
    self._Config.BatchTravel = Value
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

    -- Shallow-clone so the builder's _Config stays mutable for reuse.
    -- Tables with mutable inner state get their own clone.
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

-- ─── Enum Exposure ───────────────────────────────────────────────────────────
-- Expose DragModelEnum as BehaviorBuilder.DragModel so consumers write
-- BehaviorBuilder.DragModel.G7 instead of the raw string "G7".

BehaviorBuilder.DragModel = Types.DragModelEnum

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
