--[=[
	@class VetraNet

	Full-stack network middleware for Vetra. Handles fire-request
	serialization, server-side authority (rate limiting, origin validation,
	behavior verification), authoritative bullet replication, and client-side
	cosmetic management — all over a **single `RemoteEvent`**.

	VetraNet is accessed via `Vetra.VetraNet`. It is environment-aware:
	calling it on the server returns a handle with authority signals;
	calling it on the client returns a handle with `:Fire()`.

	## Architecture Overview

	```
	Client                              Server
	──────                              ──────
	Net:Fire(origin, dir, speed, name)
	  → FireChannel.SendFire()          ← FireChannel decode
	  → cosmetic spawned locally (+ latency buffer)
	                                    ← FireValidator: origin, speed, behavior hash
	                                    ← RateLimiter: token deduct
	                                    ← Solver:Fire() → bullet lives on server
	                                    ← OutboundBatcher.WriteFireForAll()
	  ← cosmetic echoed (all clients)
	                                    ← hit events → OutboundBatcher.WriteHitForAll()
	  ← state batches (every Heartbeat, if ReplicateState = true)
	  ← DriftCorrector lerps cosmetics toward server position
	```

	## Setup

	**Shared registration (ModuleScript required by both sides):**

	```lua
	-- SharedBehaviors.lua (in ReplicatedStorage)
	local Vetra = require(ReplicatedStorage.Vetra)

	local Registry = Vetra.VetraNet.BehaviorRegistry.new()
	Registry:Register("Rifle",   RifleBehavior)
	Registry:Register("Shotgun", ShotgunBehavior)
	return Registry
	```

	:::danger Registration order
	Both server and client **must** register behaviors in the same order with
	the same names. Fire payloads carry only a 2-byte u16 hash — if the hash
	tables diverge, every fire request will be rejected as `RejectedUnknownBehavior`.
	Enforce this by requiring the same shared registration module on both sides.
	:::

	**Server:**

	```lua
	local SharedRegistry = require(ReplicatedStorage.SharedBehaviors)

	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    MaxOriginTolerance     = 20,
	    TokensPerSecond        = 10,
	    BurstLimit             = 20,
	    ReplicateState         = true,
	})

	Net.OnValidatedHit:Connect(function(owner, context, result, velocity, impactForce)
	    -- apply damage, update leaderboard, etc.
	end)

	Net.OnFireRejected:Connect(function(player, reason)
	    warn(player.Name .. " fire rejected: " .. reason)
	end)
	```

	**Client:**

	```lua
	local SharedRegistry = require(ReplicatedStorage.SharedBehaviors)

	local Net = Vetra.VetraNet.new(ClientSolver, SharedRegistry)

	-- Fire a bullet over the network
	Net:Fire(muzzlePosition, direction, speed, "Rifle")
	```

	## NetworkConfig

	All fields are optional. Unset fields fall back to built-in defaults.
	See [TypeDefinitions.NetworkConfig] for the complete interface.

	| Field | Type | Default | Description |
	|-------|------|---------|-------------|
	| `MaxOriginTolerance` | `number` | `15` | Max studs between client-reported and server-reconstructed fire origin. |
	| `MaxConcurrentPerPlayer` | `number` | `20` | Maximum bullets a player may have in flight simultaneously. |
	| `TokensPerSecond` | `number` | `10` | Token-bucket refill rate for fire-rate limiting. |
	| `BurstLimit` | `number` | `20` | Maximum burst tokens. Must be `>= TokensPerSecond`. |
	| `DriftThreshold` | `number` | `2` | Studs of drift before the client corrector begins interpolating. |
	| `CorrectionRate` | `number` | `8` | Lerp speed for drift correction (studs per second). |
	| `LatencyBuffer` | `number` | `0` | Extra seconds to delay local cosmetic spawn. `0` = use measured RTT. |
	| `ReplicateState` | `boolean` | `true` | Broadcast bullet state every Heartbeat to all clients. |
	| `Mode` | `NetworkMode` | `"ClientAuthoritative"` | Authority mode — controls which side may call `:Fire()`. See [Enums.NetworkMode]. |

	## NetworkMode

	VetraNet supports three authority modes, set via `NetworkConfig.Mode`.
	Use `Vetra.Enums.NetworkMode` values rather than raw strings.

	**`ClientAuthoritative`** *(default)*

	Clients send fire requests. The server validates each request (rate limit,
	origin tolerance, behavior hash) and replicates approved bullets to all
	clients. Use this for standard player-fired weapons.

	```lua
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    Mode = Vetra.Enums.NetworkMode.ClientAuthoritative, -- or omit; this is the default
	})
	```

	**`ServerAuthority`**

	Only server code may initiate bullets by calling `Net:Fire()`. Any fire
	request that arrives from a client is silently dropped — clients cannot
	spawn network bullets at all. Use this for NPC projectiles, environmental
	hazards, or any weapon whose origin should be entirely server-controlled.

	```lua
	-- Server
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    Mode = Vetra.Enums.NetworkMode.ServerAuthority,
	})

	-- Fire a bullet from server code; replicates to all clients automatically.
	Net:Fire(origin, direction, speed, behaviorHash)
	```

	**`SharedAuthority`**

	Both client and server may fire. Client requests go through the full
	validation pipeline as in `ClientAuthoritative`. Server calls bypass
	validation and replicate directly. Use this when player weapons and
	server-owned projectiles share the same handle and behavior registry —
	for example, a weapon that can also be triggered by a server script.

	```lua
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    Mode = Vetra.Enums.NetworkMode.SharedAuthority,
	})
	```
]=]
local VetraNet = {}

