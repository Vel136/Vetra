--!strict
--!optimize 2
--!native


local Core         = script.Parent.Core
local Dependencies = script.Parent.Dependencies

local VeSignal      = require(Dependencies.Signal)
local BulletContext = require(Core.BulletContext)
local Enums         = require(Core.Enums)

type Signal<T>           = VeSignal.Signal<T>
type BulletContextPublic = BulletContext.BulletContext

export type DragModel        = Enums.DragModel
export type TerminateReason  = Enums.TerminateReason

-- ============================================================================
-- ============================================================================

export type Cast = {
	Alive     : boolean,
	Paused    : boolean,
	StartTime : number,
	Id        : number,
	UserData  : { [any]: any },

	GetPosition         : (self: Cast) -> Vector3,
	GetVelocity         : (self: Cast) -> Vector3,
	GetAcceleration     : (self: Cast) -> Vector3,
	Pause               : (self: Cast) -> (),
	Resume              : (self: Cast) -> (),
	IsPaused            : (self: Cast) -> boolean,
	SuspendFrame        : (self: Cast, frames: number) -> (),
	SuspendTime         : (self: Cast, seconds: number) -> (),
	ClearSuspend        : (self: Cast) -> (),
	IsSuspended         : (self: Cast) -> boolean,
	Terminate           : (self: Cast) -> (),
	SetPosition         : (self: Cast, pos: Vector3) -> (),
	SetVelocity         : (self: Cast, vel: Vector3) -> (),
	SetAcceleration     : (self: Cast, acc: Vector3) -> (),
	AddPosition         : (self: Cast, delta: Vector3) -> (),
	AddVelocity         : (self: Cast, delta: Vector3) -> (),
	AddAcceleration     : (self: Cast, delta: Vector3) -> (),
	ResetBounceState    : (self: Cast) -> (),
	ResetPierceState    : (self: Cast) -> (),
	GetOrientation      : (self: Cast) -> CFrame,
	GetAngularVelocity  : (self: Cast) -> Vector3,
	GetAngleOfAttack    : (self: Cast) -> number,
	SetOrientation      : (self: Cast, cf: CFrame) -> (),
	SetAngularVelocity  : (self: Cast, av: Vector3) -> (),
}

export type Signals = {
	OnFire                  : Signal<(context: BulletContextPublic, behavior: any) -> ()>,
	OnHit                   : Signal<(context: BulletContextPublic, result: RaycastResult?, velocity: Vector3, impactForce: Vector3) -> ()>,
	OnTravel                : Signal<(context: BulletContextPublic, position: Vector3, velocity: Vector3) -> ()>,
	OnTravelBatch           : Signal<(batch: { { Context: BulletContextPublic, Position: Vector3, Velocity: Vector3 } }) -> ()>,
	OnPierce                : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, pierceCount: number) -> ()>,
	OnBounce                : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, bounceCount: number, bounceForce: Vector3) -> ()>,
	OnTerminated            : Signal<(context: BulletContextPublic, reason: TerminateReason) -> ()>,
	OnPreBounce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (normal: Vector3?, incomingVelocity: Vector3?) -> ()) -> ()>,
	OnMidBounce             : Signal<(context: BulletContextPublic, result: RaycastResult, postVelocity: Vector3, mutate: (postVelocity: Vector3?, restitution: number?, perturbation: number?) -> ()) -> ()>,
	OnPrePierce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (normal: Vector3?, velocity: Vector3?) -> ()) -> ()>,
	OnMidPierce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (velocity: Vector3?) -> ()) -> ()>,
	OnSpeedThresholdCrossed : Signal<(context: BulletContextPublic, threshold: number, ascending: boolean, speed: number) -> ()>,
	OnPreTermination        : Signal<(context: BulletContextPublic, reason: TerminateReason, mutate: (cancelled: boolean, newReason: TerminateReason?) -> ()) -> ()>,
	OnSegmentOpen           : Signal<(context: BulletContextPublic, segment: any) -> ()>,
	OnBranchSpawned         : Signal<(parent: BulletContextPublic, child: BulletContextPublic) -> ()>,
	OnHomingDisengaged      : Signal<(context: BulletContextPublic) -> ()>,
	OnTumbleBegin           : Signal<(context: BulletContextPublic, velocity: Vector3) -> ()>,
	OnTumbleEnd             : Signal<(context: BulletContextPublic, velocity: Vector3) -> ()>,
}

