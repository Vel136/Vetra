--[=[
	@class TypeDefinitions

	Shared Luau type definitions used across Vetra.

	These are imported for type annotations only — there is no runtime cost.
	You generally do not need to require this module directly; the types are
	re-exported from [Vetra] where needed.
]=]

-- ─── CastTrajectory ──────────────────────────────────────────────────────────

--[=[
	@interface CastTrajectory
	@within TypeDefinitions

	Represents one continuous parabolic arc of a projectile's flight path.

	A new segment is appended to `Runtime.Trajectories` on every bounce or
	mid-flight kinematic change via the `Set*` / `Add*` methods on [VetraCast].
	`EndTime` of `-1` indicates the segment is still active.

	.StartTime number -- `Runtime.TotalRuntime` when this segment began.
	.EndTime number -- `Runtime.TotalRuntime` when closed; `-1` while active.
	.Origin Vector3 -- World-space start position of this arc.
	.InitialVelocity Vector3 -- Velocity at `StartTime` in studs/second.
	.Acceleration Vector3 -- Constant acceleration for this arc (gravity + extra).
]=]

-- ─── BulletSnapshot ──────────────────────────────────────────────────────────

--[=[
	@interface BulletSnapshot
	@within TypeDefinitions

	Read-only snapshot of a [BulletContext]'s state at a point in time.
	Returned by [BulletContext:GetSnapshot].

	.Id number -- Unique identifier.
	.Origin Vector3 -- Muzzle position at fire time.
	.Direction Vector3 -- Initial unit direction.
	.Speed number -- Initial speed in studs/second.
	.Position Vector3? -- Current world-space position, or nil before the first frame.
	.Velocity Vector3 -- Current velocity vector.
	.Alive boolean -- Whether the cast is still being simulated.
	.Lifetime number -- Seconds elapsed since creation.
	.DistanceTraveled number -- Straight-line distance from Origin to Position.
]=]

-- ─── BulletContextConfig ─────────────────────────────────────────────────────

--[=[
	@interface BulletContextConfig
	@within TypeDefinitions

	Configuration table passed to [BulletContext.new].

	.Origin Vector3 -- Required. World-space muzzle position.
	.Direction Vector3 -- Required. Unit direction vector.
	.Speed number -- Required. Initial speed in studs/second.
	.Callbacks BulletCallbacks? -- Optional per-instance event callbacks.
	.SolverData any? -- Internal — used by the solver to attach lifecycle hooks.
]=]

-- ─── VetraBehavior ──────────────────────────────────────────────────────────

--[=[
	@interface VetraBehavior
	@within TypeDefinitions

	Complete configuration for a projectile cast. All fields are optional —
	any omitted field falls back to a safe built-in default.

	Prefer constructing this via [BehaviorBuilder] rather than by hand to get
	typed setters, validation, and a frozen result.

	**Physics**
	.Acceleration Vector3? -- Extra acceleration on top of gravity. Default: `Vector3.zero`
	.MaxDistance number? -- Max flight distance in studs. Default: `500`
	.RaycastParams RaycastParams? -- Raycast filter. Default: `RaycastParams.new()`
	.Gravity Vector3? -- Gravitational acceleration. Default: workspace gravity downward.
	.MinSpeed number? -- Termination speed threshold in studs/sec. Default: `1`

	**Pierce**
	.CanPierceFunction ((BulletContext, RaycastResult, Vector3) -> boolean)? -- Pierce gate. Default: `nil`
	.MaxPierceCount number? -- Lifetime pierce limit. Default: `3`
	.PierceSpeedThreshold number? -- Min speed to attempt pierce. Default: `50`
	.PenetrationSpeedRetention number? -- Speed fraction kept per pierce `[0,1]`. Default: `0.8`
	.PierceNormalBias number? -- Min approach angle for pierce `[0,1]`. Default: `1.0`

	**Bounce**
	.CanBounceFunction ((BulletContext, RaycastResult, Vector3) -> boolean)? -- Bounce gate. Default: `nil`
	.MaxBounces number? -- Lifetime bounce limit. Default: `5`
	.BounceSpeedThreshold number? -- Min speed to attempt bounce. Default: `20`
	.Restitution number? -- Energy retention per bounce `[0,1]`. Default: `0.7`
	.MaterialRestitution {[Enum.Material]: number}? -- Per-material multipliers. Default: `{}`
	.NormalPerturbation number? -- Random normal noise for rough surfaces. Default: `0.0`

	**High Fidelity**
	.HighFidelitySegmentSize number? -- Sub-segment length in studs. Default: `0.5`
	.HighFidelityFrameBudget number? -- Ms budget per cast per frame. Default: `4`
	.AdaptiveScaleFactor number? -- Adaptive scaling multiplier `> 1`. Default: `1.5`
	.MinSegmentSize number? -- Hard floor for adaptive sizing. Default: `0.1`
	.MaxBouncesPerFrame number? -- Per-frame bounce cap. Default: `10`

	**Corner Trap**
	.CornerTimeThreshold number? -- Min seconds between bounces. Default: `0.002`
	.CornerNormalDotThreshold number? -- Normal opposition threshold `[-1,0]`. Default: `-0.85`
	.CornerDisplacementThreshold number? -- Min bounce separation in studs. Default: `0.5`

	**Cosmetic**
	.CosmeticBulletTemplate BasePart? -- Part cloned per fire. Default: `nil`
	.CosmeticBulletContainer Instance? -- Parent for cosmetic object. Default: `nil`
	.CosmeticBulletProvider (() -> Instance?)? -- Provider function (takes priority). Default: `nil`

	**Debug**
	.VisualizeCasts boolean? -- Enable trajectory visualizer. Default: `false`
]=]

return {}