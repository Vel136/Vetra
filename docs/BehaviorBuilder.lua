--[=[
	@class BehaviorBuilder

	Fluent typed configuration builder for [HybridSolver].

	Instead of constructing raw behavior tables by hand, chain namespace methods
	and call `:Build()` to produce a validated, frozen `HybridBehavior`.

	```lua
	local Behavior = BehaviorBuilder.new()
	    :Physics()
	        :MaxDistance(500)
	        :MinSpeed(5)
	    :Done()
	    :Bounce()
	        :Max(3)
	        :Restitution(0.7)
	        :Filter(function(ctx, result, vel)
	            return result.Instance:HasTag("Bouncy")
	        end)
	    :Done()
	    :Build()
	```

	**Namespace overview:**

	| Method | Configures |
	|--------|-----------|
	| `:Physics()` | MaxDistance, MinSpeed, Gravity, Acceleration, RaycastParams |
	| `:Pierce()` | Filter, Max, SpeedThreshold, SpeedRetention, NormalBias |
	| `:Bounce()` | Filter, Max, SpeedThreshold, Restitution, MaterialRestitution, NormalPerturbation |
	| `:HighFidelity()` | SegmentSize, FrameBudget, AdaptiveScale, MinSegmentSize, MaxBouncesPerFrame |
	| `:CornerTrap()` | TimeThreshold, NormalDotThreshold, DisplacementThreshold |
	| `:Cosmetic()` | Template, Container, Provider |
	| `:Debug()` | Visualize |

	Builders are **reusable** — call `:Build()` multiple times to produce independent
	frozen tables. This is useful for weapon archetypes where many bullets share
	the same base configuration.

	:::tip Presets
	Use [BehaviorBuilder.Sniper], [BehaviorBuilder.Grenade], or [BehaviorBuilder.Pistol]
	as a starting point, then chain additional overrides before calling `:Build()`.
	:::
]=]
local BehaviorBuilder = {}

-- ─── Constructor ─────────────────────────────────────────────────────────────

--[=[
	Creates a new builder pre-populated with all default values.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.new(): BehaviorBuilder end

-- ─── Namespace Openers ───────────────────────────────────────────────────────

--[=[
	Opens the Physics configuration group.

	Available setters: `:MaxDistance()`, `:MinSpeed()`, `:Gravity()`,
	`:Acceleration()`, `:RaycastParams()`. Call `:Done()` to return to the
	root builder.

	@return PhysicsBuilder
]=]
function BehaviorBuilder:Physics(): PhysicsBuilder end

--[=[
	Opens the Pierce configuration group.

	Available setters: `:Filter()`, `:Max()`, `:SpeedThreshold()`,
	`:SpeedRetention()`, `:NormalBias()`. Call `:Done()` to return.

	@return PierceBuilder
]=]
function BehaviorBuilder:Pierce(): PierceBuilder end

--[=[
	Opens the Bounce configuration group.

	Available setters: `:Filter()`, `:Max()`, `:SpeedThreshold()`,
	`:Restitution()`, `:MaterialRestitution()`, `:NormalPerturbation()`.
	Call `:Done()` to return.

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

	Available setters: `:TimeThreshold()`, `:NormalDotThreshold()`,
	`:DisplacementThreshold()`. Call `:Done()` to return.

	@return CornerTrapBuilder
]=]
function BehaviorBuilder:CornerTrap(): CornerTrapBuilder end

--[=[
	Opens the Cosmetic configuration group.

	Available setters: `:Template()`, `:Container()`, `:Provider()`.
	Call `:Done()` to return.

	@return CosmeticBuilder
]=]
function BehaviorBuilder:Cosmetic(): CosmeticBuilder end

--[=[
	Opens the Debug configuration group.

	Available setters: `:Visualize()`. Call `:Done()` to return.

	@return DebugBuilder
]=]
function BehaviorBuilder:Debug(): DebugBuilder end

--[=[
	Validates the current configuration and returns a frozen `HybridBehavior`
	table ready to pass to [HybridSolver:Fire].

	All validation errors are collected and logged together so every problem is
	reported at once. Returns `nil` if any validation error is found.

	Does **not** consume the builder — call `:Build()` multiple times to produce
	independent frozen tables from the same configuration.

	@return HybridBehavior? -- Frozen behavior table, or nil if validation failed.
]=]
function BehaviorBuilder:Build(): HybridBehavior? end

-- ─── Presets ─────────────────────────────────────────────────────────────────

--[=[
	Returns a pre-configured builder for a high-velocity, long-range,
	pierce-capable projectile. No bouncing.

	Suitable for rifles and anti-materiel weapons. Further chain methods
	before calling `:Build()` to customise.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Sniper(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a low-speed, gravity-affected,
	bouncy projectile. No piercing.

	Suitable for thrown grenades or bouncing explosives.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Grenade(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a standard short-to-mid range
	projectile with single pierce and no bounce.

	Suitable for handguns and SMGs.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Pistol(): BehaviorBuilder end

return BehaviorBuilder
