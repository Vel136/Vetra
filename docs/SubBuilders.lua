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
	Maximum speed in studs per second. When the bullet's speed rises above
	this value it is terminated. `OnHit` fires with a nil `RaycastResult`.

	Useful for capping homing missiles or rockets that accelerate indefinitely,
	preventing them from tunnelling through thin surfaces.

	Default: `math.huge` (no cap)

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MaxSpeed(value: number): PhysicsBuilder end

--[=[
	Minimum speed in studs per second. When the bullet's speed drops below
	this value it is terminated. `OnHit` fires with a nil `RaycastResult`.

	Default: `1`

	@param value number
	@return PhysicsBuilder
]=]
function PhysicsBuilder:MinSpeed(value: number): PhysicsBuilder end

--[=[
	Gravitational acceleration applied to the bullet. Pass a negative-Y
	vector for downward gravity.

	Default: `Vector3.new(0, -workspace.Gravity, 0)` (read at builder construction time)

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Gravity(value: Vector3): PhysicsBuilder end

--[=[
	Extra constant acceleration layered on top of gravity — for example,
	rocket thrust. Wind is applied separately via [Vetra:SetWind] and
	`WindResponse`, and drag is applied separately via `DragCoefficient`.

	Default: `Vector3.zero`

	@param value Vector3
	@return PhysicsBuilder
]=]
function PhysicsBuilder:Acceleration(value: Vector3): PhysicsBuilder end

--[=[
	The `RaycastParams` used for all raycasts during this cast's lifetime.
	The solver acquires a clone from its internal pool — the original is
	never mutated.

	Default: `RaycastParams.new()`

	@param value RaycastParams
	@return PhysicsBuilder
]=]
function PhysicsBuilder:RaycastParams(value: RaycastParams): PhysicsBuilder end

--[=[
	Optional custom cast function. Replaces `workspace:Raycast` for every
	intersection test this bullet performs. Use for `workspace:Spherecast`,
	`workspace:Blockcast`, or any custom raycast wrapper.

	Signature: `(origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?`

	`direction` is the raw displacement vector for that frame (not a unit vector)
	— its length equals the cast distance.

	:::caution Parallel solver
	`CastFunction` is **serial-exclusive**. It is silently ignored when using
	`Vetra.newParallel()` because functions cannot cross Actor boundaries via
	message serialization. Use `Vetra.new()` if you need a custom cast function.
	:::

	Default: `nil` (uses `workspace:Raycast`)

	@param value (origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?
	@return PhysicsBuilder
]=]
function PhysicsBuilder:CastFunction(value: (Vector3, Vector3, RaycastParams) -> RaycastResult?): PhysicsBuilder end

--[=[
	Mass of the bullet in game units. Used by penetration calculations that
	model momentum transfer — a heavier bullet retains more speed through
	a thick surface than a lighter one given the same `PenetrationForce` budget.

	Set to `0` to disable mass-based calculations (the force budget is used
	directly without mass scaling). Also used by VetraNet's `impactForce`
	calculation: `BulletMass × velocity.Magnitude`.

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

	Sub-builder for the homing gate filter. Opened via [BehaviorBuilder:Homing].
	Call `:Done()` to return to the root [BehaviorBuilder].

	:::caution Only exposes the gate filter
	This builder only sets `CanHomeFunction`. The core homing fields —
	`HomingPositionProvider`, `HomingStrength`, `HomingMaxDuration`, and
	`HomingAcquisitionRadius` — must be set directly on the raw behavior table
	passed to `Solver:Fire()`.

	```lua
	local Behavior = BehaviorBuilder.new()
	    :Homing()
	        :Filter(function(context, pos, vel)
	            return not context.UserData.HomingDisabled
	        end)
	    :Done()
	    :Build()

	-- Pass homing config on the raw table alongside the built behavior:
	Solver:Fire(context, setmetatable({
	    HomingPositionProvider = function(pos, vel)
	        return targetPart.Position
	    end,
	    HomingStrength         = 90,
	    HomingMaxDuration      = 3,
	    HomingAcquisitionRadius = 0,
	}, { __index = Behavior }))
	```

	**Raw behavior fields for homing:**

	| Field | Type | Default | Description |
	|-------|------|---------|-------------|
	| `HomingPositionProvider` | `((pos: Vector3, vel: Vector3) -> Vector3?)?` | `nil` | Called every frame to get the target position. Return `nil` to disengage. |
	| `HomingStrength` | `number` | `90` | Steering force in degrees per second. |
	| `HomingMaxDuration` | `number` | `3` | Maximum seconds of active homing before `OnHomingDisengaged` fires. |
	| `HomingAcquisitionRadius` | `number` | `0` | Min target distance in studs to engage homing. `0` = engage immediately on fire. |
	:::
]=]
local HomingBuilder = {}

--[=[
	Sets the `CanHomeFunction` gate callback. Return `true` to allow homing
	to continue this frame, `false` to disengage and fire `OnHomingDisengaged`.

	Must be **synchronous** — yielding will terminate the cast.

	Signature: `(context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean`

	Default: `nil` (always home if `HomingPositionProvider` returns a position)

	@param callback (context: BulletContext, currentPosition: Vector3, currentVelocity: Vector3) -> boolean
	@return HomingBuilder
]=]
function HomingBuilder:Filter(callback: (any, Vector3, Vector3) -> boolean): HomingBuilder end

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
	If pierce succeeds, the bounce filter is not checked for that hit.
	:::
]=]
local PierceBuilder = {}

--[=[
	Callback invoked for each raycast hit. Return `true` to allow the bullet
	to pierce through the instance.

	Must be **synchronous** — yielding inside this callback terminates the cast
	with an error on the next frame.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no piercing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return PierceBuilder
]=]
function PierceBuilder:Filter(callback: (any, RaycastResult, Vector3) -> boolean): PierceBuilder end

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
	Restricts piercing to impacts above a minimum head-on angle. Must be
	in `[0, 1]`. `1.0` = all angles allowed. `0.0` = only perfectly
	perpendicular impacts pierce.

	Default: `1.0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:NormalBias(value: number): PierceBuilder end

--[=[
	Maximum wall thickness in studs that the bullet can penetrate per pierce.
	The solver performs an internal second raycast to find the exit point — if
	the wall is thicker than this value the bullet stops inside it.

	`0` = no depth limit per pierce (the `ThicknessLimit` hard cap still applies).

	Default: `0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:PenetrationDepth(value: number): PierceBuilder end

--[=[
	Total penetration force budget. Each surface absorbs force proportional
	to its thickness and the bullet's `BulletMass`. When the budget reaches
	zero the bullet can no longer pierce.

	`0` = disabled (use `MaxPierceCount` alone for simple multi-pierce without
	momentum modeling).

	Default: `0`

	@param value number
	@return PierceBuilder
]=]
function PierceBuilder:PenetrationForce(value: number): PierceBuilder end

--[=[
	Hard cap on wall thickness in studs. The solver's internal exit-point
	raycast extends at most this many studs through a surface. Any wall
	thicker than this is treated as impenetrable regardless of force budget
	or `PenetrationDepth`.

	Default: `500`

	@param value number -- Must be > 0.
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
	if pierce did not occur on that hit.
	:::
]=]
local BounceBuilder = {}

--[=[
	Callback invoked for each raycast hit. Return `true` to allow the bullet
	to bounce off the surface.

	Must be **synchronous** — yielding inside this callback terminates the cast
	with an error on the next frame.

	Signature: `(context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean`

	Default: `nil` (no bouncing)

	@param callback (context: BulletContext, result: RaycastResult, velocity: Vector3) -> boolean
	@return BounceBuilder
]=]
function BounceBuilder:Filter(callback: (any, RaycastResult, Vector3) -> boolean): BounceBuilder end

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

	Combined multiplicatively with `MaterialRestitution` for the hit surface's
	material. The `SubsonicProfile.Restitution` override applies when the bullet
	is subsonic.

	Default: `0.7`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:Restitution(value: number): BounceBuilder end

--[=[
	Per-material restitution multipliers, keyed by `Enum.Material`.
	Combined multiplicatively with the base [BounceBuilder:Restitution].
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
function BounceBuilder:MaterialRestitution(value: { [Enum.Material]: number }): BounceBuilder end

--[=[
	Adds random noise to the surface normal before reflecting, simulating rough
	or irregular surfaces. `0` = clean mirror reflection. Higher values scatter
	the bullet more unpredictably. The `SubsonicProfile.NormalPerturbation`
	override applies when the bullet is subsonic.

	Default: `0.0`

	@param value number
	@return BounceBuilder
]=]
function BounceBuilder:NormalPerturbation(value: number): BounceBuilder end

--[=[
	When `true`, pierce state (`PiercedInstances`, `PierceCount`, and the
	`FilterDescendantsInstances` filter) is automatically reset after each
	confirmed bounce, restoring the full pierce budget for the new arc.

	Required for bounce + pierce combinations where the post-bounce trajectory
	should be able to re-detect previously pierced surfaces.

	For conditional resets (e.g. only after the first bounce), call
	`cast:ResetPierceState()` manually inside an `OnBounce` handler instead.

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

	Sub-builder for high-fidelity raycasting configuration. Opened via
	[BehaviorBuilder:HighFidelity]. Call `:Done()` to return to the root
	[BehaviorBuilder].

	High-fidelity mode subdivides each frame's travel into multiple smaller
	raycasts to prevent fast bullets from tunnelling through thin surfaces.
	The segment size is adjusted adaptively each frame to stay near the
	configured frame budget.
]=]
local HighFidelityBuilder = {}

--[=[
	Starting sub-segment length in studs. Smaller values produce more raycasts
	per frame and better thin-surface detection at the cost of performance.
	The adaptive system adjusts this value at runtime.

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
	Prevents a bullet from exhausting its entire lifetime bounce budget in one
	frame when moving very fast through a dense environment.

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

	Sub-builder for corner-trap detection configuration. Opened via
	[BehaviorBuilder:CornerTrap]. Call `:Done()` to return to the root
	[BehaviorBuilder].

	Corner-trap detection terminates bullets that become stuck bouncing
	infinitely between two or more opposing surfaces (V-grooves, inside corners,
	narrow slots). The detector runs four independent checks — any single check
	firing is sufficient to declare a trap and terminate the cast:

	**Pass 1 — Temporal:** Two bounces within `CornerTimeThreshold` seconds
	triggers termination.

	**Pass 2 — Velocity EMA:** An exponential moving average of the bullet's
	velocity direction is tracked across bounces. If the EMA magnitude falls
	below `CornerEMAThreshold`, the bullet is oscillating and is terminated.

	**Pass 3 — Spatial:** If successive bounce contact points fall within
	`CornerDisplacementThreshold` studs of each other, the bullet is trapped.

	**Pass 4 — Minimum progress:** The bullet must advance at least
	`CornerMinProgressPerBounce` studs from its first bounce contact over
	the tracked history window. Catches slow-drift traps that pass the other
	three checks. Set to `0` to disable this pass.

	:::tip EMA parameter constraint
	`CornerEMAThreshold` must be greater than `|1 − 2 · CornerEMAAlpha|`.
	At the default `alpha = 0.4`, this gives `|1 - 0.8| = 0.2`, so the
	threshold must be `> 0.2`. The default `0.25` satisfies this with a
	clear margin. `:Build()` validates this constraint and returns `nil`
	if it is violated.
	:::
]=]
local CornerTrapBuilder = {}

--[=[
	Minimum time in seconds that must elapse between successive bounces.
	Two bounces closer together than this are flagged as a corner trap (Pass 1).

	Default: `0.002`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:TimeThreshold(value: number): CornerTrapBuilder end

--[=[
	Number of bounce contact points kept in the rolling position history.
	Must be a positive integer. Higher values make the Pass 3 spatial and
	Pass 4 progress checks more robust at the cost of slightly more memory.

	Default: `4`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:PositionHistorySize(value: number): CornerTrapBuilder end

--[=[
	Minimum stud distance between successive bounce contact points.
	Displacement below this threshold triggers the Pass 3 spatial-proximity guard.

	Default: `0.5`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:DisplacementThreshold(value: number): CornerTrapBuilder end

--[=[
	EMA smoothing factor for velocity direction tracking (Pass 2). Must be in `(0, 1)`.
	Higher values weight recent bounces more heavily — detection is faster but more
	sensitive to brief directional wobble.

	Default: `0.4`

	:::caution
	`CornerEMAThreshold` must be `> |1 − 2 · CornerEMAAlpha|`. If you change
	this value, adjust `EMAThreshold` accordingly. `:Build()` enforces this.
	:::

	@param value number -- Must be in (0, 1).
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:EMAAlpha(value: number): CornerTrapBuilder end

--[=[
	EMA magnitude threshold below which oscillation is declared (Pass 2).
	Must be `> |1 − 2 · CornerEMAAlpha|` — see class note.

	Default: `0.25`

	@param value number
	@return CornerTrapBuilder
]=]
function CornerTrapBuilder:EMAThreshold(value: number): CornerTrapBuilder end

--[=[
	Minimum studs the bullet must advance from its first bounce contact over
	the `PositionHistorySize` window (Pass 4). Set to `0` to disable Pass 4.

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

	Sub-builder for cosmetic bullet configuration. Opened via
	[BehaviorBuilder:Cosmetic]. Call `:Done()` to return to the root
	[BehaviorBuilder].

	:::caution
	`:Provider()` and `:Template()` are mutually exclusive. Provider takes
	priority if both are set, and a warning is logged.
	:::
]=]
local CosmeticBuilder = {}

--[=[
	A `BasePart` that is cloned once per [Vetra:Fire] call and used as the
	visible bullet. The clone is parented to `Container` (or `workspace` if nil)
	and destroyed automatically on termination.

	Mutually exclusive with `:Provider()` — Provider takes priority.

	Default: `nil`

	@param value BasePart
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Template(value: BasePart): CosmeticBuilder end

--[=[
	Parent `Instance` for the cosmetic bullet object. Defaults to `workspace`
	if nil.

	Default: `nil`

	@param value Instance
	@return CosmeticBuilder
]=]
function CosmeticBuilder:Container(value: Instance): CosmeticBuilder end

--[=[
	A function called once per [Vetra:Fire] that returns the cosmetic bullet
	`Instance`. Use this for object pooling or procedural creation.

	Must be **synchronous** — yielding logs a warning. Takes priority over
	`:Template()` if both are set.

	The [BulletContext] is passed as the first argument so the provider can
	read `UserData` (e.g. to pick a projectile model by weapon type).

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
	Enables the trajectory visualizer. Draws cast segments, hit points, surface
	normals, bounce vectors, and corner-trap markers directly in the world.

	Zero runtime cost when `false` — no raycasts or draw calls are added.

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
