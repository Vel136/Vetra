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
	    :Drag()
	        :Coefficient(0.003)
	        :Model(Vetra.Enums.DragModel.G7)
	    :Done()
	    :Build()
	```

	**Namespace overview:**

	| Method | Configures |
	|--------|------------|
	| `:Physics()` | MaxDistance, MaxSpeed, MinSpeed, Gravity, Acceleration, RaycastParams, CastFunction, BulletMass |
	| `:Homing()` | Filter, PositionProvider, Strength, MaxDuration, AcquisitionRadius |
	| `:Pierce()` | Filter, Max, SpeedThreshold, SpeedRetention, NormalBias, PenetrationDepth, PenetrationForce, ThicknessLimit |
	| `:Bounce()` | Filter, Max, SpeedThreshold, Restitution, MaterialRestitution, NormalPerturbation, ResetPierceOnBounce |
	| `:HighFidelity()` | SegmentSize, FrameBudget, AdaptiveScale, MinSegmentSize, MaxBouncesPerFrame |
	| `:CornerTrap()` | TimeThreshold, PositionHistorySize, DisplacementThreshold, EMAAlpha, EMAThreshold, MinProgressPerBounce |
	| `:Cosmetic()` | Template, Container, Provider |
	| `:Debug()` | Visualize |
	| `:Drag()` | Coefficient, Model, SegmentInterval, CustomMachTable |
	| `:Wind()` | Response |
	| `:Magnus()` | SpinVector, Coefficient, SpinDecayRate |
	| `:GyroDrift()` | Rate, Axis |
	| `:Tumble()` | SpeedThreshold, DragMultiplier, LateralStrength, OnPierce, RecoverySpeed |
	| `:Fragmentation()` | OnPierce, Count, Deviation |
	| `:SpeedProfiles()` | Thresholds, `:Supersonic()` → profile, `:Subsonic()` → profile |
	| `:Trajectory()` | Provider |
	| `:LOD()` | Distance |
	| `:BatchTravel()` | Root-level boolean toggle — no sub-builder |
	| `:Clone()` | Returns an independent copy of this builder |
	| `:Impose(other)` | Copies only the explicitly-set fields from `other` onto self |
	| `:Merge(a, b, ...)` | Clone + impose multiple modifiers, returns new builder |
	| `:When(cond, fn)` | Conditionally apply a block without breaking the chain |
	| `BehaviorBuilder.Inherit(frozen)` | Create a builder from a frozen `VetraBehavior` table |

	:::tip DragModel enum
	Use `Vetra.Enums.DragModel` when passing a drag model to `:Drag():Model()`.
	A wrong integer is silently incorrect; an invalid enum key is a nil-index
	warning immediately at the call site:

	```lua
	:Drag():Model(Vetra.Enums.DragModel.G7):Done()
	```

	See [Enums.DragModel] for the full value table and descriptions.
	:::

	Builders are **reusable** — call `:Build()` multiple times to produce
	independent frozen tables from the same configuration.

	```lua
	-- Produce two independent frozen tables from the same builder
	local RifleBehavior  = RifleBuilder:Build()
	local SniperBehavior = RifleBuilder:Physics():MaxDistance(2000):Done():Build()
	```

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

	Available setters: `:Filter()`, `:PositionProvider()`, `:Strength()`,
	`:MaxDuration()`, `:AcquisitionRadius()`. Call `:Done()` to return.

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

--[=[
	Opens the Drag configuration group.

	Available setters: `:Coefficient()`, `:Model()`, `:SegmentInterval()`,
	`:CustomMachTable()`. Call `:Done()` to return.

	:::caution
	`:CustomMachTable()` is required when `Model = Vetra.Enums.DragModel.Custom`.
	`:Build()` returns `nil` if it is omitted.
	:::

	@return DragBuilder
]=]
function BehaviorBuilder:Drag(): DragBuilder end

--[=[
	Opens the Wind configuration group.

	Available setters: `:Response()`. Call `:Done()` to return.

	`Response` is a multiplier on the solver's global wind vector set via
	`Vetra:SetWind`. `1.0` = fully affected, `0.0` = immune.

	@return WindBuilder
]=]
function BehaviorBuilder:Wind(): WindBuilder end

--[=[
	Opens the Magnus configuration group.

	Available setters: `:SpinVector()`, `:Coefficient()`, `:SpinDecayRate()`.
	Call `:Done()` to return.

	:::caution Start small
	`MagnusCoefficient` is highly sensitive. Start at `0.00005` and increase
	incrementally — `0.0001` already produces visible drift at typical speeds.
	:::

	@return MagnusBuilder
]=]
function BehaviorBuilder:Magnus(): MagnusBuilder end

--[=[
	Opens the GyroDrift configuration group.

	Available setters: `:Rate()`, `:Axis()`. Call `:Done()` to return.

	Setting `:Rate()` enables drift. `Axis` defaults to world UP
	(right-hand rifling) when not set.

	@return GyroDriftBuilder
]=]
function BehaviorBuilder:GyroDrift(): GyroDriftBuilder end

--[=[
	Opens the Tumble configuration group.

	Available setters: `:SpeedThreshold()`, `:DragMultiplier()`,
	`:LateralStrength()`, `:OnPierce()`, `:RecoverySpeed()`.
	Call `:Done()` to return.

	:::caution
	`:RecoverySpeed()` must be greater than `:SpeedThreshold()` if both are
	set. `:Build()` enforces this constraint.
	:::

	@return TumbleBuilder
]=]
function BehaviorBuilder:Tumble(): TumbleBuilder end

--[=[
	Opens the Fragmentation configuration group.

	Available setters: `:OnPierce()`, `:Count()`, `:Deviation()`.
	Call `:Done()` to return.

	Each fragment is a fully live cast. It fires `OnHit` independently and
	can bounce, pierce, and apply drag if its inherited behavior includes those.

	@return FragmentationBuilder
]=]
function BehaviorBuilder:Fragmentation(): FragmentationBuilder end

--[=[
	Opens the SpeedProfiles configuration group.

	Available setters: `:Thresholds()`, `:Supersonic()`, `:Subsonic()`.
	`:Supersonic()` and `:Subsonic()` each return a [SpeedProfileBuilder].
	Call `:Done()` on each profile builder to return to [SpeedProfilesBuilder],
	then `:Done()` again to return to the root builder.

	```lua
	:SpeedProfiles()
	    :Thresholds({ 343 })
	    :Supersonic()
	        :DragCoefficient(0.0015)
	    :Done()
	    :Subsonic()
	        :DragCoefficient(0.004)
	        :NormalPerturbation(0.06)
	    :Done()
	:Done()
	```

	@return SpeedProfilesBuilder
]=]
function BehaviorBuilder:SpeedProfiles(): SpeedProfilesBuilder end

--[=[
	Opens the Trajectory configuration group.

	Available setters: `:Provider()`. Call `:Done()` to return.

	`Provider` overrides bullet position each frame. Return `nil` from the
	callback to end the override and terminate the cast.
	Signature: `(elapsed: number) -> Vector3?`

	@return TrajectoryBuilder
]=]
function BehaviorBuilder:Trajectory(): TrajectoryBuilder end

--[=[
	Opens the LOD configuration group.

	Available setters: `:Distance()`. Call `:Done()` to return.

	Bullets beyond `Distance` studs from the LOD origin step at reduced
	frequency. `0` disables LOD for this cast.

	@return LODBuilder
]=]
function BehaviorBuilder:LOD(): LODBuilder end

--[=[
	Enables or disables batch travel for this cast. When `true`, travel
	events go to `OnTravelBatch` instead of individual `OnTravel` fires.

	Default: `false`

	@param value boolean
	@return BehaviorBuilder
]=]
function BehaviorBuilder:BatchTravel(value: boolean): BehaviorBuilder end

-- ─── Clone / Impose ──────────────────────────────────────────────────────────

--[=[
	Returns an independent `BehaviorBuilder` whose configuration and dirty set
	are deep copies of this builder's. Changes to either builder after cloning
	do not affect the other.

	Use this to derive variants from a shared archetype without mutating it:

	```lua
	local Base    = BehaviorBuilder.Sniper()
	local Variant = Base:Clone():Physics():MaxDistance(2000):Done():Build()
	-- Base is unchanged; Variant has MaxDistance = 2000
	```

	`:Clone()` is the correct way to branch from a preset. Calling setters
	directly on the preset builder mutates it for all future `:Build()` calls,
	which is rarely what you want.

	@return BehaviorBuilder -- Independent copy with cloned config and dirty set.
]=]
function BehaviorBuilder:Clone(): BehaviorBuilder end

--[=[
	Copies only the **explicitly-set** fields from `other` onto this builder.

	"Explicitly set" means a field whose setter was called on `other` — tracked
	internally via dirty flags. Fields sitting at their defaults on `other` are
	never copied, so a modifier cannot silently clobber values it never touched.

	Returns `self` for chaining. Does not mutate `other`.

	```lua
	-- Define a reusable modifier — only two fields are dirty.
	local APMod = BehaviorBuilder.new()
	    :Pierce()
	        :Max(5)
	        :SpeedRetention(0.95)
	    :Done()

	-- Apply to any base without touching MaxDistance, HighFidelity, etc.
	local APSniper = BehaviorBuilder.Sniper():Clone():Impose(APMod):Build()
	local APPistol = BehaviorBuilder.Pistol():Clone():Impose(APMod):Build()
	```

	Modifiers stack cleanly — each `:Impose()` only writes its own dirty set:

	```lua
	local HollowMod = BehaviorBuilder.new()
	    :Tumble():OnPierce(true):DragMultiplier(5):Done()

	local APHollow = BehaviorBuilder.Sniper():Clone()
	    :Impose(APMod)
	    :Impose(HollowMod)
	    :Build()
	```

	:::caution Last write wins
	If two modifiers set the same field, the second `:Impose()` wins.
	There is no merge strategy for conflicting values — ordering is the
	caller's responsibility.
	:::

	@param other BehaviorBuilder -- The modifier to apply. Must be a BehaviorBuilder.
	@return BehaviorBuilder -- self, for chaining.
]=]
function BehaviorBuilder:Impose(other: BehaviorBuilder): BehaviorBuilder end

-- ─── Merge / Inherit / When ──────────────────────────────────────────────────

--[=[
	Returns a new builder that is a clone of `self` with all provided modifiers
	applied in order via `:Impose()`. Neither `self` nor any modifier is mutated.

	Equivalent to `self:Clone():Impose(a):Impose(b):...`, but reads more
	naturally when combining a preset with modifiers at the call site.

	```lua
	local Behavior = BehaviorBuilder.Sniper()
	    :Merge(APMod, HollowMod)
	    :Build()
	```

	Because `:Merge()` returns a builder, you can continue chaining after it:

	```lua
	local Behavior = BehaviorBuilder.Sniper()
	    :Merge(APMod)
	    :Physics():MaxDistance(2000):Done()   -- applied after the merge
	    :Build()
	```

	@param ... BehaviorBuilder -- One or more modifier builders to apply in order.
	@return BehaviorBuilder -- New independent builder with all modifiers imposed.
]=]
function BehaviorBuilder:Merge(...: BehaviorBuilder): BehaviorBuilder end

--[=[
	Creates a new `BehaviorBuilder` pre-populated from a frozen `VetraBehavior`
	table, with every field marked dirty.

	This is the inverse of `:Build()` — it lets you round-trip a frozen behavior
	back into a mutable builder so you can tweak individual fields without
	reconstructing from scratch.

	Because every field is marked dirty, the resulting builder works correctly
	with `:Impose()` and `:Merge()` — all its values are treated as intentional
	rather than defaults.

	```lua
	-- Received from a registry, config file, or another module
	local existing = BehaviorRegistry:Get("Sniper")

	-- Round-trip: unfreeze → tweak → refreeze
	local tweaked = BehaviorBuilder.Inherit(existing)
	    :Physics():MaxDistance(2000):Done()
	    :Build()
	```

	Note that `BehaviorBuilder.Inherit` is a **static constructor**, not an
	instance method — call it on the class, not on a builder instance.

	@param frozen VetraBehavior -- A frozen behavior table produced by `:Build()`.
	@return BehaviorBuilder -- Mutable builder pre-populated from the frozen table.
]=]
function BehaviorBuilder.Inherit(frozen: VetraBehavior): BehaviorBuilder end

--[=[
	Conditionally applies a block of builder calls without breaking the fluent
	chain. If `condition` is falsy the builder is returned unchanged.

	The callback receives `self` and is called for its side effects — it should
	not return a value.

	```lua
	local Behavior = BehaviorBuilder.Sniper()
	    :When(isRaining,   function(b) b:Wind():Response(1.5):Done() end)
	    :When(isHeavyAmmo, function(b) b:Pierce():Max(5):Done() end)
	    :When(isDebug,     function(b) b:Debug():Visualize(true):Done() end)
	    :Build()
	```

	Without `:When()`, each conditional would require breaking out of the chain:

	```lua
	local b = BehaviorBuilder.Sniper()
	if isRaining   then b:Wind():Response(1.5):Done() end
	if isHeavyAmmo then b:Pierce():Max(5):Done() end
	if isDebug     then b:Debug():Visualize(true):Done() end
	local Behavior = b:Build()
	```

	Both are equivalent. `:When()` is purely ergonomic — it keeps construction
	as a single coherent declaration.

	@param condition any -- Truthy value to gate the block. Falsy = skip.
	@param fn (builder: BehaviorBuilder) -> () -- Block to apply if condition is truthy.
	@return BehaviorBuilder -- self, for chaining.
]=]
function BehaviorBuilder:When(condition: any, fn: (BehaviorBuilder) -> ()): BehaviorBuilder end

-- ─── Build ───────────────────────────────────────────────────────────────────

--[=[
	Validates the current configuration and returns a frozen `VetraBehavior`
	table ready to pass to [Vetra:Fire].

	All validation errors are collected and logged together so every problem
	is reported at once. Returns `nil` if any validation error is found.

	Does **not** consume the builder — call `:Build()` multiple times to
	produce independent frozen tables from the same configuration.

	```lua
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
	HighFidelitySegmentSize 0.2, HighFidelityFrameBudget 2.

	Suitable for rifles and anti-materiel weapons.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Sniper(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a low-speed, gravity-affected,
	bouncy projectile with corner-trap detection tuned for tight-space ricochets.

	**Preset values:** MaxDistance 400, MinSpeed 2, MaxBounces 6,
	BounceSpeedThreshold 10, Restitution 0.55, NormalPerturbation 0.05,
	CornerTimeThreshold 0.005, CornerDisplacementThreshold 0.3,
	HighFidelitySegmentSize 0.4.

	Suitable for thrown grenades or bouncing explosives.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Grenade(): BehaviorBuilder end

--[=[
	Returns a pre-configured builder for a standard short-to-mid range
	projectile with single pierce and no bounce.

	**Preset values:** MaxDistance 300, MinSpeed 5, MaxPierceCount 1,
	PierceSpeedThreshold 80, PenetrationSpeedRetention 0.75.

	Suitable for handguns and SMGs.

	@return BehaviorBuilder
]=]
function BehaviorBuilder.Pistol(): BehaviorBuilder end

return BehaviorBuilder