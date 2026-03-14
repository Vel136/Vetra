--!strict

-- Typed callback signatures matching TypeDefinition.luau — using any for the
-- BulletContext parameter since the public API type is not re-exported here.
export type CanPierceCallback = (ctx: any, result: RaycastResult, velocity: Vector3) -> boolean
export type CanBounceCallback = (ctx: any, result: RaycastResult, velocity: Vector3) -> boolean
export type CanHomeCallback   = (ctx: any, currentPosition: Vector3, currentVelocity: Vector3) -> boolean

export type DragModel =
	-- Analytic models
	| "Linear"
	| "Quadratic"
	| "Exponential"
	-- G-series empirical drag functions (Mach-indexed Cd lookup tables).
	-- Coefficient acts as a scalar multiplier — 1.0 = physically accurate.
	| "G1"   -- flat-base spitzer; general-purpose standard
	| "G2"   -- Aberdeen J projectile; large-caliber / atypical
	| "G3"   -- Finnish reference projectile; rarely used in practice
	| "G4"   -- seldom-used reference; included for completeness
	| "G5"   -- boat-tail spitzer; mid-range rifles
	| "G6"   -- semi-spitzer flat-base; shotgun slugs / blunt rounds
	| "G7"   -- long boat-tail; modern long-range / sniper standard
	| "G8"   -- flat-base semi-spitzer; hollow points / pistols
	| "GL"   -- lead round ball; cannons / muskets / buckshot
	-- User-supplied table. Requires CustomMachTable = { {mach, cd}, ... }
	| "Custom"

export type SpeedProfile = {
	DragCoefficient    : number?,
	NormalPerturbation : number?,
	MaterialRestitution: { [Enum.Material]: number }?,
	Restitution        : number?,
}

export type TerminationReason = "hit" | "distance" | "speed" | "corner_trap" | "manual"

export type VetraBehavior = {
	Acceleration                 : Vector3?,
	MaxDistance                  : number?,
	MaxSpeed                     : number?,
	RaycastParams                : RaycastParams?,
	Gravity                      : Vector3?,
	MinSpeed                     : number?,

	DragCoefficient              : number?,
	DragModel                    : DragModel?,
	DragSegmentInterval          : number?,
	CustomMachTable              : { { number } }?,

	GyroDriftRate                : number?,   -- acceleration magnitude (studs/s²); nil or 0 = disabled
	GyroDriftAxis                : Vector3?,  -- reference axis for drift direction; nil = world UP (right-hand rifling)

	TumbleSpeedThreshold         : number?,   -- speed (studs/s) below which tumbling begins; nil = disabled
	TumbleDragMultiplier         : number?,   -- drag coefficient multiplier while tumbling; default 3.0
	TumbleLateralStrength        : number?,   -- chaotic lateral acceleration magnitude (studs/s²); default 0
	TumbleOnPierce               : boolean?,  -- begin tumbling on first pierce regardless of speed
	TumbleRecoverySpeed          : number?,   -- speed (studs/s) above which tumbling ends; nil = permanent

	SpeedThresholds              : { number }?,
	SupersonicProfile            : SpeedProfile?,
	SubsonicProfile              : SpeedProfile?,

	WindResponse                 : number?,

	TrajectoryPositionProvider   : ((elapsed: number) -> Vector3?)?,

	HomingPositionProvider       : ((currentPosition: Vector3, currentVelocity: Vector3) -> Vector3?)?,
	CanHomeFunction              : CanHomeCallback?,
	HomingStrength               : number?,
	HomingMaxDuration            : number?,
	HomingAcquisitionRadius      : number?,

	CanPierceFunction            : CanPierceCallback?,
	MaxPierceCount               : number?,
	PierceSpeedThreshold         : number?,
	PenetrationSpeedRetention    : number?,
	PierceNormalBias             : number?,
	PenetrationDepth             : number?,
	PenetrationForce             : number?,

	FragmentOnPierce             : boolean?,
	FragmentCount                : number?,
	FragmentDeviation            : number?,

	BulletMass                   : number?,

	CanBounceFunction            : CanBounceCallback?,
	MaxBounces                   : number?,
	BounceSpeedThreshold         : number?,
	Restitution                  : number?,
	MaterialRestitution          : { [Enum.Material]: number }?,
	NormalPerturbation           : number?,
	ResetPierceOnBounce          : boolean?,

	HighFidelitySegmentSize      : number?,
	HighFidelityFrameBudget      : number?,
	AdaptiveScaleFactor          : number?,
	MinSegmentSize               : number?,
	MaxBouncesPerFrame           : number?,

	CornerTimeThreshold          : number?,
	CornerPositionHistorySize    : number?,
	CornerDisplacementThreshold  : number?,
	CornerEMAAlpha               : number?,
	CornerEMAThreshold           : number?,

	LODDistance                  : number?,

	CosmeticBulletTemplate       : BasePart?,
	CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : ((ctx: any) -> Instance?)?,

	BatchTravel                  : boolean?,
	VisualizeCasts               : boolean?,
}

return {}