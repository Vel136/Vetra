--[=[
	@class TypeDefinitions

	Shared Luau type definitions used across Vetra and VetraNet.

	These are imported for type annotations only — there is no runtime cost.
	You generally do not need to require this module directly.
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
	.Acceleration Vector3 -- Constant acceleration for this arc (gravity + extra + initial drag).
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
	.Lifetime number -- Seconds of simulated time elapsed since creation.
	.PathLength number -- True accumulated path distance (bounces included).
	.DistanceTraveled number -- Alias for PathLength (API compatibility).
]=]

-- ─── BulletContextConfig ─────────────────────────────────────────────────────

--[=[
	@interface BulletContextConfig
	@within TypeDefinitions

	Configuration table passed to [BulletContext.new].

	.Origin Vector3 -- Required. World-space muzzle position.
	.Direction Vector3 -- Required. Unit direction vector.
	.Speed number -- Required. Initial speed in studs/second.
	.SolverData any? -- Internal — used by the solver to attach lifecycle hooks. Do not set from weapon code.
]=]

-- ─── SpeedProfile ────────────────────────────────────────────────────────────

--[=[
	@interface SpeedProfile
	@within TypeDefinitions

	Per-speed-regime behavior overrides. Assigned to `SupersonicProfile` or
	`SubsonicProfile` on a `VetraBehavior`. The solver blends in the matching
	profile's values when the bullet crosses the speed of sound (343 studs/s).

	All fields are optional. Omitted fields continue using the base behavior values.

	.DragCoefficient number? -- Drag coefficient override for this regime.
	.DragModel DragModel? -- Drag model override for this regime.
	.NormalPerturbation number? -- Bounce noise override for this regime.
	.MaterialRestitution { [Enum.Material]: number }? -- Per-material restitution overrides.
	.Restitution number? -- Base restitution override for this regime.
]=]

-- ─── VetraBehavior ───────────────────────────────────────────────────────────

