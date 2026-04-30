--[=[
	@class Vetra

	Analytic-trajectory projectile simulation engine for Roblox.

	Vetra manages all active in-flight projectiles. Every frame it advances
	each cast using the exact kinematic formula `P(t) = Origin + V₀t + ½At²`,
	raycasts between the previous and current position, and resolves hits as
	pierce, bounce, or terminal impact.

	Signals are instance-level, connect once at initialisation and receive
	events from every cast fired through that solver. The [BulletContext]
	argument on every signal lets you identify which bullet fired the event
	and dispatch accordingly.

	```lua
	local Vetra       = require(ReplicatedStorage.Vetra)
	local BulletContext = Vetra.BulletContext

	local Solver  = Vetra.new()
	local Signals = Solver:GetSignals()

	Signals.OnHit:Connect(function(context, result, velocity)
	    -- handle impact
	end)

	local Behavior = Vetra.BehaviorBuilder.Sniper():Build()

	local context = BulletContext.new({
	    Origin    = muzzlePosition,
	    Direction = direction,
	    Speed     = 300,
	})

	Solver:Fire(context, Behavior)
	```
]=]
local Vetra = {}

-- ─── Re-exports ───────────────────────────────────────────────────────────────

--[=[
	@prop BehaviorBuilder BehaviorBuilder
	@within Vetra

	Re-export of the [BehaviorBuilder] module. Access via `Vetra.BehaviorBuilder`
	so consumers only need one require.
]=]

--[=[
	@prop BulletContext BulletContext
	@within Vetra

	Re-export of the [BulletContext] module. Access via `Vetra.BulletContext`
	so consumers only need one require.
]=]

--[=[
	@prop VetraNet VetraNet
	@within Vetra

	Re-export of the [VetraNet] module. Access via `Vetra.VetraNet`.
]=]

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[=[
	Creates a new serial Vetra solver and connects the per-frame simulation
	loop to the appropriate RunService event (`Heartbeat` on the server,
	`RenderStepped` on the client).

	```lua
	local Solver = Vetra.new()
	```

	**FactoryConfig fields (all optional):**

	| Field | Type | Description |
	|-------|------|-------------|
	| `SpatialPartition` | `SpatialPartitionConfig?` | LOD tier configuration. See [TypeDefinitions]. |

	@param FactoryConfig { SpatialPartition: SpatialPartitionConfig? }?
	@return Vetra
]=]
function Vetra.new(FactoryConfig: { SpatialPartition: any? }?): Vetra end

--[=[
	Creates a new **parallel** Vetra solver. Physics computation, raycasts,
	drag, Magnus, homing, bounce math, corner-trap detection, runs across `N`
	Roblox Actors on multiple cores via Parallel Luau.

	Signal firing, user callbacks (`CanPierce` / `CanBounce` / `HomingPositionProvider`),
	and cosmetic updates are flushed on the main thread after each parallel pass.

	The returned solver exposes the **identical API** as `Vetra.new()`.
	`Fire()`, `SetWind()`, `SetLODOrigin()`, `SetInterestPoints()`,
	`GetSignals()`, `WithValidator`, and `Destroy()` all behave the same way.

	```lua
	local Solver = Vetra.newParallel({
	    ShardCount = 6,
	    SpatialPartition = { FallbackTier = "COLD" },
	})

	Solver:GetSignals().OnHit:Connect(function(context, result, vel)
	    -- identical handler
	end)

	Solver:Fire(context, Behavior)
	```

	:::caution CastFunction not supported
	`CastFunction` overrides in `VetraBehavior` are **silently ignored** by the
	parallel solver, functions cannot cross Actor boundaries via message
	serialization. Use `Vetra.new()` if you need a custom cast function.
	:::

	:::caution Fallback on failure
	If the internal Actor coordinator fails to construct, `newParallel` falls
	back to a serial solver automatically and logs an error. The returned solver
	is still fully functional, you cannot distinguish the fallback from a
	normal serial solver at the call site. Check output logs if parallel
	performance is expected but not observed.
	:::

	:::tip Benchmark Guidance
	Parallel overhead breaks even around 50–100 active bullets.
	Below that threshold `Vetra.new()` may be faster.
	Above ~200 bullets with physics features enabled (Magnus, homing,
	high-fidelity resimulation) the parallel version scales significantly
	better because raycast cost dominates.
	:::

	**Config fields (all optional, inherits all `Vetra.new()` fields):**

	| Field | Type | Default | Description |
	|-------|------|---------|-------------|
	| `ShardCount` | `number` | `4` | Number of Actor shards. Tune to your server's core count. |
	| `ActorParent` | `Instance` | `workspace` | Where to parent Actor instances. |

	@param FactoryConfig { ShardCount: number?, ActorParent: Instance?, SpatialPartition: SpatialPartitionConfig? }?
	@return Vetra
]=]
function Vetra.newParallel(FactoryConfig: any?): Vetra end