export type Solver = {
	Signals : Signals,

	Fire              : (self: Solver, context: BulletContextPublic, behavior: any?) -> Cast,
	GetSignals        : (self: Solver) -> Signals,
	Destroy           : (self: Solver) -> (),
	SetWind           : (self: Solver, wind: Vector3) -> (),
	SetLODOrigin      : (self: Solver, origin: Vector3?) -> (),
	SetInterestPoints : (self: Solver, points: { Vector3 }) -> (),
	SetCoriolisConfig : (self: Solver, latitude: number, scale: number) -> (),
}

-- ============================================================================
-- ============================================================================

export type CastTrajectory = {
	StartTime       : number,
	EndTime         : number,
	Origin          : Vector3,
	InitialVelocity : Vector3,
	Acceleration    : Vector3,
}

export type CastRuntime = {
	TotalRuntime           : number,
	ConfirmedRuntime       : number?,
	IsThrottled            : boolean?,
	DistanceCovered        : number,
	SpawnOrigin            : Vector3,
	Trajectories           : { CastTrajectory },
	ActiveTrajectory       : CastTrajectory,
	PierceCount            : number,
	PiercedInstances       : { Instance },
	PierceCallbackThread   : thread?,
	BounceCount            : number,
	BouncesThisFrame       : number,
	LastBounceTime         : number,
	BouncePositionHistory  : { Vector3 },
	BouncePositionHead     : number,
	VelocityDirectionEMA   : Vector3,
	FirstBouncePosition    : Vector3?,
	CornerBounceCount      : number,
	BounceCallbackThread   : thread?,
	CanHomeCallbackThread  : thread?,
	CanHomeThisFrame       : boolean,
	CastFunctionThread     : thread?,
	IsActivelyResimulating : boolean,
	CurrentSegmentSize     : number,
	PierceForceRemaining : number?,
	CosmeticBulletObject   : BasePart?,
}

export type CanPierceFunction = (
	context  : any,
	result   : RaycastResult,
	velocity : Vector3
) -> boolean

export type CanBounceFunction = (
	context  : any,
	result   : RaycastResult,
	velocity : Vector3
) -> boolean

export type CanHomeFunction = (
	context         : any,
	currentPosition : Vector3,
	currentVelocity : Vector3
) -> boolean

export type CastFunction = (
	origin    : Vector3,
	direction : Vector3,
	params    : RaycastParams
) -> RaycastResult?

export type CastBehavior = {
	Acceleration               : Vector3,
	MaxDistance                : number,
	MaxDisplacement            : number,
	MinSpeed                   : number,
	MaxSpeed                   : number,
	Gravity                    : Vector3,
	ResetPierceOnBounce		   : boolean,
	RaycastParams              : RaycastParams,
	CastFunction               : CastFunction?,
	OriginalFilter             : { Instance },
	CanPierceFunction          : CanPierceFunction?,
	MaxPierceCount             : number,
	PierceSpeedThreshold       : number,
	PierceSpeedRetention  : number,
	PierceNormalBias           : number,
	PierceDepth           : number,
	PierceForce           : number,
	CanHomeFunction            : CanHomeFunction?,
	BulletMass                 : number,
	CanBounceFunction          : CanBounceFunction?,
	MaxBounces                 : number,
	BounceSpeedThreshold       : number,
	Restitution                : number,
	MaterialRestitution        : { [Enum.Material]: number }?,
	NormalPerturbation         : number,
	HighFidelitySegmentSize    : number,
	HighFidelityFrameBudget    : number,
	AdaptiveScaleFactor        : number,
	MinSegmentSize             : number,
	MaxBouncesPerFrame         : number,
	CornerTimeThreshold        : number,
	CornerPositionHistorySize  : number,
	CornerDisplacementThreshold: number,
	CornerMinProgressPerBounce : number,
	VisualizeCasts             : boolean,
}

export type VetraCast = {
	Alive     : boolean,
	Paused    : boolean,
	StartTime : number,
	_registryIndex : number?,
	Runtime  : CastRuntime,
	Behavior : CastBehavior,
	UserData : { [any]: any },
}

