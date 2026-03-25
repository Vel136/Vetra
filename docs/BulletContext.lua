--[=[
	@class BulletContext

	The public-facing object that weapon code interacts with for every
	in-flight projectile.

	Create one before firing, pass it to [Vetra:Fire], then use the
	solver's signals to react to events. The context is passed as the
	first argument on every signal so you can identify the bullet and
	read its current state.

	```lua
	local context = BulletContext.new({
	    Origin    = muzzlePosition,
	    Direction = direction,
	    Speed     = 200,
	})

	Solver:Fire(context, Behavior)
	```

	:::tip UserData
	Attach weapon-specific metadata (shooter UserId, damage value, hit-group
	flags, etc.) via `context.UserData` before calling `Fire`. This table is
	passed unchanged on every signal emission.
	:::
]=]
local BulletContext = {}

-- ─── Properties ──────────────────────────────────────────────────────────────

--[=[
	@prop Id number
	@within BulletContext
	@readonly

	Auto-incrementing unique identifier assigned at construction time.
	Use this to distinguish bullets in signal handlers without storing
	separate references.
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

	Initial speed in studs per second. The bullet's actual speed decreases
	over time due to drag, bounces (restitution), and pierces (speed retention).
	Read the magnitude of `Velocity` for the current speed.
]=]

--[=[
	@prop StartTime number
	@within BulletContext
	@readonly

	`os.clock()` timestamp at construction. Use with [BulletContext:GetLifetime]
	to compute bullet age without storing the time yourself.
]=]

--[=[
	@prop Position Vector3?
	@within BulletContext
	@readonly

	Current world-space position. Updated every frame by the solver.
	`nil` until the first simulation step.
]=]

--[=[
	@prop Velocity Vector3
	@within BulletContext
	@readonly

	Current velocity vector in studs per second. Updated every frame by the
	solver. The magnitude of this vector is the current speed.
]=]

--[=[
	@prop Alive boolean
	@within BulletContext
	@readonly

	`true` while the cast is being simulated. Set to `false` by
	[BulletContext:Terminate] or automatically by the solver on hit,
	distance expiry, speed expiry, or corner-trap detection.
]=]

--[=[
	@prop Length number
	@within BulletContext
	@readonly

	True accumulated path distance in studs — the sum of every frame
	displacement since firing. This diverges from straight-line
	`(Position - Origin).Magnitude` for bullets that bounce or follow
	homing curves. See also [BulletContext:GetDistanceTraveled].
]=]

--[=[
	@prop SimulationTime number
	@within BulletContext
	@readonly

	Total seconds this bullet has been simulated, as tracked by the solver.
	Updated every frame. Use [BulletContext:GetLifetime] to read this.
	Does not advance while the cast is paused.
]=]

--[=[
	@prop CosmeticBulletObject Instance?
	@within BulletContext
	@readonly

	Set by the solver after the cosmetic bullet is created. Readable from
	signal handlers (`OnSegmentOpen`, `OnBounce`, etc.) via the context argument.
	`nil` when no cosmetic is configured or after the bullet terminates.
]=]

--[=[
	@prop UserData {[any]: any}
	@within BulletContext

	Free-form table for attaching cast-specific metadata (shooter UserId,
	weapon type, damage value, etc.). Surfaced on every signal emission —
	read it in your handlers to route events without maintaining a parallel lookup.

	```lua
	context.UserData.Damage    = 45
	context.UserData.ShooterId = Players.LocalPlayer.UserId

	Signals.OnHit:Connect(function(context, result, velocity)
	    local damage    = context.UserData.Damage
	    local shooterId = context.UserData.ShooterId
	end)
	```
]=]

-- ─── Constructor ─────────────────────────────────────────────────────────────

--[=[
	Creates a new BulletContext.

	`Origin`, `Direction`, and `Speed` are required. `SolverData` is reserved
	for internal solver use — do not supply it from weapon code.

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
	Returns how many seconds this bullet has been simulated.

	Tracks `SimulationTime` accumulated by the solver — not real-world clock
	time. Does not advance while the cast is paused.

	@return number -- Simulated age in seconds.
]=]
function BulletContext:GetLifetime(): number end

--[=[
	Returns the true accumulated path length of the bullet in studs.

	Unlike `(Position - Origin).Magnitude`, this correctly accounts for
	bounces and homing curves by accumulating the actual frame-by-frame
	displacement. Equivalent to reading `context.Length`.

	@return number -- Path length in studs.
]=]
function BulletContext:GetDistanceTraveled(): number end

--[=[
	Returns a read-only snapshot of the bullet's current state.

	Useful for logging, replication, or passing state to systems that
	should not hold a live reference to the context.

	@return BulletSnapshot
]=]
function BulletContext:GetSnapshot(): BulletSnapshot end

--[=[
	Terminates the bullet immediately, notifying the solver to clean up
	resources, destroy the cosmetic object, and fire `OnTerminated`.

	Calling `Terminate` on an already-dead bullet is a no-op.
]=]
function BulletContext:Terminate() end

return BulletContext