--[=[
	Attaches a server-side [HitValidator] to an existing solver instance.
	Must be called on the **server only**, returns `Solver` unchanged on the
	client so the same setup code can run on both sides safely.

	Once attached, the solver records every `Fire()` trajectory and validates
	incoming hit reports against reconstructed physics. Invalid hits are silently
	rejected and logged.

	```lua
	-- Server
	local Solver = Vetra.WithValidator(Vetra.new(), {
	    MaxOriginTolerance = 20,
	    PositionTolerance  = 15,
	    VelocityTolerance  = 80,
	    TimeTolerance      = 0.15,
	})
	```

	**ValidatorConfig fields (all optional):**

	| Field | Type | Default | Description |
	|-------|------|---------|-------------|
	| `MaxOriginTolerance` | `number` | `15` | Max studs between client-reported and server-reconstructed fire origin. |
	| `PositionTolerance` | `number` | `10` | Max studs between client-reported and reconstructed hit position. |
	| `VelocityTolerance` | `number` | `50` | Max studs/s error on reconstructed velocity at hit time. |
	| `TimeTolerance` | `number` | `0.1` | Max seconds of timing error allowed for hit timestamp. |

	@server
	@param Solver Vetra -- The solver to attach the validator to.
	@param ValidatorConfig { MaxOriginTolerance: number?, PositionTolerance: number?, VelocityTolerance: number?, TimeTolerance: number? }?
	@return Vetra -- The same solver instance, now with validation enabled.
]=]
function Vetra.WithValidator(Solver: Vetra, ValidatorConfig: any?): Vetra end

-- ─── Methods ─────────────────────────────────────────────────────────────────

--[=[
	Creates and registers a new in-flight projectile cast.

	`context` must have non-nil, finite `Origin` (Vector3), `Direction` (Vector3),
	and `Speed` (number) fields. Any field omitted from `behavior` falls back to
	the built-in defaults documented in [TypeDefinitions].

	After `Fire` returns the cast is live and will be advanced every frame until
	it hits something, expires by distance or speed, or is stopped via
	`context:Terminate()`.

	Returns `nil` only if `context` fails the basic type validation (`Origin`,
	`Direction`, or `Speed` is missing or the wrong type). Behavior validation
	errors are caught by [BehaviorBuilder:Build] before `Fire` is called.

	:::caution Parallel solver
	`CastFunction` in `behavior` is ignored when using `Vetra.newParallel()`.
	All other behavior fields work identically.
	:::

	@param context BulletContext -- The public bullet object weapon code interacts with.
	@param behavior VetraBehavior? -- Optional behavior overrides. Omitted fields use defaults.
	@return VetraCast? -- The internal cast object, or nil if context validation failed.
]=]
function Vetra:Fire(context: BulletContext, behavior: VetraBehavior?): VetraCast? end