--[=[
	@prop BehaviorRegistry BehaviorRegistry
	@within VetraNet

	Re-export of the [BehaviorRegistry] module. Access via
	`Vetra.VetraNet.BehaviorRegistry`.
]=]

--[=[
	Creates a new VetraNet handle. Returns a server or client handle
	depending on the environment (`RunService:IsServer()`).

	On the **server** returns a handle with `.OnValidatedHit`, `.OnFireRejected`,
	and `:Destroy()`.

	On the **client** returns a handle with `:Fire()` and `:Destroy()`.

	The optional `OnCosmeticFire` and `OnCosmeticHit` signals are client-only.
	Pass pre-created `VeSignal` instances if you need to hook into cosmetic
	events outside the standard signal table.

	```lua
	-- Server
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    TokensPerSecond = 15,
	    BurstLimit      = 30,
	    ReplicateState  = true,
	})

	-- Client
	local Net = Vetra.VetraNet.new(ClientSolver, SharedRegistry)
	```

	@param Solver Vetra -- The live Vetra solver instance.
	@param BehaviorRegistry BehaviorRegistry -- Shared pre-populated registry.
	@param NetworkConfig NetworkConfig? -- Optional configuration overrides.
	@param OnCosmeticFire Signal? -- (Client only) Fired after a cosmetic bullet spawns locally.
	@param OnCosmeticHit Signal? -- (Client only) Fired after a cosmetic bullet terminates on a confirmed hit.
	@return VetraNetServer | VetraNetClient
]=]
function VetraNet.new(
	Solver:           any,
	BehaviorRegistry: any,
	NetworkConfig:    any?,
	OnCosmeticFire:   any?,
	OnCosmeticHit:    any?
): any end

-- ─── Server Properties ───────────────────────────────────────────────────────

--[=[
	@prop OnValidatedHit Signal
	@within VetraNet

	*(Server only)*

	Fired after a hit report passes all server-side authority checks:
	rate-limit, concurrent-bullet limit, origin tolerance, behavior validity,
	and trajectory reconstruction. Safe to use for damage application.

	Signal signature:
	`(owner: Player, context: BulletContext, result: RaycastResult?, velocity: Vector3, impactForce: number)`

	- `result` is `nil` for speed/distance expiry events (no surface was struck).
	- `impactForce` is computed as `BulletMass × velocity.Magnitude`. Returns `0`
	  when `BulletMass` is not set on the behavior.
]=]

