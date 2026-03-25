--!native
--!optimize 2
--!strict

--[[
    Build-time validation for BehaviorBuilder.

    All checks are deferred to :Build() — the builder never throws mid-chain.
    Every error is collected and reported together so every problem surfaces
    in a single pass rather than requiring repeated build attempts.
]]

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Parent.Parent.Core.Enums)

type BuiltBehavior = Types.BuiltBehavior

local function IsValidDragModel(Value: any): boolean
    if type(Value) ~= "number" then return false end
    for _, v in Enums.DragModel do
        if v == Value then return true end
    end
    return false
end

local function ValidateBuilt(Config: BuiltBehavior): { string }
    local Errors = {}

    local function Expect(Condition: boolean, Message: string)
        if not Condition then
            Errors[#Errors + 1] = Message
        end
    end

    -- Physics
    Expect(Config.MaxDistance > 0,   "MaxDistance must be > 0")
    Expect(Config.MinSpeed   >= 0,   "MinSpeed must be >= 0")
    Expect(Config.MaxSpeed   >  0,   "MaxSpeed must be > 0")
    Expect(Config.MaxSpeed   >= Config.MinSpeed, "MaxSpeed must be >= MinSpeed")

    -- Drag
    Expect(Config.DragCoefficient >= 0, "DragCoefficient must be >= 0")
    Expect(IsValidDragModel(Config.DragModel),
        "DragModel must be a BehaviorBuilder.DragModel enum value")
    Expect(Config.DragSegmentInterval > 0, "DragSegmentInterval must be > 0")
    if Config.DragModel == "Custom" then
        Expect(Config.CustomMachTable ~= nil,
            "CustomMachTable is required when DragModel = BehaviorBuilder.DragModel.Custom")
    end

    -- Wind
    Expect(Config.WindResponse >= 0, "WindResponse must be >= 0")

    -- Magnus
    Expect(Config.MagnusCoefficient >= 0, "MagnusCoefficient must be >= 0")
    Expect(Config.SpinDecayRate     >= 0, "SpinDecayRate must be >= 0")

    -- Gyroscopic Drift
    if Config.GyroDriftRate ~= nil then
        Expect(Config.GyroDriftRate >= 0, "GyroDriftRate must be >= 0")
    end

    -- Tumble
    if Config.TumbleSpeedThreshold ~= nil then
        Expect(Config.TumbleSpeedThreshold >= 0, "TumbleSpeedThreshold must be >= 0")
    end
    Expect(Config.TumbleDragMultiplier  >= 1, "TumbleDragMultiplier must be >= 1")
    Expect(Config.TumbleLateralStrength >= 0, "TumbleLateralStrength must be >= 0")
    if Config.TumbleRecoverySpeed ~= nil then
        Expect(Config.TumbleRecoverySpeed >= 0, "TumbleRecoverySpeed must be >= 0")
        if Config.TumbleSpeedThreshold ~= nil then
            Expect(Config.TumbleRecoverySpeed > Config.TumbleSpeedThreshold,
                "TumbleRecoverySpeed must be > TumbleSpeedThreshold to prevent re-entry loop")
        end
    end

    -- Homing
    Expect(Config.HomingStrength           > 0,  "HomingStrength must be > 0")
    Expect(Config.HomingMaxDuration        > 0,  "HomingMaxDuration must be > 0")
    Expect(Config.HomingAcquisitionRadius >= 0,  "HomingAcquisitionRadius must be >= 0")

    -- Speed Profiles
    Expect(type(Config.SpeedThresholds) == "table", "SpeedThresholds must be a table")

    -- Pierce
    Expect(Config.MaxPierceCount            >= 0, "MaxPierceCount must be >= 0")
    Expect(Config.PierceSpeedThreshold      >= 0, "PierceSpeedThreshold must be >= 0")
    Expect(Config.PenetrationSpeedRetention >= 0 and Config.PenetrationSpeedRetention <= 1,
        "PenetrationSpeedRetention must be in [0, 1]")
    Expect(Config.PierceNormalBias >= 0 and Config.PierceNormalBias <= 1,
        "PierceNormalBias must be in [0, 1]")

    -- Fragmentation
    Expect(Config.FragmentCount    >= 1,  "FragmentCount must be >= 1")
    Expect(Config.FragmentDeviation >= 0 and Config.FragmentDeviation <= 180,
        "FragmentDeviation must be in [0, 180]")

    -- Bounce
    Expect(Config.MaxBounces           >= 0, "MaxBounces must be >= 0")
    Expect(Config.BounceSpeedThreshold >= 0, "BounceSpeedThreshold must be >= 0")
    Expect(Config.Restitution >= 0 and Config.Restitution <= 1,
        "Restitution must be in [0, 1]")
    Expect(Config.NormalPerturbation >= 0, "NormalPerturbation must be >= 0")

    -- High Fidelity
    Expect(Config.HighFidelitySegmentSize > 0,  "HighFidelitySegmentSize must be > 0")
    Expect(Config.HighFidelityFrameBudget > 0,  "HighFidelityFrameBudget must be > 0")
    Expect(Config.AdaptiveScaleFactor     > 1,  "AdaptiveScaleFactor must be > 1")
    Expect(Config.MinSegmentSize          > 0,  "MinSegmentSize must be > 0")
    Expect(Config.MaxBouncesPerFrame      >= 1, "MaxBouncesPerFrame must be >= 1")
    Expect(Config.MinSegmentSize <= Config.HighFidelitySegmentSize,
        "MinSegmentSize must be <= HighFidelitySegmentSize")

    -- Corner Trap
    Expect(Config.CornerTimeThreshold >= 0, "CornerTimeThreshold must be >= 0")
    Expect(
        Config.CornerPositionHistorySize >= 1
        and math.floor(Config.CornerPositionHistorySize) == Config.CornerPositionHistorySize,
        "CornerPositionHistorySize must be a positive integer"
    )
    Expect(Config.CornerDisplacementThreshold >= 0, "CornerDisplacementThreshold must be >= 0")
    Expect(Config.CornerEMAAlpha > 0 and Config.CornerEMAAlpha < 1,
        "CornerEMAAlpha must be in (0, 1)")
    Expect(
        Config.CornerEMAThreshold > math.abs(1 - 2 * Config.CornerEMAAlpha),
        "CornerEMAThreshold must be > |1 - 2·CornerEMAAlpha| or the 2-wall trap is undetectable"
    )
    Expect(Config.CornerMinProgressPerBounce >= 0,
        "CornerMinProgressPerBounce must be >= 0 (set to 0 to disable Pass 4)")

    -- 6DOF
    if Config.SixDOFEnabled then
        Expect(Config.LiftCoefficientSlope >= 0,   "LiftCoefficientSlope must be >= 0")
        Expect(Config.ReferenceArea        >  0,   "ReferenceArea must be > 0 when SixDOF is enabled")
        Expect(Config.ReferenceLength      >  0,   "ReferenceLength must be > 0 when SixDOF is enabled")
        Expect(Config.AirDensity           >  0,   "AirDensity must be > 0")
        Expect(Config.MomentOfInertia      >  0,   "MomentOfInertia must be > 0 when SixDOF is enabled")
        Expect(Config.SpinMOI              >= 0,   "SpinMOI must be >= 0")
        Expect(Config.MaxAngularSpeed      >  0,   "MaxAngularSpeed must be > 0")
        Expect(Config.AoADragFactor        >= 0,   "AoADragFactor must be >= 0")
        Expect(Config.PitchDampingCoeff    >= 0,   "PitchDampingCoeff must be >= 0")
        Expect(Config.RollDampingCoeff     >= 0,   "RollDampingCoeff must be >= 0")
        Expect(Config.BulletMass           >  0,
            "BulletMass must be > 0 when SixDOF is enabled (required for force→acceleration)")
    end

    -- LOD
    Expect(Config.LODDistance >= 0, "LODDistance must be >= 0")

    -- Cosmetic
    if Config.CosmeticBulletProvider ~= nil and Config.CosmeticBulletTemplate ~= nil then
        Errors[#Errors + 1] =
            "CosmeticBulletProvider and CosmeticBulletTemplate are mutually exclusive — Provider takes priority"
    end

    return Errors
end

return ValidateBuilt