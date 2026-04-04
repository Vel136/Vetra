--[=[
	@class Enums

	Named constant tables for every value that appears in Vetra's public API.

	Access via `Vetra.Enums`:

	```lua
	local Vetra = require(ReplicatedStorage.Vetra)

	-- Drag model for the BehaviorBuilder
	local DragModel     = Vetra.Enums.DragModel
	local TerminateReason = Vetra.Enums.TerminateReason
	```

	`BehaviorBuilder.DragModel` is a direct re-export of `Vetra.Enums.DragModel`
	— they are the same table. You can use either reference interchangeably.

	:::tip Why enums instead of raw strings or numbers?
	Passing `BehaviorBuilder.DragModel.G7` instead of the integer `10` or the
	string `"G7"` means a typo is a nil-index warning at the call site rather
	than a silent wrong value or a validation error at `:Build()` time.
	If an enum value is ever renamed, every reference site produces an error
	rather than silently passing the wrong value.
	:::
]=]
local Enums = {}

-- ─── DragModel ───────────────────────────────────────────────────────────────

--[=[
	@prop DragModel { [string]: number }
	@within Enums
	@tag enum

	Integer identifiers for the drag model used to compute aerodynamic
	deceleration each `DragSegmentInterval` seconds.

	Stored as integers rather than strings so the physics hot path uses integer
	comparison rather than string comparison. `BehaviorBuilder.DragModel` is a
	direct re-export of this table.

	Pass values from this table to `:Drag():Model()` and
	`:SpeedProfiles():Supersonic():DragModel()`.

	```lua
	local Behavior = BehaviorBuilder.new()
	    :Drag()
	        :Coefficient(0.003)
	        :Model(BehaviorBuilder.DragModel.G7)
	    :Done()
	    :Build()
	```

	**Analytic models**, mathematically defined drag curves:

	| Key | Value | Description |
	|-----|-------|-------------|
	| `Quadratic` | `1` | Deceleration ∝ speed², default; most accurate for subsonic bullets |
	| `Linear` | `2` | Deceleration ∝ speed |
	| `Exponential` | `3` | Deceleration ∝ eˢᵖᵉᵉᵈ, exotic high-drag shapes |

	**G-series empirical models**, Mach-indexed Cd lookup tables derived from
	ballistic reference projectiles. The `DragCoefficient` field acts as a scalar
	multiplier on top of the table value, `1.0` is physically accurate, lower
	values give a more arcade feel:

	| Key | Value | Description |
	|-----|-------|-------------|
	| `G1` | `4` | Flat-base spitzer, general-purpose standard |
	| `G2` | `5` | Aberdeen J projectile, large-calibre / atypical shapes |
	| `G3` | `6` | Finnish reference projectile, rarely used in practice |
	| `G4` | `7` | Seldom-used reference, included for completeness |
	| `G5` | `8` | Boat-tail spitzer, mid-range rifles |
	| `G6` | `9` | Semi-spitzer flat-base, shotgun slugs / blunt rounds |
	| `G7` | `10` | Long boat-tail, modern long-range / sniper standard |
	| `G8` | `11` | Flat-base semi-spitzer, hollow points / pistols |
	| `GL` | `12` | Lead round ball, cannons / muskets / buckshot |

	**User-supplied:**

	| Key | Value | Description |
	|-----|-------|-------------|
	| `Custom` | `13` | Requires `CustomMachTable = { {mach, cd}, ... }` on the behavior |

	:::tip Choosing a model
	For most modern rifles and pistols, `G7` or `G8` respectively are the most
	physically accurate choices. `Quadratic` is the default and is sufficient
	for gameplay-tuned weapons where exact ballistic fidelity isn't required.
	`GL` gives a distinctly heavy, arcing feel suited to cannons or muskets.
	:::
]=]
Enums.DragModel = {}

-- ─── TerminateReason ─────────────────────────────────────────────────────────

--[=[
	@prop TerminateReason { [string]: string }
	@within Enums
	@tag enum

	Reason strings passed to `OnPreTermination` signal handlers. Compare
	against these rather than hardcoding raw strings, if a value is ever
	renamed, every reference site produces a detectable nil rather than silently
	passing the wrong string.

	```lua
	local Signals = Solver:GetSignals()

	Signals.OnPreTermination:Connect(function(context, reason, mutate)
	    if reason == Vetra.Enums.TerminateReason.Hit then
	        -- bullet struck a surface, optionally cancel termination
	        if context.UserData.HasShield then
	            mutate(true, nil)  -- cancelled
	        end
	    elseif reason == Vetra.Enums.TerminateReason.CornerTrap then
	        -- corner-trap detection triggered, termination cannot be cancelled
	    end
	end)
	```

	| Key | Value | When fired |
	|-----|-------|------------|
	| `Hit` | `"hit"` | Bullet struck a surface and was not pierced or bounced |
	| `Distance` | `"distance"` | `MaxDistance` was reached |
	| `Speed` | `"speed"` | Speed dropped below `MinSpeed` or exceeded `MaxSpeed` |
	| `CornerTrap` | `"corner_trap"` | Corner-trap detection terminated the cast |
	| `Manual` | `"manual"` | `VetraCast:Terminate()` was called, or the solver was destroyed |

	:::caution CornerTrap cannot be cancelled
	`OnPreTermination` with `reason = TerminateReason.CornerTrap` fires the
	mutate callback, but cancelling a corner-trap termination has no effect —
	the bullet is force-terminated regardless. The callback fires for
	observability only.
	:::
]=]
Enums.TerminateReason = {}

-- ─── NetworkMode ──────────────────────────────────────────────────────────────

--[=[
	@prop NetworkMode { [string]: string }
	@within Enums
	@tag enum

	Authority mode for a VetraNet instance. Controls which side may call
	`:Fire()` to initiate a bullet. Pass a value from this table to the
	`Mode` field of [TypeDefinitions.NetworkConfig] when constructing a
	[VetraNet] handle.

	```lua
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    Mode = Vetra.Enums.NetworkMode.ServerAuthority,
	})
	```

	| Key | Value | Who may fire |
	|-----|-------|--------------|
	| `ClientAuthoritative` | `"ClientAuthoritative"` | Client sends fire requests; server validates and replicates. **(Default)** |
	| `ServerAuthority` | `"ServerAuthority"` | Only server code may call `:Fire()`. Client fire requests are silently dropped. |
	| `SharedAuthority` | `"SharedAuthority"` | Both client and server may initiate bullets. Client requests are validated as normal; server fires bypass validation. |

	**Choosing a mode**

	- `ClientAuthoritative`, standard player-fired weapons. The client fires,
	  the server validates origin, rate, and behavior, then replicates to all.
	- `ServerAuthority`, server-controlled projectiles such as NPC attacks,
	  environmental hazards, or scripted events. No client request is ever
	  accepted. Call `Net:Fire()` from server code only.
	- `SharedAuthority`, mixed scenarios where both player weapons and
	  server-spawned projectiles share the same VetraNet handle and behavior
	  registry. Player requests go through the full validation pipeline;
	  server calls bypass it.

	:::caution Default is ClientAuthoritative
	If `Mode` is omitted from `NetworkConfig`, VetraNet defaults to
	`ClientAuthoritative`. Explicitly set `Mode = NetworkMode.ServerAuthority`
	for any handle where clients should never be permitted to fire.
	:::
]=]
Enums.NetworkMode = {}

return Enums