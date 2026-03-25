--!native
--!optimize 2
--!strict

--[[
    Canonical defaults for every BuiltBehavior field.

    NOTE: RaycastParams and Gravity are intentionally NOT set here.
    BehaviorBuilder.new() allocates a fresh RaycastParams per instance
    and reads workspace.Gravity live at construction time.
    Setting them here would cause shared-reference mutations across builders.
]]

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Parent.Parent.Core.Enums)

type BuiltBehavior = Types.BuiltBehavior

local DEFAULTS: BuiltBehavior = {
    -- Physics (RaycastParams and Gravity are sentinels — overridden in .new())
    Acceleration                 = Vector3.zero,
    MaxDistance                  = 500,
    MaxSpeed                     = math.huge,
    RaycastParams                = RaycastParams.new(),
    Gravity                      = Vector3.zero,
    MinSpeed                     = 1,

    -- Drag
    DragCoefficient              = 0,
    DragModel                    = Enums.DragModel.Quadratic,
    DragSegmentInterval          = 0.05,
    CustomMachTable              = nil,

    -- Wind
    WindResponse                 = 1.0,

    -- Magnus
    SpinVector                   = Vector3.zero,
    MagnusCoefficient            = 0,
    SpinDecayRate                = 0,

    -- Gyroscopic Drift
    GyroDriftRate                = nil,
    GyroDriftAxis                = nil,

    -- Tumble
    TumbleSpeedThreshold         = nil,
    TumbleDragMultiplier         = 3.0,
    TumbleLateralStrength        = 0,
    TumbleOnPierce               = false,
    TumbleRecoverySpeed          = nil,

    -- Homing
    CanHomeFunction              = nil,
    HomingPositionProvider       = nil,
    HomingStrength               = 90,
    HomingMaxDuration            = 3,
    HomingAcquisitionRadius      = 0,

    -- Speed Profiles
    SpeedThresholds              = {},
    SupersonicProfile            = nil,
    SubsonicProfile              = nil,

    -- Trajectory
    TrajectoryPositionProvider   = nil,

    -- Bullet Mass
    BulletMass                   = 0,
    CastFunction                 = nil,

    -- Pierce
    CanPierceFunction            = nil,
    MaxPierceCount               = 3,
    PierceSpeedThreshold         = 50,
    PenetrationSpeedRetention    = 0.8,
    PierceNormalBias             = 1.0,
    PenetrationDepth             = 0,
    PenetrationForce             = 0,
    PenetrationThicknessLimit    = 500,

    -- Fragmentation
    FragmentOnPierce             = false,
    FragmentCount                = 3,
    FragmentDeviation            = 15,

    -- Bounce
    CanBounceFunction            = nil,
    MaxBounces                   = 5,
    BounceSpeedThreshold         = 20,
    Restitution                  = 0.7,
    MaterialRestitution          = {},
    NormalPerturbation           = 0.0,
    ResetPierceOnBounce          = false,

    -- High Fidelity
    HighFidelitySegmentSize      = 0.5,
    HighFidelityFrameBudget      = 4,
    AdaptiveScaleFactor          = 1.5,
    MinSegmentSize               = 0.1,
    MaxBouncesPerFrame           = 10,

    -- Corner Trap
    CornerTimeThreshold          = 0.002,
    CornerPositionHistorySize    = 4,
    CornerDisplacementThreshold  = 0.5,
    CornerEMAAlpha               = 0.4,
    -- Must be > |1 - 2·α| = 0.2 at default alpha 0.4; 0.25 gives a clear margin.
    CornerEMAThreshold           = 0.25,
    -- Bullet must move >= this many studs per bounce. 0 disables Pass 4.
    CornerMinProgressPerBounce   = 0.3,

    -- 6DOF
    SixDOFEnabled                = false,
    LiftCoefficientSlope         = 0,
    PitchingMomentSlope          = 0,
    PitchDampingCoeff            = 0,
    RollDampingCoeff             = 0,
    AoADragFactor                = 0,
    ReferenceArea                = 0,
    ReferenceLength              = 0,
    AirDensity                   = 1.225,
    MomentOfInertia              = 0,
    SpinMOI                      = 0,
    MaxAngularSpeed              = 200 * math.pi,
    InitialOrientation           = nil,
    InitialAngularVelocity       = nil,
    -- 6DOF Mach tables (nil = use flat scalar)
    CLAlphaMachTable             = nil,
    CmAlphaMachTable             = nil,
    CmqMachTable                 = nil,
    ClpMachTable                 = nil,

    -- LOD
    LODDistance                  = 0,

    -- Cosmetic
    CosmeticBulletTemplate       = nil,
    CosmeticBulletContainer      = nil,
    CosmeticBulletProvider       = nil,

    -- Batch Travel
    BatchTravel                  = false,

    -- Debug
    VisualizeCasts               = false,
}

return DEFAULTS