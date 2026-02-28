--[=[
	@class BulletContext

	The public-facing object that weapon code interacts with for every in-flight projectile.

	Create one before firing, pass it to [HybridSolver:Fire], then use the module-level
	signals to react to events. The context is passed as the first argument on every signal
	so you can identify the bullet and read its current state.

	```lua
	local context = BulletContext.new({
	    Origin    = muzzlePosition,
	    Direction = direction,
	    Speed     = 200,
	    SolverData = {},
	})

	Solver:Fire(context, Behavior)
	```

	:::tip UserData
	Attach weapon-specific metadata (shooter UserId, damage value, hit-group flags, etc.)
	via `context.UserData` before calling `Fire`. This table is passed unchanged on every
	signal emission.
	:::
]=]
local BulletContext = {}

-- ─── Properties ──────────────────────────────────────────────────────────────

--[=[
	@prop Id number
	@within BulletContext
	@readonly

	Auto-incrementing unique identifier assigned at construction time.
	Use this to distinguish bullets in signal handlers without storing separate references.
]=]

--[=[
	@prop Origin Vector3
	@within BulletContext
	@readonly

	World-space muzzle position at the moment the bullet was fired. Never changes.
]=]

--[=[
	@prop Direction Vector3
	@within BulletContext
	@readonly

	Unit direction vector the bullet was fired along. Never changes.
]=]

--[=[
	@prop Speed number
	@within BulletContext
	@readonly

	Initial speed in studs per second. The bullet's actual speed decreases over
	time due to bounces (restitution) and pierces (speed retention).
]=]

--[=[
	@prop StartTime number
	@within BulletContext
	@readonly

	`os.clock()` timestamp at construction. Use with [BulletContext:GetLifetime] to
	compute bullet age without storing the time yourself.
]=]

--[=[
	@prop Position Vector3?
	@within BulletContext
	@readonly

	Current world-space position. Updated every frame by the solver. `nil` until the
	first simulation step.
]=]

--[=[
	@prop Velocity Vector3
	@within BulletContext
	@readonly

	Current velocity vector in studs per second. Updated every frame by the solver.
	The magnitude of this vector is the current speed.
]=]

--[=[
	@prop Alive boolean
	@within BulletContext
	@readonly

	`true` while the cast is being simulated. Set to `false` by [BulletContext:Terminate]
	or automatically by the solver on hit, distance expiry, or speed expiry.
]=]

--[=[
	@prop Length number
	@within BulletContext
	@readonly

	Cumulative distance the bullet has travelled along its actual ray path, in studs.
]=]

--[=[
	@prop UserData {[any]: any}
	@within BulletContext

	Free-form table for attaching cast-specific metadata (shooter UserId, weapon type,
	damage value, etc.). Surfaced on every signal emission — read it in your handlers
	to route events without maintaining a parallel lookup.

	```lua
	context.UserData.Damage   = 45
	context.UserData.ShooterId = Players.LocalPlayer.UserId
	```
]=]

-- ─── Constructor ─────────────────────────────────────────────────────────────

--[=[
	Creates a new BulletContext.

	`Origin`, `Direction`, and `Speed` are required. `Callbacks` and `SolverData`
	are optional and primarily used internally.

	@param config BulletContextConfig
	@return BulletContext
]=]
function BulletContext.new(config: BulletContextConfig): BulletContext end

-- ─── Methods ─────────────────────────────────────────────────────────────────

--[=[
	Returns whether the bullet is still alive and being simulated.

	@return boolean
]=]
function BulletContext:IsAlive(): boolean end

--[=[
	Returns how many seconds have elapsed since the bullet was created.

	@return number -- Age in seconds.
]=]
function BulletContext:GetLifetime(): number end

--[=[
	Returns the straight-line distance from [BulletContext.Origin] to the current
	[BulletContext.Position]. Note: this is not the same as [BulletContext.Length],
	which accumulates the actual curved path length.

	@return number -- Distance in studs, or 0 if no position is recorded yet.
]=]
function BulletContext:GetDistanceTraveled(): number end

--[=[
	Returns a read-only snapshot of the bullet's current state.

	Useful for logging, replication, or passing state to systems that should
	not hold a live reference to the context.

	@return BulletSnapshot
]=]
function BulletContext:GetSnapshot(): BulletSnapshot end

--[=[
	Terminates the bullet immediately, notifying the solver to clean up resources,
	destroy the cosmetic object, and fire `OnTerminated`.

	Calling `Terminate` on an already-dead bullet is a no-op.
]=]
function BulletContext:Terminate() end

return BulletContext