--[=[
	Returns the instance's Signals table.

	Connect to these once during weapon initialisation. Every signal passes
	[BulletContext] as its first argument so you can identify the bullet and
	access its `UserData`.

	**Signal contracts:**

	| Signal | Arguments | Notes |
	|--------|-----------|-------|
	| `OnHit` | `context`, `result: RaycastResult?`, `velocity: Vector3` | `result` is nil on distance/speed expiry. |
	| `OnTravel` | `context`, `position: Vector3`, `velocity: Vector3` | Fires every frame. Handler **must not yield**. |
	| `OnTravelBatch` | `context[]` | Fires once per frame with all travelling casts. Safer for batch processing. |
	| `OnPierce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `pierceCount: number` | Fired after a successful pierce. |
	| `OnBounce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `bounceCount: number` | Fired after a confirmed bounce. |
	| `OnPreBounce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `mutate: MutateFn` | Before reflection math. Call `mutate(newNormal, newInVelocity)` to override. |
	| `OnMidBounce` | `context`, `result: RaycastResult`, `outVelocity: Vector3`, `mutate: MutateFn` | After reflection, before corner-trap check. Call `mutate(newOutVelocity, newRestitution, newNormalPerturbation)` to override. |
	| `OnPrePierce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `mutate: MutateFn` | Before pierce resolution. Call `mutate(newEntryVelocity, maxPierceOverride)` to override. |
	| `OnMidPierce` | `context`, `result: RaycastResult`, `entryVelocity: Vector3`, `mutate: MutateFn` | After exit-point raycast. Call `mutate(newSpeedRetention, newExitVelocity)` to override. |
	| `OnTerminated` | `context` | Fires on any termination cause. |
	| `OnPreTermination` | `context`, `reason: TerminationReason`, `mutate: MutateFn` | Before cleanup. Call `mutate(cancelled: boolean, newReason?)` to cancel. Per-reason 3-strike limit applies. |
	| `OnSegmentOpen` | `context`, `trajectory: CastTrajectory` | Fires when a new parabolic arc begins (fire, bounce, velocity change). |
	| `OnBranchSpawned` | `parentContext`, `childContext` | Fires when fragmentation spawns a child bullet. |
	| `OnSpeedThresholdCrossed` | `context`, `threshold: number`, `velocity: Vector3` | Each time the bullet crosses a registered `SpeedThresholds` value. |
	| `OnHomingDisengaged` | `context`, `reason: string` | Fires when homing ends (timeout, filter returned false, provider returned nil, etc.). |
	| `OnTumbleBegin` | `context`, `velocity: Vector3` | Fires when the bullet enters tumble mode. |
	| `OnTumbleEnd` | `context`, `velocity: Vector3` | Fires when the bullet recovers from tumble. |

	**Hook signals (`OnPreBounce`, `OnMidBounce`, `OnPrePierce`, `OnMidPierce`, `OnPreTermination`):**
	The `mutate` callback is only active during the **synchronous** signal handler. Do not yield in
	these handlers, calling `mutate` after the handler returns logs a warning and has no effect.

	**`OnPreTermination` 3-strike rule:**
	Cancellation is tracked per `reason` string. After 3 consecutive cancels for the same reason the
	bullet is force-terminated regardless. The counter resets to zero on any non-cancelled termination.

	**`OnTravel` vs `OnTravelBatch`:**
	These are mutually exclusive per cast, controlled by `BatchTravel` on the behavior. When
	`BatchTravel = false` (default), `OnTravel` fires once per step per cast. When `BatchTravel = true`,
	travel events accumulate and `OnTravelBatch` fires once per frame with all of them as a table.
	Both use the same `Fire` path — neither provides error isolation. All signals use `:Fire()`, so
	errors in handlers propagate to the caller. Do not use `ConnectAsync` on signals where you mutate
	cast state — arguments are passed by reference, not copied.

	```lua
	local Signals = Solver:GetSignals()

	Signals.OnHit:Connect(function(context, result, velocity)
	    if result then
	        -- surface impact
	    else
	        -- distance/speed expiry
	    end
	end)

	Signals.OnBounce:Connect(function(context, result, velocity, bounceCount)
	    print("Bounce #" .. bounceCount)
	end)

	Signals.OnPreBounce:Connect(function(context, result, velocity, mutate)
	    -- Force flat-floor reflection
	    mutate(Vector3.new(0, 1, 0), nil)
	end)

	Signals.OnPreTermination:Connect(function(context, reason, mutate)
	    if reason == "hit" and context.UserData.HasShield then
	        mutate(true, nil)  -- cancel this death (up to 3 times per reason)
	    end
	end)
	```

	@return { OnHit: Signal, OnTravel: Signal, OnTravelBatch: Signal, OnPierce: Signal, OnBounce: Signal, OnPreBounce: Signal, OnMidBounce: Signal, OnPrePierce: Signal, OnMidPierce: Signal, OnTerminated: Signal, OnPreTermination: Signal, OnSegmentOpen: Signal, OnBranchSpawned: Signal, OnSpeedThresholdCrossed: Signal, OnHomingDisengaged: Signal, OnTumbleBegin: Signal, OnTumbleEnd: Signal }
]=]
function Vetra:GetSignals() end