--[=[
	@prop OnFireRejected Signal
	@within VetraNet

	*(Server only)*

	Fired when a fire request is rejected before a bullet is spawned.
	Useful for anti-cheat logging, telemetry, and kick thresholds.

	Signal signature: `(player: Player, reason: string)`

	**Rejection reasons:**

	| Reason | Description |
	|--------|-------------|
	| `"RejectedNoSession"` | Player has no active VetraNet session (not yet registered). |
	| `"RejectedRateLimit"` | Player exceeded their token-bucket fire rate. |
	| `"RejectedConcurrentLimit"` | Player already has `MaxConcurrentPerPlayer` bullets in flight. |
	| `"RejectedUnknownBehavior"` | Behavior hash not found in the server's registry. |
	| `"RejectedOriginTolerance"` | Fire origin too far from the server-reconstructed position. |
	| `"RejectedInvalidSpeed"` | Reported speed exceeds the behavior's `MaxSpeed`. |
]=]

-- ─── Server Methods ──────────────────────────────────────────────────────────

--[=[
	*(Server only — `ServerAuthority` and `SharedAuthority` modes)*

	Fires a server-owned bullet and replicates it to all clients.
	Bypasses all validation (rate limit, origin tolerance, behavior hash checks)
	because the server is considered trusted.

	Only available when `Mode` is `ServerAuthority` or `SharedAuthority`.
	Calling this in `ClientAuthoritative` mode logs an error and returns `0`.

	```lua
	local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
	    Mode = Vetra.Enums.NetworkMode.ServerAuthority,
	})

	-- Fire from an NPC or scripted event:
	Net:Fire(
	    npc.HumanoidRootPart.Position + Vector3.new(0, 1, 0),
	    (targetPosition - npc.HumanoidRootPart.Position).Unit,
	    600,
	    SharedRegistry:HashOf("Rifle")
	)
	```

	Returns the server-assigned cast ID on success, or `0` on failure
	(unknown behavior hash, wrong mode).

	@server
	@param Origin Vector3 -- World-space fire origin.
	@param Direction Vector3 -- Unit direction vector.
	@param Speed number -- Initial bullet speed in studs/second.
	@param BehaviorHash number -- Numeric hash from `BehaviorRegistry:HashOf(name)`.
	@return number -- Server cast ID, or `0` on failure.
]=]
function VetraNet:Fire(Origin: Vector3, Direction: Vector3, Speed: number, BehaviorHash: number): number end

-- ─── Client Methods ──────────────────────────────────────────────────────────

--[=[
	*(Client only)*

	Serializes and sends a fire request to the server, then spawns a
	local cosmetic bullet after the configured latency buffer.

	```lua
	Net:Fire(
	    tool.Handle.Position,  -- muzzle position
	    direction.Unit,        -- unit direction
	    250,                   -- speed in studs/s
	    "Rifle"                -- registered behavior name
	)
	```

	The cosmetic bullet is spawned locally with a small delay (latency buffer)
	to reduce visible RTT jitter. `DriftCorrector` lerps it toward the
	server-confirmed position once state replication arrives.

	Silently no-ops and logs a warning if the behavior name is not registered
	in the client registry.

	@client
	@param Origin Vector3 -- World-space fire origin.
	@param Direction Vector3 -- Unit direction vector.
	@param Speed number -- Initial bullet speed in studs/second.
	@param BehaviorName string -- Registered behavior name (must match server registry).
]=]
function VetraNet:Fire(Origin: Vector3, Direction: Vector3, Speed: number, BehaviorName: string) end

-- ─── Shared Methods ──────────────────────────────────────────────────────────

--[=[
	Tears down this VetraNet handle. Disconnects all `RemoteEvent`
	listeners, stops the Heartbeat frame loop, and destroys all
	internal state including signals.

	:::caution
	Call this only when shutting down the game or a specific weapon system
	entirely. Do not call on every player disconnect — VetraNet is designed
	to live for the duration of the server/client lifetime.
	:::
]=]
function VetraNet:Destroy() end

return VetraNet
