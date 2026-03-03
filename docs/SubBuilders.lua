-- ─── PhysicsBuilder ──────────────────────────────────────────────────────────

--[=[
	@class PhysicsBuilder

	Sub-builder for physics configuration. Opened via [BehaviorBuilder:Physics].
	Call `:Done()` to return to the root [BehaviorBuilder].
]=]
local PhysicsBuilder = {}

--[=[
	Maximum distance in studs the bullet can travel before expiring.
	`OnHit` fires with a nil `RaycastResult` when this is reached.

	Default: `500`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MaxDistance(value: number): PhysicsBuilder end

--[=[
	Minimum speed in studs per second. When the bullet's speed drops below
	this value it is terminated naturally.
	`OnHit` fires with a nil `RaycastResult`.

	Default: `1`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MinSpeed(value: number): PhysicsBuilder end

--[=[
	Gravitational acceleration applied to the bullet. Pass a negative-Y vector
	for downward gravity.

	Default: `Vector3.new(0, -workspace.Gravity, 0)`

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Gravity(value: Vector3): PhysicsBuilder end

--[=[
	Extra constant acceleration layered on top of gravity (e.g. rocket thrust, wind).

	Default: `Vector3.zero`

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Acceleration(value: Vector3): PhysicsBuilder end

--[=[
	The `RaycastParams` used for all raycasts during this cast's lifetime.
	The solver clones these internally — the original is never mutated.

	Default: `RaycastParams.new()`

	@param value RaycastParams
	@return PhysicsBuilder
]=]
function PhysicsBuilder:RaycastParams(value: RaycastParams): PhysicsBuilder end

--[=[
	Returns the root [BehaviorBuilder].

	@return BehaviorBuilder
]=]
function PhysicsBuilder:Done(): BehaviorBuilder end

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
	Callback invoked for each raycast hit. Return `true` to allow the bullet
	to pierce through the instance.

	Must be **synchronous** — yielding inside this callback will cause the cast
	to be terminated with an error on the next frame.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no piercing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return PierceBuilder
]=]
function PierceBuilder:Filter(callback: (context: any, result: RaycastResult, velocity: Vector3) -> boolean): PierceBuilder end

--[=[
	Maximum total number of surfaces the bullet can pierce over its lifetime.

	Default: `3`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:Max(value: number): PierceBuilder end

--[=[
	Minimum speed in studs per second required for a pierce attempt.
	Below this speed the hit is treated as a solid terminal impact.

	Default: `50`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:SpeedThreshold(value: number): PierceBuilder end

--[=[
	Fraction of speed retained after each pierce. Must be in `[0, 1]`.
	`0.8` means 20% of speed is lost per pierce — deeper chains become
	progressively slower.

	Default: `0.8`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:SpeedRetention(value: number): PierceBuilder end

--[=[
	Restricts piercing to impacts above a minimum head-on angle. Must be in `[0, 1]`.
	`1.0` = all angles allowed. `0.0` = only perfectly perpendicular impacts pierce.

	Default: `1.0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:NormalBias(value: number): PierceBuilder end

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
	Callback invoked for each raycast hit. Return `true` to allow the bullet
	to bounce off the surface.

	Must be **synchronous** — yielding inside this callback will cause the cast
	to be terminated with an error on the next frame.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no bouncing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return BounceBuilder
]=]
function BounceBuilder:Filter(callback: (context: any, result: RaycastResult, velocity: Vector3) -> boolean): BounceBuilder end

--[=[
	Maximum total bounces across the bullet's entire lifetime.

	Default: `5`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:Max(value: number): BounceBuilder end

--[=[
	Minimum speed in studs per second required for a bounce attempt.
	Below this speed the hit is treated as a terminal impact.

	Default: `20`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:SpeedThreshold(value: number): BounceBuilder end

--[=[
	Energy-retention coefficient applied to reflected velocity. Must be in `[0, 1]`.
	`1.0` = perfectly elastic (no energy loss). `0.0` = bullet stops on first contact.

	Default: `0.7`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:Restitution(value: number): BounceBuilder end

--[=[
	Per-material restitution multipliers, keyed by `Enum.Material`.
	Combined multiplicatively with the base restitution in [BounceBuilder:Restitution].
	Omitted materials use a multiplier of `1.0`.

	```lua
	:MaterialRestitution({
	    [Enum.Material.Concrete] = 0.5,
	    [Enum.Material.Plastic]  = 0.95,
	})
	```

	Default: `{}`

	@param value {[Enum.Material]: number}
	@return BounceBuilder
]=]
function BounceBuilder:MaterialRestitution(value: {[Enum.Material]: number}): BounceBuilder end

--[=[
	Adds random noise to the surface normal before reflecting, simulating rough
	or irregular surfaces. `0` = clean mirror reflection.

	Default: `0.0`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:NormalPerturbation(value: number): BounceBuilder end

--[=[
	Returns the root [BehaviorBuilder].

	@return BehaviorBuilder
]=]
function BounceBuilder:Done(): BehaviorBuilder end

-- ─── HighFidelityBuilder ─────────────────────────────────────────────────────

--[=[
	@class HighFidelityBuilder

	Sub-builder for high-fidelity raycasting configuration. Opened via
	[BehaviorBuilder:HighFidelity]. Call `:Done()` to return to the root [BehaviorBuilder].

	High-fidelity mode subdivides each frame's travel into multiple smaller raycasts
	to prevent fast bullets from tunnelling through thin surfaces. The segment size
	is adjusted adaptively each frame to stay near the configured frame budget.
]=]
local HighFidelityBuilder = {}

--[=[
	Starting sub-segment length in studs. Smaller values produce more raycasts
	per frame and better thin-surface detection at the cost of performance.
	Adjusted adaptively at runtime.

	Default: `0.5`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:SegmentSize(value: number): HighFidelityBuilder end

--[=[
	Target wall-clock budget in milliseconds this cast may spend on sub-segment
	raycasts per frame. The adaptive system scales segment size up or down to
	stay near this target.

	Default: `4`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:FrameBudget(value: number): HighFidelityBuilder end

--[=[
	Multiplier applied when coarsening or refining segment size adaptively.
	Must be `> 1`. Higher values adapt faster but with less precision.

	Default: `1.5`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:AdaptiveScale(value: number): HighFidelityBuilder end

--[=[
	Hard floor for adaptive segment size reduction in studs.
	Must be `<= SegmentSize`. Prevents the adaptive algorithm from shrinking
	segments to near-zero.

	Default: `0.1`

	@param value number
	@return HighFidelityBuilder
]=]
function HighFidelityBuilder:MinSegmentSize(value: number): HighFidelityBuilder end

--[=[
	Maximum bounces allowed across all sub-segments within a single frame step.
	Prevents a bullet from exhausting its entire lifetime bounce budget in one frame.

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

	Sub-builder for corner trap detection configuration. Opened via
	[BehaviorBuilder:CornerTrap]. Call `:Done()` to return to the root [BehaviorBuilder].

	Corner trap detection terminates bullets that become stuck bouncing infinitely
	between two opposing surfaces (V-grooves, inside corners, narrow slots). Three
	independent guards are checked: temporal proximity, normal opposition, and
	spatial proximity. Any single guard firing is sufficient to declare a trap.
]=]
local CornerTrapBuilder = {}

--[=[
	Minimum time in seconds that must elapse between successive bounces.
	Two bounces closer together than this are flagged as a corner trap.

	Default: `0.002`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:TimeThreshold(value: number): CornerTrapBuilder end

--[=[
	Dot-product threshold for the normal-opposition guard. Must be in `[-1, 0]`.
	If consecutive surface normals have a dot product below this value they are
	considered opposing (corner trap). `-0.85` ≈ surfaces within ~32° of face-to-face.

	Default: `-0.85`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:NormalDotThreshold(value: number): CornerTrapBuilder end

--[=[
	Minimum stud distance between successive bounce contact points.
	Displacement below this threshold triggers the spatial-proximity guard.

	Default: `0.5`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:DisplacementThreshold(value: number): CornerTrapBuilder end

--[=[
	Returns the root [BehaviorBuilder].

	@return BehaviorBuilder
]=]
function CornerTrapBuilder:Done(): BehaviorBuilder end

-- ─── CosmeticBuilder ─────────────────────────────────────────────────────────

--[=[
	@class CosmeticBuilder

	Sub-builder for cosmetic bullet configuration. Opened via
	[BehaviorBuilder:Cosmetic]. Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution
	`:Provider()` and `:Template()` are mutually exclusive. Provider takes priority
	if both are set.
	:::
]=]
local CosmeticBuilder = {}

--[=[
	A `BasePart` that is cloned once per [Vetra:Fire] call and used as the
	visible bullet. The clone is destroyed automatically on termination.

	Mutually exclusive with `:Provider()` — Provider takes priority.

	Default: `nil`

	@param value BasePart
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Template(value: BasePart): CosmeticBuilder end

--[=[
	Parent `Instance` for the cosmetic bullet object. Defaults to `workspace` if nil.

	Default: `nil`

	@param value Instance
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Container(value: Instance): CosmeticBuilder end

--[=[
	A function called once per [Vetra:Fire] that returns the cosmetic bullet
	`Instance`. Use this for object pooling or procedural creation.

	Must be **synchronous** — yielding will log a warning. Takes priority over
	`:Template()` if both are set.

	Signature: `() -> Instance?`

	Default: `nil`

	@param callback () -> Instance?
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Provider(callback: () -> Instance?): CosmeticBuilder end

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
	Enables the trajectory visualizer. Draws cast segments, hit points, surface
	normals, bounce vectors, and corner trap markers in the world.

	Zero runtime cost when `false`.

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

return {}