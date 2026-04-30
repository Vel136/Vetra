--!native
--!optimize 2
--!strict

--[[
    Shared type definitions and the DragModel enum for BehaviorBuilder.

    Every sub-builder and the root builder require this module to get the
    BuiltBehavior type, callback aliases, and DragModelEnum.

    IsValidDragModel is also exposed here so Drag.lua and SpeedProfiles.lua
    can both validate against the enum without duplicating the loop.
]]

-- ─── Callback Aliases ────────────────────────────────────────────────────────

export type BulletContext  = any
export type PierceFilter   = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
export type BounceFilter   = (Context: BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
export type HomingFilter   = (Context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean
export type HomingProvider = (pos: Vector3, vel: Vector3) -> Vector3?
export type BulletProvider = (ctx: BulletContext) -> Instance?
export type TrajectoryProvider = (elapsed: number) -> Vector3?

-- ─── SpeedProfile ────────────────────────────────────────────────────────────

export type SpeedProfile = {
    DragCoefficient     : number?,
    DragModel           : DragModel?,
    NormalPerturbation  : number?,
    MaterialRestitution : { [Enum.Material]: number }?,
    Restitution         : number?,
}

-- ─── BuiltBehavior ───────────────────────────────────────────────────────────

export type BuiltBehavior = {
    -- Physics
    Acceleration                 : Vector3,
    MaxDistance                  : number,
    MaxSpeed                     : number,
    RaycastParams                : RaycastParams,
    Gravity                      : Vector3,
    MinSpeed                     : number,
    -- Drag
    DragCoefficient              : number,
    DragModel                    : DragModel,
    DragSegmentInterval          : number,
    CustomMachTable              : { { number } }?,
    -- Wind
    WindResponse                 : number,
    -- Magnus
    SpinVector                   : Vector3,
    MagnusCoefficient            : number,
    SpinDecayRate                : number,
    -- Gyroscopic Drift
    GyroDriftRate                : number?,
    GyroDriftAxis                : Vector3?,
    -- Tumble
    TumbleSpeedThreshold         : number?,
    TumbleDragMultiplier         : number,
    TumbleLateralStrength        : number,
    TumbleOnPierce               : boolean,
    TumbleRecoverySpeed          : number?,
    -- Homing
    CanHomeFunction              : HomingFilter?,
    HomingPositionProvider       : HomingProvider?,
    HomingStrength               : number,
    HomingMaxDuration            : number,
    HomingAcquisitionRadius      : number,
    -- Speed Profiles
    SpeedThresholds              : { number },
    SupersonicProfile            : SpeedProfile?,
    SubsonicProfile              : SpeedProfile?,
    -- Trajectory
    TrajectoryPositionProvider   : TrajectoryProvider?,
    -- Bullet Mass
    BulletMass                   : number,
    CastFunction                 : ((Vector3, Vector3, RaycastParams) -> RaycastResult?)?,
    -- Pierce
    CanPierceFunction            : PierceFilter?,
    MaxPierceCount               : number,
    PierceSpeedThreshold         : number,
    PierceSpeedRetention    : number,
    PierceNormalBias             : number,
    PierceDepth             : number,
    PierceForce             : number,
    PierceThicknessLimit    : number,
    -- Fragmentation
    FragmentOnPierce             : boolean,
    FragmentCount                : number,
    FragmentDeviation            : number,
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
    -- 6DOF
    SixDOFEnabled                : boolean,
    LiftCoefficientSlope         : number,
    PitchingMomentSlope          : number,
    PitchDampingCoeff            : number,
    RollDampingCoeff             : number,
    AoADragFactor                : number,
    ReferenceArea                : number,
    ReferenceLength              : number,
    AirDensity                   : number,
    MomentOfInertia              : number,
    SpinMOI                      : number,
    MaxAngularSpeed              : number,
    InitialOrientation           : CFrame?,
    InitialAngularVelocity       : Vector3?,
    -- 6DOF Mach tables (optional — override flat scalars when set)
    CLAlphaMachTable             : { { number } }?,
    CmAlphaMachTable             : { { number } }?,
    CmqMachTable                 : { { number } }?,
    ClpMachTable                 : { { number } }?,
    -- LOD
    LODDistance                  : number,
    -- Cosmetic
    CosmeticBulletTemplate       : BasePart?,
    CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : BulletProvider?,
	AutoDeleteCosmeticBullet	 : boolean,
    -- Batch Travel
    BatchTravel                  : boolean,
    -- Hitscan
    IsHitscan                    : boolean,
    -- Debug
    VisualizeCasts               : boolean,
}

-- ─── DragModel ───────────────────────────────────────────────────────────────

local Enums = require(script.Parent.Parent.Parent.Core.Enums)
export type DragModel = Enums.DragModel

-- ─── DirtySet ────────────────────────────────────────────────────────────────
--[[
    Tracks which BuiltBehavior fields were explicitly set by the user vs still
    sitting at their defaults. Used by :Impose() to copy only intentional
    changes, preventing a modifier from clobbering fields it never touched.
]]
export type DirtySet = { [string]: boolean }

-- ─── BehaviorBuilder ─────────────────────────────────────────────────────────
-- Full structural type used by sub-builders for Done() return and _Root field.
-- No sub-builder requires are needed here — namespace opener returns are typed
-- as `any` to avoid circular deps, but all other methods are fully typed.
-- init.lua re-exports this as typeof(setmetatable(...)) for consumers.
export type BehaviorBuilder = {
    _Config : BuiltBehavior,
    _Dirty  : DirtySet,

    new           : () -> BehaviorBuilder,
    Physics       : (self: BehaviorBuilder) -> any,
    Homing        : (self: BehaviorBuilder) -> any,
    Pierce        : (self: BehaviorBuilder) -> any,
    Bounce        : (self: BehaviorBuilder) -> any,
    HighFidelity  : (self: BehaviorBuilder) -> any,
    CornerTrap    : (self: BehaviorBuilder) -> any,
    Cosmetic      : (self: BehaviorBuilder) -> any,
    Debug         : (self: BehaviorBuilder) -> any,
    Drag          : (self: BehaviorBuilder) -> any,
    Wind          : (self: BehaviorBuilder) -> any,
    Magnus        : (self: BehaviorBuilder) -> any,
    GyroDrift     : (self: BehaviorBuilder) -> any,
    Tumble        : (self: BehaviorBuilder) -> any,
    Fragmentation : (self: BehaviorBuilder) -> any,
    SpeedProfiles : (self: BehaviorBuilder) -> any,
    Trajectory    : (self: BehaviorBuilder) -> any,
    LOD           : (self: BehaviorBuilder) -> any,
    SixDOF        : (self: BehaviorBuilder) -> any,
    BatchTravel   : (self: BehaviorBuilder, value: boolean) -> BehaviorBuilder,
    Hitscan       : (self: BehaviorBuilder, value: boolean) -> BehaviorBuilder,
    Clone         : (self: BehaviorBuilder) -> BehaviorBuilder,
    Impose        : (self: BehaviorBuilder, other: BehaviorBuilder) -> BehaviorBuilder,
    Build         : (self: BehaviorBuilder) -> BuiltBehavior,
}

-- ─── Module Return ───────────────────────────────────────────────────────────

return {}