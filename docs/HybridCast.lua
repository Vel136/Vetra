--[=[
	@class VetraCast

	The internal representation of one in-flight projectile. Returned by
	[Vetra:Fire] for callers that need to introspect initial state.

	:::warning
	Weapon scripts should interact with [BulletContext] rather than `VetraCast`
	directly. `VetraCast` exposes internal solver state — mutating it directly
	can produce physics errors that are difficult to debug.

	The methods below (`GetPosition`, `SetVelocity`, etc.) are safe to call and are
	the intended way to read or modify a bullet mid-flight from within signal handlers.
	:::
]=]
local VetraCast = {}

-- ─── Properties ──────────────────────────────────────────────────────────────

--[=[
	@prop Alive boolean
	@within VetraCast
	@readonly

	`true` while the cast is being simulated. Set to `false` as the very first
	action in termination so re-entrant calls are no-ops.
]=]

--[=[
	@prop Paused boolean
	@within VetraCast

	When `true`, `_StepProjectile` skips this cast entirely. `TotalRuntime` does
	not advance, producing seamless resumption from the paused position when set
	back to `false`.
]=]

--[=[
	@prop UserData {[any]: any}
	@within VetraCast

	Free-form table for weapon-specific metadata. Shared with the linked
	[BulletContext] and passed unchanged on every signal emission.
]=]

-- ─── State Getters ───────────────────────────────────────────────────────────

--[=[
	Returns the bullet's current world-space position using the analytic
	kinematic formula. Always accurate to the current simulation time
	regardless of when in the frame it is called.

	@return Vector3
]=]
function VetraCast:GetPosition(): Vector3 end

--[=[
	Returns the bullet's current velocity vector. The magnitude of this vector
	is the current speed in studs per second.

	@return Vector3
]=]
function VetraCast:GetVelocity(): Vector3 end

--[=[
	Returns the constant acceleration vector for the active trajectory segment.
	This is the pre-computed sum of gravity and any extra acceleration — not
	`workspace.Gravity` alone.

	@return Vector3
]=]
function VetraCast:GetAcceleration(): Vector3 end

-- ─── State Setters ───────────────────────────────────────────────────────────

--[=[
	Teleports the bullet to a new world-space position without changing its
	velocity or acceleration. Opens a new trajectory segment if simulation
	time has already elapsed on the current one.

	@param position Vector3
]=]
function VetraCast:SetPosition(position: Vector3) end

--[=[
	Changes the bullet's velocity to the given vector. Opens a new trajectory
	segment if needed.

	:::tip
	Call [VetraCast:ResetBounceState] after a sharp velocity change to prevent
	the corner-trap detector from triggering on the new trajectory.
	:::

	@param velocity Vector3
]=]
function VetraCast:SetVelocity(velocity: Vector3) end

--[=[
	Replaces the bullet's constant acceleration for future simulation. Because
	acceleration is constant within a segment, this always opens a new segment
	unless the current one has zero elapsed time.

	@param acceleration Vector3
]=]
function VetraCast:SetAcceleration(acceleration: Vector3) end

--[=[
	Translates the bullet by an offset in world space. Equivalent to
	`SetPosition(GetPosition() + offset)`.

	@param offset Vector3
]=]
function VetraCast:AddPosition(offset: Vector3) end

--[=[
	Adds a delta to the bullet's current velocity. Useful for impulse effects
	such as explosion knockback applied mid-flight.

	@param delta Vector3
]=]
function VetraCast:AddVelocity(delta: Vector3) end

--[=[
	Adds a delta to the bullet's constant acceleration. Useful for variable wind
	or thrust that builds up over time via repeated calls.

	@param delta Vector3
]=]
function VetraCast:AddAcceleration(delta: Vector3) end

-- ─── Utilities ───────────────────────────────────────────────────────────────

--[=[
	Resets the corner-trap sentinel fields (`LastBounceTime`, `LastBounceNormal`,
	`LastBouncePosition`) back to their initial values.

	Call this after any programmatic mid-flight velocity change (e.g. `SetVelocity`,
	`AddVelocity`) that deliberately reverses or sharply redirects the bullet,
	otherwise the corner-trap detector may falsely terminate the cast on the
	next bounce.
]=]
function VetraCast:ResetBounceState() end

return VetraCast