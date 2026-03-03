--[=[
	@class Vetra

	Analytic-trajectory projectile simulation engine for Roblox.

	Vetra manages all active in-flight projectiles. Every frame it advances
	each cast using the exact kinematic formula `P(t) = Origin + V₀t + ½At²`,
	raycasts between the previous and current position, and resolves hits as
	pierce, bounce, or terminal impact.

	Signals are module-level — connect once at initialisation and receive events
	from every cast. The [BulletContext] argument on every signal lets you identify
	which bullet fired the event and dispatch accordingly.

	```lua
	local Vetra = require(path.to.Vetra)

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

--[=[
	@prop BehaviorBuilder BehaviorBuilder
	@within Vetra

	Re-export of the [BehaviorBuilder] module so consumers only need to require
	Vetra and can access the builder via `Vetra.BehaviorBuilder`.
]=]

--[=[
	Creates a new Vetra instance and connects the per-frame simulation
	loop to the appropriate RunService event (Heartbeat on server, RenderStepped
	on client).

	:::caution
	Call this only once. Calling `new()` more than once will log a warning
	and return an additional instance sharing the same underlying state —
	the frame loop is not connected a second time.
	:::

	@return Vetra
]=]
function Vetra.new(): Vetra end

--[=[
	Creates and registers a new in-flight projectile cast.

	`context` must have non-nil, finite `Origin` (Vector3), `Direction` (Vector3),
	and `Speed` (number) fields. Any field omitted from `behavior` falls back to
	the built-in defaults.

	After `Fire` returns the cast is live and will be advanced every frame until
	it hits something, expires by distance or speed, or is stopped via
	`context:Terminate()`.

	@param context BulletContext -- The public bullet object weapon code interacts with.
	@param behavior VetraBehavior? -- Optional behavior overrides. Omitted fields use defaults.
	@return VetraCast -- The internal cast object, or nil if validation failed.
]=]
function Vetra:Fire(context: BulletContext, behavior: VetraBehavior?): VetraCast end

--[=[
	Returns the module-level Signals table.

	Connect to these once during weapon initialisation. Every signal passes the
	[BulletContext] as its first argument so you can identify the bullet and
	access its `UserData`.

	```lua
	local Signals = Solver:GetSignals()

	Signals.OnHit:Connect(function(context, result, velocity)
	    if result then
	        -- physical surface impact
	    else
	        -- distance or speed expiry
	    end
	end)

	Signals.OnBounce:Connect(function(context, result, velocity, bounceCount)
	    print("Bounce #" .. bounceCount)
	end)
	```

	**Signal contracts:**

	| Signal | Arguments |
	|--------|-----------|
	| `OnHit` | `context`, `result: RaycastResult?`, `velocity: Vector3` |
	| `OnTravel` | `context`, `position: Vector3`, `velocity: Vector3` |
	| `OnPierce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `pierceCount: number` |
	| `OnBounce` | `context`, `result: RaycastResult`, `velocity: Vector3`, `bounceCount: number` |
	| `OnTerminated` | `context` |

	`OnHit` fires with a nil `result` when the bullet expires by distance or minimum
	speed rather than a physical surface impact. Check `result ~= nil` to distinguish
	the two cases.

	`OnTravel` fires every frame using `Fire` (not `FireSafe`) — handlers must not throw.

	@return { OnHit: Signal, OnTravel: Signal, OnPierce: Signal, OnBounce: Signal, OnTerminated: Signal }
]=]
function Vetra:GetSignals() end

return Vetra