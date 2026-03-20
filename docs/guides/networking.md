---
sidebar_position: 3
---

# Networking and Trust

Multiplayer shooters have a problem that single-player games don't: the client lies.

Not always on purpose. Sometimes the client is a bad actor deliberately reporting false hits. Sometimes it's a legitimate player on a 200ms connection whose bullet's position doesn't quite line up with where the server thinks it should be. Either way, the server needs a way to decide what to believe — and that decision has consequences in both directions.

Believe too little and legitimate hits get rejected. Players feel the game is broken, report rubber bullets and missed shots. Believe too much and exploiters can fire from anywhere, claim hits at any range, damage without risk.

Most games pick a point on that spectrum and live with the tradeoffs. VetraNet is built around a specific answer to the question: **what is the minimum amount of trust required to make this fair?**

---

## The Classic Approaches and Why They Fall Short

**Trust the client entirely.** The client says it hit, so it hit. Damage is applied immediately, no server check. This is fast, it feels responsive, and it works great until someone sends a remote event claiming they hit every player in the game simultaneously. It's not a strategy — it's an absence of strategy.

**Raycast on the server only.** The client sends "I fired here in this direction." The server re-runs the full hit detection itself. Nothing the client can claim matters — the server is authoritative on all hits.

This sounds perfect until you think about lag. A player on 100ms ping fires at someone. That fire event arrives on the server 100ms later. The server raycasts at the target's position as it currently is — not where it was when the player pulled the trigger. If the target moved in those 100ms, the server misses. The player sees a hit, the server says miss. Every shot on a moving target becomes a gamble.

You can add lag compensation — store a history of character positions and rewind the server state to the client's timestamp before raycasting. Now you're correct for positions but the implementation complexity is significant, and the rewind window itself introduces its own exploits.

**Reconstruct the trajectory, compare the claim.** The server and client both run the same physics. The server records the bullet's trajectory as it fires it. When the client reports a hit, the server reconstructs where that bullet *should have been* at the reported timestamp and checks whether the client's claimed position is within tolerance.

This is what VetraNet does. The client can't fabricate a hit from a position the bullet never visited. Timing and position both have to be plausible for the physics to have produced them. Lag is tolerated within a configured window. Exploiting requires breaking the physics simulation, not just crafting a remote event.

---

## The Behavior Hash

Here's a subtle exploit that most systems miss: if the client sends the full behavior configuration with every fire request, they can send a modified behavior. Dramatically increased speed, no `MaxPierceCount`, a custom `CanPierceFunction` that always returns true. The server trusts the behavior because it came with the fire request.

VetraNet avoids this entirely. Behavior tables are **never sent over the network**. Instead, both server and client register the same behaviors at startup — same names, same order — and fire requests carry only a 2-byte hash that identifies which pre-registered behavior was used.

```lua
-- SharedBehaviors.lua — required by both server and client
local Registry = Vetra.VetraNet.BehaviorRegistry.new()
Registry:Register("Rifle",   RifleBehavior)
Registry:Register("Shotgun", ShotgunBehavior)
return Registry
```

The client fires a `"Rifle"` and sends hash `1`. The server looks up hash `1` in its own registry — the same `RifleBehavior` it registered at startup. There's nothing for the client to forge. If they send an unregistered hash, the request is rejected with `RejectedUnknownBehavior` before a bullet ever spawns.

This also means fire payloads are tiny. A hash fits in 2 bytes. Position and direction together are 24 bytes. The entire fire request is small enough that you could realistically fire at high rates without worrying about bandwidth from the request itself.

---

## What Gets Validated

When a fire request arrives on the server, VetraNet checks several things before spawning a bullet:

**Rate limiting.** A token bucket prevents any player from firing faster than their configured `TokensPerSecond`. Burst fire is allowed up to `BurstLimit` tokens. When tokens run out, the request is rejected with `RejectedRateLimit`. This catches both speed exploiters and bugs that cause repeated fire events.

**Concurrent limit.** A player can't have more than `MaxConcurrentPerPlayer` bullets in flight simultaneously. Shotgun spreads count as multiple bullets and deplete this budget faster. Exceeding it gives `RejectedConcurrentLimit`.

**Behavior validity.** The hash is resolved against the server's registry. Unknown hash → `RejectedUnknownBehavior`.

**Origin tolerance.** The client reports the muzzle position. The server reconstructs where the player's character could plausibly have been at the fire timestamp. If the reported origin is more than `MaxOriginTolerance` studs from a plausible position, the request is rejected. This catches position spoofing and teleport exploits.

**Speed validation.** The reported initial speed is checked against the behavior's `MaxSpeed`. A client can't fire a `"Rifle"` at 10,000 studs/s if `RifleBehavior.MaxSpeed` is 900.

:::tip Always set MaxSpeed
`MaxSpeed` is what makes the speed validation meaningful. A behavior without it falls back to a global default cap. For every registered behavior, call `:Physics():MaxSpeed(n):Done()` on the builder. The registry logs a warning if it's missing.
:::

---

## The Architecture in Practice

```
Client                                   Server
──────                                   ──────
player pulls trigger

Net:Fire(pos, dir, speed, "Rifle")
→ serialize: {pos, dir, speed, hash=1}
→ send over RemoteEvent
                                         ← receive fire packet
                                         ← validate: rate, concurrent, hash, origin, speed
                                         ← Solver:Fire() — bullet lives on server
                                         ← record trajectory for validation
                                         ← echo fire to all clients

← receive echo
← spawn local cosmetic bullet
← DriftCorrector tracks server state

                                         (bullet travels on server...)
                                         ← bullet hits something
                                         ← fire OnHit
                                         ← broadcast hit event

← receive hit event
← terminate local cosmetic at hit pos
```

