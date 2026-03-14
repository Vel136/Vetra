--[=[
	@class BehaviorBuilder

	Fluent typed configuration builder for [Vetra].

	Instead of constructing raw behavior tables by hand, chain namespace
	methods and call `:Build()` to produce a validated, frozen `VetraBehavior`.

	```lua
	local Behavior = BehaviorBuilder.new()
	    :Physics()
	        :MaxDistance(500)
	        :MinSpeed(5)
	    :Done()
	    :Bounce()
	        :Max(3)
	        :Restitution(0.7)
	        :Filter(function(context, result, vel)
	            return result.Instance:HasTag("Bouncy")
	        end)
	    :Done()
	    :Build()
	```

	**Namespace overview:**

	| Method | Configures |
	|--------|------------|
	| `:Physics()` | MaxDistance, MaxSpeed, MinSpeed, Gravity, Acceleration, RaycastParams, CastFunction, BulletMass |
	| `:Homing()` | CanHomeFunction (gate filter only) |
	| `:Pierce()` | Filter, Max, SpeedThreshold, SpeedRetention, NormalBias, PenetrationDepth, PenetrationForce, ThicknessLimit |
	| `:Bounce()` | Filter, Max, SpeedThreshold, Restitution, MaterialRestitution, NormalPerturbation, ResetPierceOnBounce |
	| `:HighFidelity()` | SegmentSize, FrameBudget, AdaptiveScale, MinSegmentSize, MaxBouncesPerFrame |
	| `:CornerTrap()` | TimeThreshold, PositionHistorySize, DisplacementThreshold, EMAAlpha, EMAThreshold, MinProgressPerBounce |
	| `:Cosmetic()` | Template, Container, Provider |
	| `:Debug()` | Visualize |

	:::caution Fields not exposed by the builder
	Several `VetraBehavior` fields must be set directly on a raw table and passed
	to `Solver:Fire()`, because they require function references or have no
	builder setter. These include:

	- **Drag:** `DragCoefficient`, `DragModel`, `DragSegmentInterval`, `CustomMachTable`
	- **Magnus:** `SpinVector`, `MagnusCoefficient`, `SpinDecayRate`
	- **Gyroscopic drift:** `GyroDriftRate`, `GyroDriftAxis`
	- **Tumble:** `TumbleSpeedThreshold`, `TumbleDragMultiplier`, `TumbleLateralStrength`, `TumbleOnPierce`, `TumbleRecoverySpeed`
	- **Fragmentation:** `FragmentOnPierce`, `FragmentCount`, `FragmentDeviation`
	- **Homing config:** `HomingPositionProvider`, `HomingStrength`, `HomingMaxDuration`, `HomingAcquisitionRadius`
	- **Speed profiles:** `SpeedThresholds`, `SupersonicProfile`, `SubsonicProfile`
	- **Trajectory override:** `TrajectoryPositionProvider`
	- **Wind sensitivity:** `WindResponse`
	- **LOD:** `LODDistance`
	- **Batch travel:** `BatchTravel`

	You can mix a built behavior with raw overrides by passing a table that
	inherits the built values:

	```lua
	local Base = BehaviorBuilder.Sniper():Build()
	Solver:Fire(context, setmetatable({
	    DragCoefficient = 0.003,
	    DragModel       = "G7",
	}, { __index = Base }))
	```
	:::

	Builders are **reusable** — call `:Build()` multiple times to produce
	independent frozen tables from the same configuration.

	:::tip Presets
	Use [BehaviorBuilder.Sniper], [BehaviorBuilder.Grenade], or [BehaviorBuilder.Pistol]
	as a starting point, then chain additional overrides before calling `:Build()`.
	:::

	:::caution Build-time validation
	All validation is deferred to `:Build()` rather than per-setter. This means
	the builder never throws mid-chain — all errors are collected and reported
	together when `:Build()` is called. `:Build()` returns `nil` if any error
	is found.
	:::
]=]
local BehaviorBuilder = {}

-- ─── Constructor ─────────────────────────────────────────────────────────────