export type ParallelTrajectorySegment = {
	Origin          : Vector3,
	InitialVelocity : Vector3,
	Acceleration    : Vector3,
	StartTime       : number,
}

export type CastSnapshot = {
	Id                          : number,
	StaticOccupancy             : any?,
	StaticOccupancyId           : number,
	DynamicOccupancy            : any?,
	DynamicOccupancyId          : number,
	TrajectoryOrigin            : Vector3,
	TrajectoryInitialVelocity   : Vector3,
	TrajectoryAcceleration      : Vector3,
	TrajectoryStartTime         : number,
	TotalRuntime                : number,
	DistanceCovered             : number,
	IsSupersonic                : boolean,
	LastDragRecalculateTime     : number,
	SpinVector                  : Vector3,
	HomingElapsed               : number,
	HomingDisengaged            : boolean,
	HomingAcquired              : boolean,
	CurrentSegmentSize          : number,
	BouncesThisFrame            : number,
	IsTumbling                  : boolean,
	TumbleRandom                : Random?,
	BounceRandom                : Random?,
	BounceCount                 : number,
	PierceCount                 : number,
	LastBounceTime              : number,
	IsLOD                       : boolean,
	LODDistance                 : number,
	LODInterval                 : number,
	LODFrameAccumulator         : number,
	LODDeltaAccumulator         : number,
	SpatialFrameAccumulator     : number,
	SpatialDeltaAccumulator     : number,
	SpatialTier                 : number,
	LODOrigin                   : Vector3?,
	BouncePositionHistory       : { Vector3 },
	BouncePositionHead          : number,
	VelocityDirectionEMA        : Vector3,
	FirstBouncePosition         : Vector3?,
	CornerBounceCount           : number,
	MaxDistance                 : number,
	MaxDisplacement             : number,
	MinSpeed                    : number,
	MaxSpeed                    : number,
	MaxBounces                  : number,
	MaxBouncesPerFrame          : number,
	MaxPierceCount              : number,
	DragCoefficient             : number,
	DragModel                   : number,
	DragSegmentInterval         : number,
	BounceSpeedThreshold        : number,
	Restitution                 : number,
	NormalPerturbation          : number,
	MaterialRestitution         : { [string]: number }?,
	PierceSpeedThreshold        : number,
	PierceSpeedRetention   : number,
	PierceNormalBias            : number,
	MagnusCoefficient           : number,
	SpinDecayRate               : number,
	HomingStrength              : number,
	HomingMaxDuration           : number,
	HomingTarget                : Vector3?,
	HighFidelitySegmentSize     : number,
	AdaptiveScaleFactor         : number,
	MinSegmentSize              : number,
	HighFidelityFrameBudget     : number,
	CornerTimeThreshold         : number,
	CornerDisplacementThreshold : number,
	CornerEMAAlpha              : number,
	CornerEMAThreshold          : number,
	CornerMinProgressPerBounce  : number,
	HasCanPierceCallback        : boolean,
	HasCanBounceCallback        : boolean,
	HasCanHomeCallback          : boolean,
	SupersonicDragCoefficient   : number?,
	SupersonicDragModel         : number?,
	SubsonicDragCoefficient     : number?,
	SubsonicDragModel           : number?,
	BaseAcceleration            : Vector3,
	Wind                        : Vector3,
	WindResponse                : number,
	GyroDriftRate               : number?,
	GyroDriftAxis               : Vector3?,
	TumbleSpeedThreshold        : number?,
	TumbleDragMultiplier        : number?,
	TumbleLateralStrength       : number?,
	TumbleOnPierce              : boolean?,
	TumbleRecoverySpeed         : number?,
	RaycastParams               : RaycastParams,
	VisualizeCasts              : boolean,
	ProvidedLastPosition        : Vector3?,
	ProvidedCurrentPosition     : Vector3?,
	ProvidedCurrentVelocity     : Vector3?,
	RemainingResimDelta         : number?,
	_FastResult                 : ParallelResult?,
	SixDOFEnabled               : boolean?,
	Orientation                 : CFrame?,
	AngularVelocity             : Vector3?,
	AngleOfAttack               : number?,
	SixDOFAccumulator           : number?,
	LiftCoefficientSlope        : number?,
	PitchingMomentSlope         : number?,
	PitchDampingCoeff           : number?,
	RollDampingCoeff            : number?,
	AoADragFactor               : number?,
	ReferenceArea               : number?,
	ReferenceLength             : number?,
	AirDensity                  : number?,
	MomentOfInertia             : number?,
	SpinMOI                     : number?,
	MaxAngularSpeed             : number?,
	BulletMass                  : number?,
	CLAlphaMachTable            : { { number } }?,
	CmAlphaMachTable            : { { number } }?,
	CmqMachTable                : { { number } }?,
	ClpMachTable                : { { number } }?,
	CustomMachTable             : { { number } }?,
}

