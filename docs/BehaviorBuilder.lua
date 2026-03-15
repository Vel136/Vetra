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
	        :Model(BehaviorBuilder.DragModel.G7)
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

	:::tip DragModel enum
	Use `BehaviorBuilder.DragModel` instead of raw strings. Typos on raw strings
	pass the type checker silently and only fail at `:Build()`. Enum access
	fails immediately at the indexing site:

	```lua
	-- Safe — typo is a nil-index warning immediately
	:Drag():Model(BehaviorBuilder.DragModel.G7):Done()

	-- Unsafe — "g7" silently passes strict mode, fails at :Build()
	:Drag():Model("g7"):Done()
	```

	Available values: `Linear`, `Quadratic`, `Exponential`, `G1`, `G2`, `G3`,
	`G4`, `G5`, `G6`, `G7`, `G8`, `GL`, `Custom`.
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

-- ─── DragModel Enum ──────────────────────────────────────────────────────────

--[=[
	@prop DragModel { [string]: DragModel }
	@within BehaviorBuilder

	Frozen enum table for the drag model field. Pass values from this table to
	`:Drag():Model()` and `:SpeedProfiles():Supersonic():DragModel()`.

	```lua
	:Drag()
	    :Model(BehaviorBuilder.DragModel.G7)
	:Done()
	```

	| Key | Description |
	|-----|-------------|
	| `Linear` | Deceleration ∝ speed |
	| `Quadratic` | Deceleration ∝ speed² (default) |
	| `Exponential` | Deceleration ∝ eˢᵖᵉᵉᵈ |
	| `G1` | Flat-base spitzer — general-purpose standard |
	| `G2` | Aberdeen J projectile — large-calibre / atypical shapes |
	| `G5` | Boat-tail spitzer — mid-range rifles |
	| `G6` | Semi-spitzer flat-base — shotgun slugs |
	| `G7` | Long boat-tail — modern long-range / sniper standard |
	| `G8` | Flat-base semi-spitzer — hollow points / pistols |
	| `GL` | Lead round ball — cannons / muskets / buckshot |
	| `Custom` | User-supplied `CustomMachTable` required |
]=]
BehaviorBuilder.DragModel = {}

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
	`:CustomMachTable()` is required when `Model = BehaviorBuilder.DragModel.Custom`.
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