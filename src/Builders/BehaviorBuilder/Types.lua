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
    PenetrationSpeedRetention    : number,
    PierceNormalBias             : number,
    PenetrationDepth             : number,
    PenetrationForce             : number,
    PenetrationThicknessLimit    : number,
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
    -- Batch Travel
    BatchTravel                  : boolean,
    -- Debug
    VisualizeCasts               : boolean,
}

-- ─── DirtySet ────────────────────────────────────────────────────────────────
--[[
    Tracks which BuiltBehavior fields were explicitly set by the user vs still
    sitting at their defaults. Used by :Impose() to copy only intentional
    changes, preventing a modifier from clobbering fields it never touched.
]]
export type DirtySet = { [string]: boolean }

-- ─── Module Return ───────────────────────────────────────────────────────────

return {}