export type ParallelResult = {
	Id    : number,
	Event : string,
	TotalRuntime             : number?,
	DistanceCovered          : number?,
	IsSupersonic             : boolean?,
	LastDragRecalcTime       : number?,
	SpinVector               : Vector3?,
	HomingElapsed            : number?,
	HomingDisengaged         : boolean?,
	HomingAcquired           : boolean?,
	CurrentSegmentSize       : number?,
	BouncesThisFrame         : number?,
	IsTumbling               : boolean?,
	TumbleBegan              : boolean?,
	TumbleRecovered          : boolean?,
	IsLOD                    : boolean?,
	LODFrameAccumulator      : number?,
	LODDeltaAccumulator      : number?,
	SpatialFrameAccumulator  : number?,
	SpatialDeltaAccumulator  : number?,
	Trajectory               : ParallelTrajectorySegment?,
	HitPosition              : Vector3?,
	HitNormal                : Vector3?,
	HitMaterial              : Enum.Material?,
	HitInstance              : Instance?,
	RayOrigin                : Vector3?,
	ImpactDot                : number?,
	TravelPosition           : Vector3?,
	TravelVelocity           : Vector3?,
	FiredAccumulatedDelta    : number?,
	VisualizationRayOrigin   : Vector3?,
	PreBounceVelocity        : Vector3?,
	ReflectedVelocity        : Vector3?,
	IsCornerTrap             : boolean?,
	BounceCount              : number?,
	LastBounceTime           : number?,
	BouncePositionHistory    : { Vector3 }?,
	BouncePositionHead       : number?,
	VelocityDirectionEMA     : Vector3?,
	FirstBouncePosition      : Vector3?,
	CornerBounceCount        : number?,
	RemainingResimDelta      : number?,
	Orientation              : CFrame?,
	AngularVelocity          : Vector3?,
	AngleOfAttack            : number?,
}

export type ResumeSyncData = {
	TotalRuntime    : number?,
	DistanceCovered : number?,
	PierceCount     : number?,
	BounceCount     : number?,
	BouncesThisFrame: number?,
	LastBounceTime  : number?,
	TrajectoryOrigin          : Vector3?,
	TrajectoryInitialVelocity : Vector3?,
	TrajectoryAcceleration    : Vector3?,
	TrajectoryStartTime       : number?,
	IsTumbling      : boolean?,
	BouncePositionHistory : { Vector3 }?,
	BouncePositionHead    : number?,
	VelocityDirectionEMA  : Vector3?,
	FirstBouncePosition   : Vector3?,
	CornerBounceCount     : number?,
	Orientation           : CFrame?,
	AngularVelocity       : Vector3?,
	RemainingResimDelta : number?,
}

-- ============================================================================
-- ============================================================================

export type BuilderBulletContext = any