--[=[
	Sets the global wind vector for this solver. Applied to all bullets that
	have a non-zero `WindResponse` in their behavior. Does not retroactively
	affect bullets already in flight.

	Per-bullet sensitivity is controlled by `WindResponse` in the behavior
	(`1.0` = full effect, `0.0` = ignore wind entirely).

	```lua
	-- 10 studs/s eastward wind
	Solver:SetWind(Vector3.new(10, 0, 0))

	-- Calm
	Solver:SetWind(Vector3.zero)
	```

	@param WindVector Vector3
]=]
function Vetra:SetWind(WindVector: Vector3) end

--[=[
	Sets the LOD origin point for this solver. Bullets farther from this point
	than their configured `LODDistance` are stepped at a reduced frequency,
	reducing raycast cost.

	Call this every frame with the relevant camera position (client) or a
	central interest point (server):

	```lua
	RunService.RenderStepped:Connect(function()
	    Solver:SetLODOrigin(workspace.CurrentCamera.CFrame.Position)
	end)
	```

	Pass `nil` to disable LOD, all casts are stepped at full frequency.

	@param LODOrigin Vector3?
]=]
function Vetra:SetLODOrigin(LODOrigin: Vector3?) end

--[=[
	Replaces the set of interest points used by the spatial partition to
	classify bullet LOD tiers. Call this every frame with the current
	positions of all relevant entities (players, objectives, etc.).

	```lua
	RunService.Heartbeat:Connect(function()
	    local Points = {}
	    for _, Player in Players:GetPlayers() do
	        local Character = Player.Character
	        if Character then
	            local Root = Character:FindFirstChild("HumanoidRootPart")
	            if Root then
	                Points[#Points + 1] = Root.Position
	            end
	        end
	    end
	    Solver:SetInterestPoints(Points)
	end)
	```

	Passing an empty table puts all bullets in the lowest LOD tier.

	@param Points { Vector3 }
]=]
function Vetra:SetInterestPoints(Points: { Vector3 }) end

--[=[
	Configures the Coriolis deflection effect for this solver. This is a
	**solver-level environment property**, it is not configurable per-bullet
	via the behavior table. All bullets fired through this solver are affected
	equally.

	The Ω vector is precomputed here and cached on the solver so no
	trigonometry runs in the per-frame step loop.

	```lua
	-- Arctic map, strong northern deflection
	Solver:SetCoriolisConfig(75, 1200)

	-- Equatorial map, purely horizontal east/west drift
	Solver:SetCoriolisConfig(0, 800)

	-- Disable entirely (default)
	Solver:SetCoriolisConfig(45, 0)
	```

	**Scale reference:**

	| Scale | Effect |
	|-------|--------|
	| `0` | Disabled, zero overhead (default) |
	| `500` | Subtle; detectable only at long range |
	| `1000` | Clearly perceptible at ~300 studs |
	| `3000` | Strong, map-defining mechanic |

	@param latitude number -- Geographic latitude in degrees. Positive = northern hemisphere, negative = southern. `0` = equator, `±90` = poles.
	@param scale number -- Exaggeration multiplier on Earth's actual ω. `0` = disabled.
]=]
function Vetra:SetCoriolisConfig(latitude: number, scale: number) end

--[=[
	Tears down this solver instance completely. After this call the instance
	is inert, its frame loop is disconnected, all live casts are terminated,
	all signals are destroyed, and all internal state is cleared.

	`OnTerminated` fires for every live cast during shutdown, giving consumers
	a final cleanup callback consistent with normal cast expiry.

	:::danger
	Calling any method on the instance after `Destroy()` returns is undefined
	behaviour. The metatable is stripped and the table is frozen, all reads
	and writes will error immediately at the call site.
	:::

	:::caution
	`Destroy()` is not safe to call twice. Guard against this with a flag on
	your own code if double-destruction is possible at your call sites.
	:::
]=]
function Vetra:Destroy() end

return Vetra