Two things are happening in parallel. The server runs the authoritative bullet. The client runs a cosmetic copy locally, spawned with a small delay to absorb RTT jitter. When the server sends state updates (every Heartbeat, if `ReplicateState = true`), the `DriftCorrector` smoothly nudges the cosmetic bullet toward the server's confirmed position. From the player's perspective, the bullet they see is correct almost all the time. The server's bullet is what actually matters for hit detection.

---

## Configuring It

```lua
-- Server setup
local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
    MaxOriginTolerance     = 20,   -- studs; wider = more lag tolerance, less precise exploit detection
    TokensPerSecond        = 10,   -- fire rate limit (refill rate)
    BurstLimit             = 20,   -- max burst before throttling kicks in
    MaxConcurrentPerPlayer = 15,   -- max in-flight bullets per player
    ReplicateState         = true, -- broadcast state to clients each Heartbeat
    DriftThreshold         = 2,    -- studs before cosmetic correction begins
    CorrectionRate         = 8,    -- studs/s lerp rate for correction
})

Net.OnValidatedHit:Connect(function(player, context, result, velocity, impactForce)
    if result then
        local damage = context.UserData.Damage or 0
        -- apply damage to result.Instance here
    end
end)

Net.OnFireRejected:Connect(function(player, reason)
    -- log this for telemetry; multiple RejectedRateLimit events from the same player
    -- might warrant investigation
    warn(player.Name, "fire rejected:", reason)
end)
```

```lua
-- Client setup (same SharedRegistry required)
local Net = Vetra.VetraNet.new(ClientSolver, SharedRegistry)

-- In your tool's activation code:
Net:Fire(
    tool.Handle.CFrame.Position,
    (mouseHitPosition - tool.Handle.CFrame.Position).Unit,
    RifleBehavior.MaxSpeed,
    "Rifle"
)
```

---

## Tuning Tolerance

The `MaxOriginTolerance` value is a tradeoff. Tighter = harder to exploit but more legitimate hits rejected for players with high ping. Looser = more forgiving for laggy players but easier to fake position.

A reasonable starting point is `15`–`20` studs. For a competitive game where exploits are a serious concern, you might go as low as `10`. For a casual game where you'd rather never reject a real hit, `25`–`30` might be appropriate.

The same principle applies to the validator tolerances if you're using `WithValidator` directly:

```lua
local Solver = Vetra.WithValidator(Vetra.new(), {
    MaxOriginTolerance = 20,   -- fire origin
    PositionTolerance  = 15,   -- hit position
    VelocityTolerance  = 80,   -- velocity at hit time (studs/s)
    TimeTolerance      = 0.15, -- timestamp (seconds)
})
```

Start generous. Look at your `OnFireRejected` telemetry. If you're seeing a high rate of `RejectedOriginTolerance` from players you trust, loosen it. If you're seeing implausible rejection patterns from specific accounts, that's information worth acting on.

---

## Authority Modes

VetraNet supports three authority modes, configured via `NetworkConfig.Mode`. Always use `Vetra.Enums.NetworkMode` rather than raw strings.

### ClientAuthoritative *(default)*

Clients send fire requests. The server validates each one — rate limit, origin tolerance, behavior hash — and replicates approved bullets to all clients. This is the standard model for player weapons.

```lua
local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
    -- Mode defaults to ClientAuthoritative; no need to set it explicitly
})
```

### ServerAuthority

Only server code may initiate bullets. Any fire request that arrives from a client is silently dropped. Use this for NPC projectiles, environmental hazards, or any weapon that should be entirely server-controlled — clients literally cannot spawn a network bullet in this mode, no matter what events they fire.

```lua
local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
    Mode = Vetra.Enums.NetworkMode.ServerAuthority,
})

-- Somewhere in server weapon/NPC code:
Net:Fire(origin, direction, speed, SharedRegistry:HashOf("SniperRifle"))
```

Server-fired bullets replicate to all clients automatically. The `OnValidatedHit` signal still fires on hit — the `owner` parameter will be `nil` (no player owns the bullet), so make sure your damage handler accounts for that.

```lua
Net.OnValidatedHit:Connect(function(owner, context, result, velocity, impactForce)
    if owner then
        -- player bullet hit something
    else
        -- server-owned bullet hit something
    end
end)
```

### SharedAuthority

Both client and server may fire. Client requests go through the full validation pipeline. Server calls bypass it. Use this when player weapons and server-owned projectiles share the same handle and behavior registry.

```lua
local Net = Vetra.VetraNet.new(ServerSolver, SharedRegistry, {
    Mode = Vetra.Enums.NetworkMode.SharedAuthority,
})

-- Client fires via Net:Fire() as normal.
-- Server can also fire:
Net:Fire(origin, direction, speed, SharedRegistry:HashOf("Mortar"))
```

---

## What VetraNet Can't Do

VetraNet validates that bullets followed physics it could have produced. It doesn't validate that the player *should* have been able to fire — that the tool was equipped, that the player was alive, that the cooldown had elapsed. Those are your responsibility to check before or after calling `Net:Fire`.

It also doesn't prevent cosmetic exploits. A client could display their own bullets travelling wherever they want locally — VetraNet only controls what the server acknowledges as a real hit. Visual cheating that doesn't produce server-authoritative damage is a separate problem outside the scope of ballistics.

The goal is a reasonable, practical level of protection that makes projectile exploiting hard without making the game unfair for legitimate players with normal network conditions. That's an engineering goal, not a security guarantee — but for most games, it's more than enough.