export type PierceFilter   = (Context: BuilderBulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
export type BounceFilter   = (Context: BuilderBulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean
export type HomingFilter   = (Context: BuilderBulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean
export type HomingProvider = (pos: Vector3, vel: Vector3) -> Vector3?
export type BulletProvider = (ctx: BuilderBulletContext) -> Instance?
export type TrajectoryProvider = (elapsed: number) -> Vector3?

export type SpeedProfile = {
	DragCoefficient     : number?,
	DragModel           : DragModel?,
	NormalPerturbation  : number?,
	MaterialRestitution : { [Enum.Material]: number }?,
	Restitution         : number?,
}

export type BuiltBehavior = {

	Acceleration                 : Vector3,
	MaxDistance                  : number,
	MaxDisplacement              : number,
	MaxSpeed                     : number,
	RaycastParams                : RaycastParams,
	Gravity                      : Vector3,
	MinSpeed                     : number,

	DragCoefficient              : number,
	DragModel                    : DragModel,
	DragSegmentInterval          : number,
	CustomMachTable              : { { number } }?,

	WindResponse                 : number,

	SpinVector                   : Vector3,
	MagnusCoefficient            : number,
	SpinDecayRate                : number,

	GyroDriftRate                : number?,
	GyroDriftAxis                : Vector3?,

	TumbleSpeedThreshold         : number?,
	TumbleDragMultiplier         : number,
	TumbleLateralStrength        : number,
	TumbleOnPierce               : boolean,
	TumbleRecoverySpeed          : number?,

	CanHomeFunction              : HomingFilter?,
	HomingPositionProvider       : HomingProvider?,
	HomingStrength               : number,
	HomingMaxDuration            : number,
	HomingAcquisitionRadius      : number,

	SpeedThresholds              : { number },
	SupersonicProfile            : SpeedProfile?,
	SubsonicProfile              : SpeedProfile?,

	TrajectoryPositionProvider   : TrajectoryProvider?,

	BulletMass                   : number,
	CastFunction                 : ((Vector3, Vector3, RaycastParams) -> RaycastResult?)?,

	CanPierceFunction            : PierceFilter?,
	MaxPierceCount               : number,
	PierceSpeedThreshold         : number,
	PierceSpeedRetention    : number,
	PierceNormalBias             : number,
	PierceDepth             : number,
	PierceForce             : number,
	PierceThicknessLimit    : number,

	FragmentOnPierce             : boolean,
	FragmentCount                : number,
	FragmentDeviation            : number,

	CanBounceFunction            : BounceFilter?,
	MaxBounces                   : number,
	ResetPierceOnBounce          : boolean,
	BounceSpeedThreshold         : number,
	Restitution                  : number,
	MaterialRestitution          : { [Enum.Material]: number },
	NormalPerturbation           : number,

	HighFidelitySegmentSize      : number,
	HighFidelityFrameBudget      : number,
	AdaptiveScaleFactor          : number,
	MinSegmentSize               : number,
	MaxBouncesPerFrame           : number,

	CornerTimeThreshold          : number,
	CornerPositionHistorySize    : number,
	CornerDisplacementThreshold  : number,
	CornerEMAAlpha               : number,
	CornerEMAThreshold           : number,
	CornerMinProgressPerBounce   : number,

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

	CLAlphaMachTable             : { { number } }?,
	CmAlphaMachTable             : { { number } }?,
	CmqMachTable                 : { { number } }?,
	ClpMachTable                 : { { number } }?,

	LODDistance                  : number,
	LODInterval                  : number,

	CosmeticBulletTemplate       : BasePart?,
	CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : BulletProvider?,
	AutoDeleteCosmeticBullet	 : boolean,
	CosmeticBulletNonQueryable   : boolean,

	BatchTravel                  : boolean,

	FireTravelEvents             : boolean,

	IsHitscan                    : boolean,

	VisualizeCasts               : boolean,

	UserData                     : any?,

	StaticOccupancy              : any?,
	DynamicOccupancy             : any?,
}

export type DirtySet = { [string]: boolean }

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
	BatchTravel      : (self: BehaviorBuilder, value: boolean) -> BehaviorBuilder,
	FireTravelEvents : (self: BehaviorBuilder, value: boolean) -> BehaviorBuilder,
	Hitscan          : (self: BehaviorBuilder, value: boolean) -> BehaviorBuilder,
	StaticOccupancy  : (self: BehaviorBuilder, grid: any) -> BehaviorBuilder,
	DynamicOccupancy : (self: BehaviorBuilder, set: any) -> BehaviorBuilder,
	Clone         : (self: BehaviorBuilder) -> BehaviorBuilder,
	Impose        : (self: BehaviorBuilder, other: BehaviorBuilder) -> BehaviorBuilder,
	Build         : (self: BehaviorBuilder) -> BuiltBehavior,
}

return {}