--[=[
	@interface VetraBehavior
	@within TypeDefinitions

	Complete configuration for a projectile cast. All fields are optional —
	any omitted field falls back to a safe built-in default.

	Prefer constructing this via [BehaviorBuilder] rather than by hand to get
	typed setters, build-time validation, and a frozen result. For fields not
	exposed by the builder (drag, Magnus, homing config, tumble, etc.), pass a
	raw table or a table that inherits from a built behavior via `__index`.

	---

	**Physics**
	.Acceleration Vector3? -- Extra acceleration on top of gravity (e.g. rocket thrust). Default: `Vector3.zero`
	.MaxDistance number? -- Max flight distance in studs. Default: `500`
	.MaxSpeed number? -- Speed ceiling; bullet terminates if exceeded. Default: `math.huge`
	.MinSpeed number? -- Termination speed threshold in studs/sec. Default: `1`
	.RaycastParams RaycastParams? -- Raycast filter. Default: `RaycastParams.new()`
	.Gravity Vector3? -- Gravitational acceleration (negative Y = downward). Default: workspace gravity downward.
	.CastFunction ((Vector3, Vector3, RaycastParams) -> RaycastResult?)? -- Custom cast function (serial solver only). Default: `nil`
	.BulletMass number? -- Bullet mass for penetration and impact-force calculations. Default: `0`

	---

	**Aerodynamic Drag**
	.DragCoefficient number? -- Drag coefficient. `0` = no drag. Default: `0`
	.DragModel DragModel? -- Drag model type. Default: `"Quadratic"`
	.DragSegmentInterval number? -- Seconds between drag + Magnus recalculation steps. Default: `0.05`
	.CustomMachTable { { number } }? -- Custom Mach→Cd table pairs when `DragModel = "Custom"`.

	---

	**Wind**
	.WindResponse number? -- Multiplier on the solver's wind vector (`Vetra:SetWind`). `1.0` = full effect, `0.0` = immune. Default: `1.0`

	---

	**Supersonic / Subsonic Profiles**
	.SpeedThresholds { number }? -- Sorted list of speeds (studs/s) that fire `OnSpeedThresholdCrossed`. Default: `{}`
	.SupersonicProfile SpeedProfile? -- Behavior overrides when bullet speed is >= 343 studs/s. Default: `nil`
	.SubsonicProfile SpeedProfile? -- Behavior overrides when bullet speed is < 343 studs/s. Default: `nil`

	---

	**Magnus Effect**
	.SpinVector Vector3? -- Spin axis (direction) × angular velocity (magnitude, rad/s). `Vector3.zero` = disabled. Default: `Vector3.zero`
	.MagnusCoefficient number? -- Magnus lift coefficient. Typical range: 0.00005–0.001. `0` = disabled. Default: `0`
	.SpinDecayRate number? -- Rate at which `SpinVector` magnitude decreases per second. `0` = no decay. Default: `0`

	---

	**Gyroscopic Drift**
	.GyroDriftRate number? -- Lateral drift acceleration magnitude in studs/s². `nil` = disabled. Default: `nil`
	.GyroDriftAxis Vector3? -- Reference axis for drift direction. `nil` = world UP (right-hand rifling). Default: `nil`

	---

	**Tumble**
	.TumbleSpeedThreshold number? -- Speed below which tumbling begins. `nil` = disabled. Default: `nil`
	.TumbleDragMultiplier number? -- Drag multiplied by this factor while tumbling. Default: `3.0`
	.TumbleLateralStrength number? -- Chaotic lateral acceleration magnitude in studs/s². Default: `0`
	.TumbleOnPierce boolean? -- Begin tumbling on first pierce regardless of speed. Default: `false`
	.TumbleRecoverySpeed number? -- Speed above which tumbling ends. `nil` = tumble is permanent. Default: `nil`

	---

	**Homing**
	.HomingPositionProvider ((pos: Vector3, vel: Vector3) -> Vector3?)? -- Called every frame for target position. Return `nil` to disengage. Default: `nil`
	.CanHomeFunction CanHomeCallback? -- Gate callback; return `false` to disengage. Default: `nil`
	.HomingStrength number? -- Steering force in degrees/second. Default: `90`
	.HomingMaxDuration number? -- Max seconds of active homing before `OnHomingDisengaged` fires. Default: `3`
	.HomingAcquisitionRadius number? -- Min target distance in studs to engage. `0` = engage immediately on fire. Default: `0`

	---

	**Trajectory Provider**
	.TrajectoryPositionProvider ((elapsed: number) -> Vector3?)? -- Override bullet position each frame with a sampled curve. Return `nil` to end the override and terminate. Default: `nil`

	---

	**Pierce**
	.CanPierceFunction CanPierceCallback? -- Pierce gate; return `true` to pierce. Default: `nil`
	.MaxPierceCount number? -- Lifetime pierce limit. Default: `3`
	.PierceSpeedThreshold number? -- Min speed to attempt pierce (studs/s). Default: `50`
	.PenetrationSpeedRetention number? -- Speed fraction kept per pierce `[0,1]`. Default: `0.8`
	.PierceNormalBias number? -- Min approach angle for pierce `[0,1]`. `1.0` = all angles, `0.0` = perpendicular only. Default: `1.0`
	.PenetrationDepth number? -- Max wall thickness per pierce in studs. `0` = no per-pierce depth limit. Default: `0`
	.PenetrationForce number? -- Total momentum force budget for penetration. `0` = disabled. Default: `0`
	.PenetrationThicknessLimit number? -- Hard cap on wall thickness for the exit-point raycast in studs. Default: `500`

	---

	**Fragmentation**
	.FragmentOnPierce boolean? -- Spawn fragment child bullets when a pierce occurs. Default: `false`
	.FragmentCount number? -- Number of fragments to spawn per pierce. Default: `3`
	.FragmentDeviation number? -- Angular half-angle spread of the fragment cone in degrees. Default: `15`

	---

	**Bounce**
	.CanBounceFunction CanBounceCallback? -- Bounce gate; return `true` to bounce. Default: `nil`
	.MaxBounces number? -- Lifetime bounce limit. Default: `5`
	.BounceSpeedThreshold number? -- Min speed to attempt bounce (studs/s). Default: `20`
	.Restitution number? -- Energy retention per bounce `[0,1]`. Default: `0.7`
	.MaterialRestitution { [Enum.Material]: number }? -- Per-material multipliers, combined with `Restitution`. Default: `{}`
	.NormalPerturbation number? -- Random surface-normal noise for rough surfaces. `0` = clean reflection. Default: `0.0`
	.ResetPierceOnBounce boolean? -- Reset pierce state after each confirmed bounce. Default: `false`

	---

	**High Fidelity**
	.HighFidelitySegmentSize number? -- Sub-segment length in studs (starting value). Default: `0.5`
	.HighFidelityFrameBudget number? -- Millisecond budget per cast per frame for sub-segment raycasts. Default: `4`
	.AdaptiveScaleFactor number? -- Adaptive sizing multiplier, must be `> 1`. Default: `1.5`
	.MinSegmentSize number? -- Hard floor for adaptive segment size (studs). Default: `0.1`
	.MaxBouncesPerFrame number? -- Per-frame bounce cap across all sub-segments. Default: `10`

	---

	**Corner Trap Detection**
	.CornerTimeThreshold number? -- Min seconds between bounces (Pass 1). Default: `0.002`
	.CornerPositionHistorySize number? -- Bounce position history size, positive integer (Pass 3 & 4). Default: `4`
	.CornerDisplacementThreshold number? -- Min bounce separation in studs (Pass 3). Default: `0.5`
	.CornerEMAAlpha number? -- EMA smoothing factor for velocity direction `(0,1)` (Pass 2). Default: `0.4`
	.CornerEMAThreshold number? -- EMA oscillation threshold (Pass 2). Must be `> |1 - 2·alpha|`. Default: `0.25`
	.CornerMinProgressPerBounce number? -- Min studs of progress per bounce over history (Pass 4). `0` disables Pass 4. Default: `0.3`

	---

	**LOD**
	.LODDistance number? -- Studs from the LOD origin beyond which this bullet steps at reduced frequency. `0` = always full frequency. Default: `0`

	---

	**Cosmetic**
	.CosmeticBulletTemplate BasePart? -- Part cloned per fire call. Default: `nil`
	.CosmeticBulletContainer Instance? -- Parent for the cosmetic object. Defaults to `workspace`. Default: `nil`
	.CosmeticBulletProvider ((context: BulletContext) -> Instance?)? -- Provider function; takes priority over Template. Default: `nil`

	---

	**Batch Travel**
	.BatchTravel boolean? -- Include this cast in `OnTravelBatch` instead of firing individual `OnTravel` events. Default: `false`

	---

	**Wind Sensitivity**
	.WindResponse number? -- Multiplier on the solver's wind vector. `1.0` = fully affected, `0.0` = immune. Default: `1.0`

	---

	**Debug**
	.VisualizeCasts boolean? -- Enable trajectory visualizer for this cast. Default: `false`
]=]