--[=[
	Creates a new builder pre-populated with all default values.

	Each call allocates a fresh `RaycastParams` and reads `workspace.Gravity`
	at construction time — builders never share mutable references with
	each other.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.new(): BehaviorBuilder end

-- ─── Namespace Openers ───────────────────────────────────────────────────────

--[=[
	Opens the Physics configuration group.

	Available setters: `:MaxDistance()`, `:MaxSpeed()`, `:MinSpeed()`,
	`:Gravity()`, `:Acceleration()`, `:RaycastParams()`, `:CastFunction()`,
	`:BulletMass()`. Call `:Done()` to return to the root builder.

	@return PhysicsBuilder
]=]
function BehaviorBuilder:Physics(): PhysicsBuilder end

--[=[
	Opens the Homing configuration group.

	Available setters: `:Filter()` (sets `CanHomeFunction`). Call `:Done()` to return.

	:::caution Homing config not fully covered by this builder
	`HomingPositionProvider`, `HomingStrength`, `HomingMaxDuration`, and
	`HomingAcquisitionRadius` must be set directly on the raw behavior table
	passed to `Solver:Fire()` — they are not available through this sub-builder.
	See [TypeDefinitions] for the full field list and [intro] for a homing
	usage example.
	:::

	@return HomingBuilder
]=]
function BehaviorBuilder:Homing(): HomingBuilder end

--[=[
	Opens the Pierce configuration group.

	Available setters: `:Filter()`, `:Max()`, `:SpeedThreshold()`,
	`:SpeedRetention()`, `:NormalBias()`, `:PenetrationDepth()`,
	`:PenetrationForce()`, `:ThicknessLimit()`. Call `:Done()` to return.

	:::caution
	Pierce and bounce are mutually exclusive per hit. Pierce is evaluated first.
	:::

	@return PierceBuilder
]=]
function BehaviorBuilder:Pierce(): PierceBuilder end

--[=[
	Opens the Bounce configuration group.

	Available setters: `:Filter()`, `:Max()`, `:SpeedThreshold()`,
	`:Restitution()`, `:MaterialRestitution()`, `:NormalPerturbation()`,
	`:ResetPierceOnBounce()`. Call `:Done()` to return.

	:::caution
	Pierce and bounce are mutually exclusive per hit. Bounce is only evaluated
	if pierce did not occur.
	:::

	@return BounceBuilder
]=]
function BehaviorBuilder:Bounce(): BounceBuilder end

--[=[
	Opens the HighFidelity configuration group.

	Available setters: `:SegmentSize()`, `:FrameBudget()`, `:AdaptiveScale()`,
	`:MinSegmentSize()`, `:MaxBouncesPerFrame()`. Call `:Done()` to return.

	@return HighFidelityBuilder
]=]
function BehaviorBuilder:HighFidelity(): HighFidelityBuilder end

--[=[
	Opens the CornerTrap configuration group.

	Available setters: `:TimeThreshold()`, `:PositionHistorySize()`,
	`:DisplacementThreshold()`, `:EMAAlpha()`, `:EMAThreshold()`,
	`:MinProgressPerBounce()`. Call `:Done()` to return.

	@return CornerTrapBuilder
]=]
function BehaviorBuilder:CornerTrap(): CornerTrapBuilder end

--[=[
	Opens the Cosmetic configuration group.

	Available setters: `:Template()`, `:Container()`, `:Provider()`.
	Call `:Done()` to return.

	:::caution
	`:Provider()` and `:Template()` are mutually exclusive. Provider takes
	priority if both are set, and a warning is logged.
	:::

	@return CosmeticBuilder
]=]
function BehaviorBuilder:Cosmetic(): CosmeticBuilder end

--[=[
	Opens the Debug configuration group.

	Available setters: `:Visualize()`. Call `:Done()` to return.

	@return DebugBuilder
]=]
function BehaviorBuilder:Debug(): DebugBuilder end

-- ─── Build ───────────────────────────────────────────────────────────────────

--[=[
	Validates the current configuration and returns a frozen `VetraBehavior`
	table ready to pass to [Vetra:Fire].

	All validation errors are collected and logged together so every problem
	is reported at once. Returns `nil` if any validation error is found.

	Does **not** consume the builder — call `:Build()` multiple times to
	produce independent frozen tables from the same configuration.

	```lua
	-- Produce two independent frozen tables from the same builder
	local RifleBehavior  = RifleBuilder:Build()
	local SniperBehavior = RifleBuilder:Physics():MaxDistance(2000):Done():Build()
	```

	@return VetraBehavior? -- Frozen behavior table, or nil if validation failed.
]=]
function BehaviorBuilder:Build(): VetraBehavior? end

-- ─── Presets ─────────────────────────────────────────────────────────────────

--[=[
	Returns a pre-configured builder for a high-velocity, long-range,
	pierce-capable, high-fidelity projectile. No bouncing.

	**Preset values:** MaxDistance 1500, MinSpeed 50, MaxPierceCount 3,
	PierceSpeedThreshold 200, PenetrationSpeedRetention 0.9, PierceNormalBias 0.8,
	HighFidelitySegmentSize 0.2, HighFidelityFrameBudget 2. Pierce filter
	returns `true` for all surfaces.

	Suitable for rifles and anti-materiel weapons. Chain additional overrides
	before calling `:Build()`.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Sniper(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a low-speed, gravity-affected,
	bouncy projectile with corner-trap detection tuned for tight-space
	ricochets. No piercing.

	**Preset values:** MaxDistance 400, MinSpeed 2, MaxBounces 6,
	BounceSpeedThreshold 10, Restitution 0.55, NormalPerturbation 0.05,
	CornerTimeThreshold 0.005, CornerDisplacementThreshold 0.3,
	HighFidelitySegmentSize 0.4. Bounce filter returns `true` for all surfaces.

	Suitable for thrown grenades or bouncing explosives.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Grenade(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a standard short-to-mid range
	projectile with single pierce and no bounce.

	**Preset values:** MaxDistance 300, MinSpeed 5, MaxPierceCount 1,
	PierceSpeedThreshold 80, PenetrationSpeedRetention 0.75. Pierce filter
	returns `true` for all surfaces.

	Suitable for handguns and SMGs.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Pistol(): BehaviorBuilder end

return BehaviorBuilder
