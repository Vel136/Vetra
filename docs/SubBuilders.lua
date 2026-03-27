-- ─── PhysicsBuilder ──────────────────────────────────────────────────────────

--[=[
	@class PhysicsBuilder

	Sub-builder for physics configuration. Opened via [BehaviorBuilder:Physics].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local PhysicsBuilder = {}

--[=[
	Maximum distance in studs the bullet can travel before expiring.

	Default: `500`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MaxDistance(value: number): PhysicsBuilder end

--[=[
	Maximum speed in studs per second. Bullet terminates if speed exceeds this.

	Default: `math.huge` (no cap)

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MaxSpeed(value: number): PhysicsBuilder end

--[=[
	Minimum speed in studs per second. Bullet terminates when speed drops below this.

	Default: `1`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MinSpeed(value: number): PhysicsBuilder end

--[=[
	Gravitational acceleration. Pass a negative-Y vector for downward gravity.

	Default: `Vector3.new(0, -workspace.Gravity, 0)` (read at construction time)

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Gravity(value: Vector3): PhysicsBuilder end

--[=[
	Extra constant acceleration layered on top of gravity — e.g. rocket thrust.

	Default: `Vector3.zero`

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Acceleration(value: Vector3): PhysicsBuilder end

--[=[
	`RaycastParams` used for all raycasts during this cast's lifetime.

	**Priority order** — [Vetra:Fire] resolves params using:
	1. `Behavior.RaycastParams` — this setter, if called.
	2. `BulletContext.RaycastParams` — per-bullet filter set on the context.
	3. Empty `RaycastParams.new()` — catch-all fallback.

	:::warning Takes priority over BulletContext
	Calling this setter locks the params for every bullet fired with this
	behavior, even if individual `BulletContext` objects supply their own
	`RaycastParams`. Only call this when all bullets from this behavior
	should share the same filter. Use `BulletContext.RaycastParams` instead
	when filtering needs to vary per bullet.
	:::

	Default: `nil` (not set — defers to BulletContext or the fallback)

	@param value RaycastParams
	@return PhysicsBuilder
]=]
function PhysicsBuilder:RaycastParams(value: RaycastParams): PhysicsBuilder end

--[=[
	Optional custom cast function replacing `workspace:Raycast`. Use for
	`Spherecast`, `Blockcast`, or any custom raycast wrapper.

	Signature: `(origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?`

	:::caution Serial solver only
	Silently ignored by `Vetra.newParallel()` — functions cannot cross Actor
	boundaries via message serialization.
	:::

	Default: `nil`

	@param value (origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?
	@return PhysicsBuilder
]=]
function PhysicsBuilder:CastFunction(value: (Vector3, Vector3, RaycastParams) -> RaycastResult?): PhysicsBuilder end

--[=[
	Mass of the bullet in game units. Used by penetration and impact-force
	calculations. Set to `0` to disable mass-based scaling.

	Default: `0`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:BulletMass(value: number): PhysicsBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function PhysicsBuilder:Done(): BehaviorBuilder end

-- ─── HomingBuilder ───────────────────────────────────────────────────────────

--[=[
	@class HomingBuilder

	Sub-builder for homing configuration. Opened via [BehaviorBuilder:Homing].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local HomingBuilder = {}

--[=[
	Gate callback invoked every frame. Return `false` to disengage homing
	and fire `OnHomingDisengaged`.

	Signature: `(context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean`

	Default: `nil` (always homes while PositionProvider returns a position)

	@param callback (context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean
	@return HomingBuilder
]=]
function HomingBuilder:Filter(callback: (any, Vector3, Vector3) -> boolean): HomingBuilder end

--[=[
	Called every frame to get the target position. Return `nil` to disengage.

	Signature: `(pos: Vector3, vel: Vector3) -> Vector3?`

	Default: `nil`

	@param callback (pos: Vector3, vel: Vector3) -> Vector3?
	@return HomingBuilder
]=]
function HomingBuilder:PositionProvider(callback: (Vector3, Vector3) -> Vector3?): HomingBuilder end

--[=[
	Steering force in degrees per second.

	Default: `90`

	@param value number
	@return HomingBuilder
]=]
function HomingBuilder:Strength(value: number): HomingBuilder end

--[=[
	Maximum seconds of active homing before `OnHomingDisengaged` fires.

	Default: `3`

	@param value number
	@return HomingBuilder
]=]
function HomingBuilder:MaxDuration(value: number): HomingBuilder end

--[=[
	Minimum target distance in studs to engage homing. `0` = engage immediately.

	Default: `0`

	@param value number
	@return HomingBuilder
]=]
function HomingBuilder:AcquisitionRadius(value: number): HomingBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function HomingBuilder:Done(): BehaviorBuilder end

-- ─── PierceBuilder ───────────────────────────────────────────────────────────

--[=[
	@class PierceBuilder

	Sub-builder for pierce configuration. Opened via [BehaviorBuilder:Pierce].
	Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution
	Pierce and bounce are mutually exclusive per hit. Pierce is evaluated first.
	:::
]=]
local PierceBuilder = {}

--[=[
	Pierce gate. Return `true` to pierce; `false` treats the hit as terminal.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no piercing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return PierceBuilder
]=]
function PierceBuilder:Filter(callback: (any, RaycastResult, Vector3) -> boolean): PierceBuilder end

--[=[
	Maximum total surfaces the bullet can pierce over its lifetime.

	Default: `3`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:Max(value: number): PierceBuilder end

--[=[
	Minimum speed (studs/s) required to attempt a pierce.

	Default: `50`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:SpeedThreshold(value: number): PierceBuilder end

--[=[
	Fraction of speed retained per pierce. Must be in `[0, 1]`.

	Default: `0.8`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:SpeedRetention(value: number): PierceBuilder end

--[=[
	Minimum approach angle for pierce. Must be in `[0, 1]`.
	`1.0` = all angles; `0.0` = perpendicular only.

	Default: `1.0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:NormalBias(value: number): PierceBuilder end

--[=[
	Maximum wall thickness per pierce in studs. `0` = no per-pierce limit.

	Default: `0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:PenetrationDepth(value: number): PierceBuilder end

--[=[
	Total momentum force budget for penetration. `0` = disabled.

	Default: `0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:PenetrationForce(value: number): PierceBuilder end

--[=[
	Hard cap on wall thickness for the exit-point raycast in studs.

	Default: `500`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:ThicknessLimit(value: number): PierceBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function PierceBuilder:Done(): BehaviorBuilder end

-- ─── BounceBuilder ───────────────────────────────────────────────────────────

--[=[
	@class BounceBuilder

	Sub-builder for bounce configuration. Opened via [BehaviorBuilder:Bounce].
	Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution
	Pierce and bounce are mutually exclusive per hit. Bounce is only evaluated
	if pierce did not occur.
	:::
]=]
local BounceBuilder = {}

--[=[
	Bounce gate. Return `true` to bounce.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no bouncing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return BounceBuilder
]=]
function BounceBuilder:Filter(callback: (any, RaycastResult, Vector3) -> boolean): BounceBuilder end

--[=[
	Lifetime bounce limit.

	Default: `5`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:Max(value: number): BounceBuilder end

--[=[
	Minimum speed (studs/s) required to attempt a bounce.

	Default: `20`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:SpeedThreshold(value: number): BounceBuilder end

--[=[
	Base energy retention per bounce. Must be in `[0, 1]`.

	Default: `0.7`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:Restitution(value: number): BounceBuilder end

--[=[
	Per-material restitution multipliers, combined with the base `Restitution`.

	Default: `{}`

	@param value { [Enum.Material]: number }
	@return BounceBuilder
]=]
function BounceBuilder:MaterialRestitution(value: { [Enum.Material]: number }): BounceBuilder end

--[=[
	Random surface-normal noise for rough surfaces. `0` = clean reflection.

	Default: `0`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:NormalPerturbation(value: number): BounceBuilder end

--[=[
	If `true`, pierce state resets after each confirmed bounce.

	Default: `false`

	@param value boolean
	@return BounceBuilder
]=]
function BounceBuilder:ResetPierceOnBounce(value: boolean): BounceBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function BounceBuilder:Done(): BehaviorBuilder end

-- ─── HighFidelityBuilder ─────────────────────────────────────────────────────

--[=[
	@class HighFidelityBuilder

	Sub-builder for high-fidelity sub-segment raycasting.
	Opened via [BehaviorBuilder:HighFidelity]. Call `:Done()` to return.
]=]
local HighFidelityBuilder = {}

--[=[
	Sub-segment length in studs (starting value, shrinks adaptively).

	Default: `0.5`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:SegmentSize(value: number): HighFidelityBuilder end

--[=[
	Millisecond budget per cast per frame for sub-segment raycasts.

	Default: `4`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:FrameBudget(value: number): HighFidelityBuilder end

--[=[
	Adaptive sizing multiplier. Must be `> 1`.

	Default: `1.5`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:AdaptiveScale(value: number): HighFidelityBuilder end

--[=[
	Hard floor for adaptive segment size in studs. Must be `<= SegmentSize`.

	Default: `0.1`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:MinSegmentSize(value: number): HighFidelityBuilder end

--[=[
	Per-frame bounce cap across all sub-segments.

	Default: `10`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:MaxBouncesPerFrame(value: number): HighFidelityBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function HighFidelityBuilder:Done(): BehaviorBuilder end

-- ─── CornerTrapBuilder ───────────────────────────────────────────────────────

--[=[
	@class CornerTrapBuilder

	Sub-builder for corner-trap detection. Opened via [BehaviorBuilder:CornerTrap].
	Call `:Done()` to return to the root [BehaviorBuilder].

	Corner-trap detection terminates bullets stuck bouncing infinitely between
	opposing surfaces. Four independent passes run on every bounce — any single
	pass firing is sufficient to declare a trap:

	- **Pass 1 — Temporal:** Two bounces within `CornerTimeThreshold` seconds.
	- **Pass 2 — Velocity EMA:** Velocity direction EMA falls below `CornerEMAThreshold`.
	- **Pass 3 — Spatial:** Successive bounce contact points within `CornerDisplacementThreshold` studs.
	- **Pass 4 — Minimum progress:** Bullet fails to advance `CornerMinProgressPerBounce` studs from its first bounce contact.
]=]
local CornerTrapBuilder = {}

--[=[
	Minimum seconds between successive bounces (Pass 1).

	Default: `0.002`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:TimeThreshold(value: number): CornerTrapBuilder end

--[=[
	Bounce contact point history size. Must be a positive integer.

	Default: `4`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:PositionHistorySize(value: number): CornerTrapBuilder end

--[=[
	Minimum stud distance between successive contact points (Pass 3).

	Default: `0.5`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:DisplacementThreshold(value: number): CornerTrapBuilder end

--[=[
	EMA smoothing factor for velocity direction tracking (Pass 2). Must be in `(0, 1)`.

	:::caution
	`EMAThreshold` must be `> |1 − 2 · EMAAlpha|`. Changing this value requires
	updating `EMAThreshold`. `:Build()` enforces the constraint.
	:::

	Default: `0.4`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:EMAAlpha(value: number): CornerTrapBuilder end

--[=[
	EMA magnitude threshold below which oscillation is declared (Pass 2).
	Must be `> |1 − 2 · EMAAlpha|`.

	Default: `0.25`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:EMAThreshold(value: number): CornerTrapBuilder end

--[=[
	Minimum studs of progress per bounce over the history window (Pass 4).
	Set to `0` to disable Pass 4.

	Default: `0.3`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:MinProgressPerBounce(value: number): CornerTrapBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function CornerTrapBuilder:Done(): BehaviorBuilder end

-- ─── CosmeticBuilder ─────────────────────────────────────────────────────────

--[=[
	@class CosmeticBuilder

	Sub-builder for cosmetic bullet configuration. Opened via [BehaviorBuilder:Cosmetic].
	Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution
	`:Provider()` and `:Template()` are mutually exclusive. Provider takes
	priority if both are set, and a warning is logged.
	:::
]=]
local CosmeticBuilder = {}

--[=[
	A `BasePart` cloned once per fire call. Mutually exclusive with `:Provider()`.

	Default: `nil`

	@param value BasePart
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Template(value: BasePart): CosmeticBuilder end

--[=[
	Parent `Instance` for the cosmetic bullet object. Defaults to `workspace`.

	Default: `nil`

	@param value Instance
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Container(value: Instance): CosmeticBuilder end

--[=[
	Factory function called once per fire call. Takes priority over `:Template()`.

	Signature: `(context: BulletContext) -> Instance?`

	Default: `nil`

	@param callback (context: BulletContext) -> Instance?
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Provider(callback: (any) -> Instance?): CosmeticBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function CosmeticBuilder:Done(): BehaviorBuilder end

-- ─── DebugBuilder ────────────────────────────────────────────────────────────

--[=[
	@class DebugBuilder

	Sub-builder for debug configuration. Opened via [BehaviorBuilder:Debug].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local DebugBuilder = {}

--[=[
	Enables the trajectory visualizer. Zero runtime cost when `false`.

	Default: `false`

	@param value boolean
	@return DebugBuilder
]=]
function DebugBuilder:Visualize(value: boolean): DebugBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function DebugBuilder:Done(): BehaviorBuilder end

-- ─── DragBuilder ─────────────────────────────────────────────────────────────

--[=[
	@class DragBuilder

	Sub-builder for aerodynamic drag. Opened via [BehaviorBuilder:Drag].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local DragBuilder = {}

--[=[
	Drag coefficient. `0` = no drag.

	Default: `0`

	@param value number
	@return DragBuilder
]=]
function DragBuilder:Coefficient(value: number): DragBuilder end

--[=[
	Drag model. Use `BehaviorBuilder.DragModel` enum values.

	Default: `BehaviorBuilder.DragModel.Quadratic`

	@param value DragModel
	@return DragBuilder
]=]
function DragBuilder:Model(value: DragModel): DragBuilder end

--[=[
	Seconds between drag and Magnus recalculation steps.

	Default: `0.05`

	@param value number
	@return DragBuilder
]=]
function DragBuilder:SegmentInterval(value: number): DragBuilder end

--[=[
	Required when `Model = BehaviorBuilder.DragModel.Custom`.
	Table of `{mach, cd}` pairs, sorted ascending by Mach number.

	Default: `nil`

	@param value { { number } }
	@return DragBuilder
]=]
function DragBuilder:CustomMachTable(value: { { number } }): DragBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function DragBuilder:Done(): BehaviorBuilder end

-- ─── WindBuilder ─────────────────────────────────────────────────────────────

--[=[
	@class WindBuilder

	Sub-builder for wind sensitivity. Opened via [BehaviorBuilder:Wind].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local WindBuilder = {}

--[=[
	Multiplier on the solver's global wind vector (`Vetra:SetWind`).
	`1.0` = fully affected, `0.0` = immune.

	Default: `1.0`

	@param value number
	@return WindBuilder
]=]
function WindBuilder:Response(value: number): WindBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function WindBuilder:Done(): BehaviorBuilder end

-- ─── MagnusBuilder ───────────────────────────────────────────────────────────

--[=[
	@class MagnusBuilder

	Sub-builder for the Magnus effect. Opened via [BehaviorBuilder:Magnus].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local MagnusBuilder = {}

--[=[
	Spin axis × angular velocity in rad/s. `Vector3.zero` disables the effect.

	Default: `Vector3.zero`

	@param value Vector3
	@return MagnusBuilder
]=]
function MagnusBuilder:SpinVector(value: Vector3): MagnusBuilder end

--[=[
	Magnus lift coefficient. Typical range: `0.00005`–`0.001`.

	Default: `0`

	@param value number
	@return MagnusBuilder
]=]
function MagnusBuilder:Coefficient(value: number): MagnusBuilder end

--[=[
	Rate at which `SpinVector` magnitude decreases per second. `0` = no decay.

	Default: `0`

	@param value number
	@return MagnusBuilder
]=]
function MagnusBuilder:SpinDecayRate(value: number): MagnusBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function MagnusBuilder:Done(): BehaviorBuilder end

-- ─── GyroDriftBuilder ────────────────────────────────────────────────────────

--[=[
	@class GyroDriftBuilder

	Sub-builder for gyroscopic drift. Opened via [BehaviorBuilder:GyroDrift].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local GyroDriftBuilder = {}

--[=[
	Lateral drift acceleration magnitude in studs/s². Setting this enables drift.

	Default: `nil` (disabled)

	@param value number
	@return GyroDriftBuilder
]=]
function GyroDriftBuilder:Rate(value: number): GyroDriftBuilder end

--[=[
	Reference axis for drift direction. `nil` = world UP (right-hand rifling).

	Default: `nil`

	@param value Vector3
	@return GyroDriftBuilder
]=]
function GyroDriftBuilder:Axis(value: Vector3): GyroDriftBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function GyroDriftBuilder:Done(): BehaviorBuilder end

-- ─── TumbleBuilder ───────────────────────────────────────────────────────────

--[=[
	@class TumbleBuilder

	Sub-builder for bullet tumble. Opened via [BehaviorBuilder:Tumble].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local TumbleBuilder = {}

--[=[
	Speed (studs/s) below which tumbling begins. Setting this enables speed-based onset.

	Default: `nil` (disabled)

	@param value number
	@return TumbleBuilder
]=]
function TumbleBuilder:SpeedThreshold(value: number): TumbleBuilder end

--[=[
	Drag multiplied by this factor while tumbling. Must be `>= 1`.

	Default: `3.0`

	@param value number
	@return TumbleBuilder
]=]
function TumbleBuilder:DragMultiplier(value: number): TumbleBuilder end

--[=[
	Chaotic lateral acceleration magnitude in studs/s² applied while tumbling.

	Default: `0`

	@param value number
	@return TumbleBuilder
]=]
function TumbleBuilder:LateralStrength(value: number): TumbleBuilder end

--[=[
	If `true`, bullet begins tumbling on first pierce regardless of speed.

	Default: `false`

	@param value boolean
	@return TumbleBuilder
]=]
function TumbleBuilder:OnPierce(value: boolean): TumbleBuilder end

--[=[
	Speed above which tumbling ends. `nil` = permanent once triggered.
	Must be `> SpeedThreshold` if both are set.

	Default: `nil`

	@param value number
	@return TumbleBuilder
]=]
function TumbleBuilder:RecoverySpeed(value: number): TumbleBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function TumbleBuilder:Done(): BehaviorBuilder end

-- ─── FragmentationBuilder ────────────────────────────────────────────────────

--[=[
	@class FragmentationBuilder

	Sub-builder for fragmentation on pierce. Opened via [BehaviorBuilder:Fragmentation].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local FragmentationBuilder = {}

--[=[
	Enable or disable fragment child bullet spawning on pierce.

	Default: `false`

	@param value boolean
	@return FragmentationBuilder
]=]
function FragmentationBuilder:OnPierce(value: boolean): FragmentationBuilder end

--[=[
	Number of fragment child bullets spawned per pierce.

	Default: `3`

	@param value number
	@return FragmentationBuilder
]=]
function FragmentationBuilder:Count(value: number): FragmentationBuilder end

--[=[
	Angular half-angle spread of the fragment cone in degrees. Must be in `[0, 180]`.

	Default: `15`

	@param value number
	@return FragmentationBuilder
]=]
function FragmentationBuilder:Deviation(value: number): FragmentationBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function FragmentationBuilder:Done(): BehaviorBuilder end

-- ─── SpeedProfilesBuilder ────────────────────────────────────────────────────

--[=[
	@class SpeedProfilesBuilder

	Sub-builder for supersonic/subsonic speed profile configuration.
	Opened via [BehaviorBuilder:SpeedProfiles]. Call `:Done()` to return to
	the root [BehaviorBuilder].
]=]
local SpeedProfilesBuilder = {}

--[=[
	Sorted list of speeds (studs/s) that fire `OnSpeedThresholdCrossed`.

	Default: `{}`

	@param value { number }
	@return SpeedProfilesBuilder
]=]
function SpeedProfilesBuilder:Thresholds(value: { number }): SpeedProfilesBuilder end

--[=[
	Opens a [SpeedProfileBuilder] for the supersonic regime (speed >= 343 studs/s).
	Call `:Done()` on the profile builder to commit it and return here.

	@return SpeedProfileBuilder
]=]
function SpeedProfilesBuilder:Supersonic(): SpeedProfileBuilder end

--[=[
	Opens a [SpeedProfileBuilder] for the subsonic regime (speed < 343 studs/s).
	Call `:Done()` on the profile builder to commit it and return here.

	@return SpeedProfileBuilder
]=]
function SpeedProfilesBuilder:Subsonic(): SpeedProfileBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function SpeedProfilesBuilder:Done(): BehaviorBuilder end

-- ─── SpeedProfileBuilder ─────────────────────────────────────────────────────

--[=[
	@class SpeedProfileBuilder

	Inner builder for a single speed-regime profile (supersonic or subsonic).
	Opened via [SpeedProfilesBuilder:Supersonic] or [SpeedProfilesBuilder:Subsonic].
	Call `:Done()` to commit the profile and return to [SpeedProfilesBuilder].

	All fields are optional — omitted fields continue using the base behavior values.
]=]
local SpeedProfileBuilder = {}

--[=[
	Drag coefficient override for this regime.

	@param value number
	@return SpeedProfileBuilder
]=]
function SpeedProfileBuilder:DragCoefficient(value: number): SpeedProfileBuilder end

--[=[
	Drag model override for this regime. Use `BehaviorBuilder.DragModel` values.

	@param value DragModel
	@return SpeedProfileBuilder
]=]
function SpeedProfileBuilder:DragModel(value: DragModel): SpeedProfileBuilder end

--[=[
	Bounce normal perturbation override for this regime.

	@param value number
	@return SpeedProfileBuilder
]=]
function SpeedProfileBuilder:NormalPerturbation(value: number): SpeedProfileBuilder end

--[=[
	Base restitution override for this regime.

	@param value number
	@return SpeedProfileBuilder
]=]
function SpeedProfileBuilder:Restitution(value: number): SpeedProfileBuilder end

--[=[
	Per-material restitution overrides for this regime.

	@param value { [Enum.Material]: number }
	@return SpeedProfileBuilder
]=]
function SpeedProfileBuilder:MaterialRestitution(value: { [Enum.Material]: number }): SpeedProfileBuilder end

--[=[
	Commits the profile to the parent config and returns [SpeedProfilesBuilder].
	@return SpeedProfilesBuilder
]=]
function SpeedProfileBuilder:Done(): SpeedProfilesBuilder end

-- ─── SixDOFBuilder ───────────────────────────────────────────────────────────

--[=[
	@class SixDOFBuilder

	Sub-builder for 6DOF aerodynamic physics configuration. Opened via [BehaviorBuilder:SixDOF].
	Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution BulletMass required
	When 6DOF is enabled, `BulletMass` must be set via `:Physics():BulletMass()`.
	`:Build()` returns `nil` if it is zero or unset — mass is required to convert
	aerodynamic force vectors into accelerations.
	:::
]=]
local SixDOFBuilder = {}

--[=[
	Enables or disables the 6DOF aerodynamics system for this cast.
	When `false` (the default), no 6DOF code runs and all other fields are ignored.

	Default: `false`

	@param value boolean
	@return SixDOFBuilder
]=]
function SixDOFBuilder:Enabled(value: boolean): SixDOFBuilder end

--[=[
	dCL/dα — lift coefficient slope. Scales aerodynamic lift with angle of attack.
	Typical range: `1.0`–`4.0`. `0` disables lift.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:LiftCoefficientSlope(value: number): SixDOFBuilder end

--[=[
	dCm/dα — pitching moment slope. Negative values produce a statically stable
	restoring torque (the bullet noses back toward velocity). Zero = neutrally stable.
	Typical range: `-1.0` to `-0.1`.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:PitchingMomentSlope(value: number): SixDOFBuilder end

--[=[
	Cmq — pitch/yaw damping coefficient. Damps wobble and coning motion.
	Typical range: `0.005`–`0.05`. `0` = no damping.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:PitchDampingCoeff(value: number): SixDOFBuilder end

--[=[
	Clp — roll damping coefficient. Controls how quickly axial spin decays.
	Typical range: `0.001`–`0.02`. `0` = no spin decay.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:RollDampingCoeff(value: number): SixDOFBuilder end

--[=[
	sin²α drag multiplier. Adds extra drag proportional to angle of attack squared.
	`3.0` triples drag at 90° AoA. `0` = no AoA-dependent drag.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:AoADragFactor(value: number): SixDOFBuilder end

--[=[
	Reference cross-sectional area in studs². Scales all aerodynamic forces.
	Typical value for a rifle bullet: `0.005`–`0.02`.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:ReferenceArea(value: number): SixDOFBuilder end

--[=[
	Reference length (caliber) in studs. Used for pitching moment and damping torques.
	Typical value for a rifle bullet: `0.03`–`0.1`.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:ReferenceLength(value: number): SixDOFBuilder end

--[=[
	Air density in kg/m³. Scales all aerodynamic forces.
	Use lower values for high-altitude simulation.

	Default: `1.225` (sea level)

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:AirDensity(value: number): SixDOFBuilder end

--[=[
	Transverse moment of inertia. Governs pitch/yaw angular acceleration from aerodynamic torques.
	Typical value for a rifle bullet: `0.0005`–`0.005`.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:MomentOfInertia(value: number): SixDOFBuilder end

--[=[
	Axial (spin) moment of inertia. Required for gyroscopic precession.
	Typical value for a rifle bullet: `0.0001`–`0.001`. `0` disables precession.

	Default: `0`

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:SpinMOI(value: number): SixDOFBuilder end

--[=[
	Angular speed ceiling in rad/s. Clamps the angular velocity magnitude each step
	to prevent divergence under extreme torques.

	Default: `~628` rad/s (≈6000 RPM)

	@param value number
	@return SixDOFBuilder
]=]
function SixDOFBuilder:MaxAngularSpeed(value: number): SixDOFBuilder end

--[=[
	Initial body-frame orientation as a `CFrame`. When `nil`, the orientation is
	seeded from a velocity look-at at fire time.

	Default: `nil`

	@param value CFrame?
	@return SixDOFBuilder
]=]
function SixDOFBuilder:InitialOrientation(value: CFrame?): SixDOFBuilder end

--[=[
	Initial angular velocity in rad/s (world frame). When `nil`, seeded from the
	Magnus `SpinVector` if one is set, otherwise zero.

	Default: `nil`

	@param value Vector3?
	@return SixDOFBuilder
]=]
function SixDOFBuilder:InitialAngularVelocity(value: Vector3?): SixDOFBuilder end

--[=[
	Mach-indexed CLα table. Overrides [SixDOFBuilder:LiftCoefficientSlope] when set.
	Useful for transonic/supersonic lift drop-off modelling.

	Table format: `{ {mach, cl_alpha}, ... }` sorted ascending by Mach number.

	Default: `nil` (flat scalar used)

	@param value {{number}}
	@return SixDOFBuilder
]=]
function SixDOFBuilder:CLAlphaMachTable(value: {{number}}): SixDOFBuilder end

--[=[
	Mach-indexed Cmα table. Overrides [SixDOFBuilder:PitchingMomentSlope] when set.
	Useful for modelling reduced static stability at transonic speeds.

	Table format: `{ {mach, cm_alpha}, ... }` sorted ascending by Mach number.

	Default: `nil` (flat scalar used)

	@param value {{number}}
	@return SixDOFBuilder
]=]
function SixDOFBuilder:CmAlphaMachTable(value: {{number}}): SixDOFBuilder end

--[=[
	Mach-indexed Cmq table. Overrides [SixDOFBuilder:PitchDampingCoeff] when set.
	Allows pitch/yaw damping to vary with Mach number.

	Table format: `{ {mach, cmq}, ... }` sorted ascending by Mach number.

	Default: `nil` (flat scalar used)

	@param value {{number}}
	@return SixDOFBuilder
]=]
function SixDOFBuilder:CmqMachTable(value: {{number}}): SixDOFBuilder end

--[=[
	Mach-indexed Clp table. Overrides [SixDOFBuilder:RollDampingCoeff] when set.
	Allows spin-decay rate to vary with Mach number.

	Table format: `{ {mach, clp}, ... }` sorted ascending by Mach number.

	Default: `nil` (flat scalar used)

	@param value {{number}}
	@return SixDOFBuilder
]=]
function SixDOFBuilder:ClpMachTable(value: {{number}}): SixDOFBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function SixDOFBuilder:Done(): BehaviorBuilder end

-- ─── TrajectoryBuilder ───────────────────────────────────────────────────────

--[=[
	@class TrajectoryBuilder

	Sub-builder for trajectory position override. Opened via [BehaviorBuilder:Trajectory].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local TrajectoryBuilder = {}

--[=[
	Overrides bullet position each frame with a sampled curve.
	Return `nil` from the callback to end the override and terminate the cast.

	Signature: `(elapsed: number) -> Vector3?`

	Default: `nil`

	@param value (elapsed: number) -> Vector3?
	@return TrajectoryBuilder
]=]
function TrajectoryBuilder:Provider(value: (number) -> Vector3?): TrajectoryBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function TrajectoryBuilder:Done(): BehaviorBuilder end

-- ─── LODBuilder ──────────────────────────────────────────────────────────────

--[=[
	@class LODBuilder

	Sub-builder for LOD distance configuration. Opened via [BehaviorBuilder:LOD].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local LODBuilder = {}

--[=[
	Studs from the LOD origin beyond which this bullet steps at reduced frequency.
	`0` = always full frequency (LOD disabled for this cast).

	Default: `0`

	@param value number
	@return LODBuilder
]=]
function LODBuilder:Distance(value: number): LODBuilder end

--[=[
	Returns the root [BehaviorBuilder].
	@return BehaviorBuilder
]=]
function LODBuilder:Done(): BehaviorBuilder end

return {}