-- ─── DragModel ───────────────────────────────────────────────────────────────

--[=[
	@type DragModel "Linear" | "Quadratic" | "Exponential" | "G1" | "G2" | "G3" | "G4" | "G5" | "G6" | "G7" | "G8" | "GL" | "Custom"
	@within TypeDefinitions

	Drag model used to compute aerodynamic deceleration each `DragSegmentInterval`.

	**Analytic models:**
	- `"Linear"` — deceleration ∝ speed.
	- `"Quadratic"` — deceleration ∝ speed² (default). Most physically accurate for subsonic bullets.
	- `"Exponential"` — deceleration ∝ eˢᵖᵉᵉᵈ. Models exotic high-drag shapes.

	**G-series empirical models (Mach-indexed Cd lookup tables):**
	- `"G1"` — flat-base spitzer; general-purpose standard.
	- `"G2"` — Aberdeen J projectile; large-caliber / atypical shapes.
	- `"G5"` — boat-tail spitzer; mid-range rifles.
	- `"G6"` — semi-spitzer flat-base; shotgun slugs.
	- `"G7"` — long boat-tail; modern long-range / sniper standard.
	- `"G8"` — flat-base semi-spitzer; hollow points / pistols.
	- `"GL"` — lead round ball; cannons / muskets / buckshot.

	**User-supplied:**
	- `"Custom"` — requires `CustomMachTable = { {mach, cd}, ... }` in the behavior.
]=]

-- ─── TerminationReason ───────────────────────────────────────────────────────

--[=[
	@type TerminationReason "hit" | "distance" | "speed" | "corner_trap" | "manual"
	@within TypeDefinitions

	The reason a cast was terminated. Passed as the second argument to
	`OnPreTermination` signal handlers.

	- `"hit"` — bullet struck a surface and was not pierced or bounced.
	- `"distance"` — `MaxDistance` was reached.
	- `"speed"` — speed dropped below `MinSpeed` or exceeded `MaxSpeed`.
	- `"corner_trap"` — corner-trap detection terminated the cast.
	- `"manual"` — `Terminate()` was called explicitly, or the solver was destroyed.
]=]

-- ─── NetworkConfig ───────────────────────────────────────────────────────────

--[=[
	@interface NetworkConfig
	@within TypeDefinitions

	Optional configuration table passed to `VetraNet.new()` as the third argument.
	All fields are optional — unset fields fall back to built-in defaults.

	.MaxOriginTolerance number? -- Max studs between client-reported and server-reconstructed fire origin. Default: `15`
	.MaxConcurrentPerPlayer number? -- Maximum in-flight bullets per player at any time. Default: `20`
	.TokensPerSecond number? -- Token-bucket refill rate for fire-rate limiting. Default: `10`
	.BurstLimit number? -- Maximum burst tokens. Must be `>= TokensPerSecond`. Default: `20`
	.DriftThreshold number? -- Studs of positional drift before cosmetic correction begins. Default: `2`
	.CorrectionRate number? -- Lerp speed for cosmetic drift correction in studs/second. Default: `8`
	.LatencyBuffer number? -- Extra seconds to delay local cosmetic spawn. `0` = use measured RTT automatically. Default: `0`
	.ReplicateState boolean? -- Broadcast bullet state every Heartbeat to all clients for cosmetic correction. Default: `true`
]=]

-- ─── SpatialPartitionConfig ──────────────────────────────────────────────────

--[=[
	@interface SpatialPartitionConfig
	@within TypeDefinitions

	Optional configuration for the LOD spatial partition system. Passed as
	`SpatialPartition` inside the `FactoryConfig` to `Vetra.new()` or
	`Vetra.newParallel()`.

	.HotRadius number? -- Studs radius around an interest point for HOT tier (full-frequency simulation). Default: `150`
	.WarmRadius number? -- Studs radius for WARM tier (must be >= HotRadius). Default: `400`
	.FallbackTier string? -- Tier for bullets outside all warm radii. `"HOT"`, `"WARM"`, or `"COLD"`. Default: `"HOT"`
	.UpdateInterval number? -- Frames between spatial grid rebuilds. Default: `3`
]=]

return {}
