---
sidebar_position: 4
---

# FAQ

Answers to the questions that come up most often.

---

## General

**What is Vetra?**

Vetra is a projectile simulation module for Roblox. Unlike most weapon systems that move a bullet
with `position += velocity * dt` each frame, Vetra uses the exact kinematic formula
`P(t) = Origin + V₀t + ½At²` — no drift, no frame-rate dependency, and a shared ground truth
between client and server. On top of that it builds pierce, bounce, drag, homing, Magnus, tumble,
fragmentation, parallel physics, and a full authoritative network layer.

---

**Is Vetra free?**

Yes — MIT. Use it however you want, commercial or otherwise.

---

**What version is this?**

This documentation covers **Vetra V6**.

---

**Does Vetra work on the client, the server, or both?**

Both. `Vetra.new()` runs on either environment and connects to the appropriate RunService event
automatically — `RenderStepped` on the client, `Heartbeat` on the server. VetraNet is the layer
that coordinates between the two.

---

## Setup

**Where does the Vetra folder go?**

`ReplicatedStorage`. Both client and server need to be able to require it.

---

**Do I need one solver or many?**

One per game system that fires bullets independently. Most games need exactly one. If you have
fundamentally separate bullet contexts — say, a server-authoritative weapon system and a client-side
particle-only system — you'd create separate solvers for each.

---

**Can I use Vetra without VetraNet?**

VetraNet is entirely optional. `Vetra.new()` and `Vetra.newParallel()` work on their own — handle
your own networking and call `Solver:Fire()` from wherever makes sense in your architecture.

---

## Behaviors and Physics

**What's the difference between `BehaviorBuilder` and passing a raw table to `Fire()`?**

They produce the same result — a `VetraBehavior` table passed to the solver. `BehaviorBuilder`
gives you typed setters, build-time validation, a frozen result, and dirty-tracked `:Clone()` /
`:Impose()` for composing weapon archetypes. A raw table is fine for quick tests or one-off fire
calls.

---

**Why did drag, Magnus, and tumble previously require raw table overrides?**

They didn't have builder setters in earlier versions. As of V6 the builder covers every
`VetraBehavior` field — `:Drag()`, `:Magnus()`, `:GyroDrift()`, `:Tumble()`, `:Fragmentation()`,
`:SpeedProfiles()`, `:Wind()`, `:Trajectory()`, `:SixDOF()`, and `:LOD()` are all fully
implemented. Raw table usage is still valid but no longer necessary.

---

**How do I create weapon variants from a shared base?**

Use `:Clone()` to get an independent copy, then chain setters on the clone:

```lua
local Base  = BehaviorBuilder.Sniper()
local Heavy = Base:Clone():Pierce():Max(5):Done():Build()
local Light = Base:Clone():Physics():MaxDistance(800):Done():Build()
-- Base is untouched
```

For applying one or more reusable modifiers in a single call, use `:Merge()`:

```lua
local APMod = BehaviorBuilder.new()
    :Pierce():Max(5):SpeedRetention(0.95):Done()

local HollowMod = BehaviorBuilder.new()
    :Tumble():OnPierce(true):DragMultiplier(5):Done()

-- Neither the preset nor the modifiers are mutated
local Behavior = BehaviorBuilder.Sniper():Merge(APMod, HollowMod):Build()
```

`:Merge(a, b)` is shorthand for `:Clone():Impose(a):Impose(b)`. Use `:Impose()` directly when you already have a cloned builder and want to apply modifiers step by step.

---

**What is `:Impose()` and how does it differ from `:Merge()`?**

`:Impose(other)` copies only the **explicitly set** fields from `other` onto `self`, then returns `self`. It mutates the builder it is called on.

`:Merge(a, b, ...)` is non-destructive — it clones `self` first, then imposes each modifier in order, and returns the new builder. Neither `self` nor the modifiers are touched.

The key point for both: "explicitly set" means a setter was actually called on the source builder, tracked via dirty flags. Default-valued fields are never copied, so a modifier cannot silently reset fields it never touched.

---

**I have a frozen behavior table from a registry. How do I modify one field?**

Use `BehaviorBuilder.Inherit()` — a static constructor that takes a frozen table and returns a mutable builder with every field pre-populated and marked dirty:

```lua
local existing = BehaviorRegistry:Get("Sniper")

local tweaked = BehaviorBuilder.Inherit(existing)
    :Physics():MaxDistance(2000):Done()
    :Build()
```

The original frozen table is untouched.

---

**How do I apply conditional config without breaking the fluent chain?**

Use `:When(condition, fn)`. If the condition is truthy the callback is called with `self`; if falsy the builder is returned unchanged:

```lua
local Behavior = BehaviorBuilder.Sniper()
    :When(isRaining,   function(b) b:Wind():Response(1.5):Done() end)
    :When(isHeavyAmmo, function(b) b:Pierce():Max(5):Done() end)
    :When(isDebug,     function(b) b:Debug():Visualize(true):Done() end)
    :Build()
```

---

**Pierce and bounce both have `Filter` callbacks. Which one fires first?**

Pierce is always evaluated first. If the pierce filter returns `true`, the bounce filter is never
checked for that hit. They are mutually exclusive per surface contact.

---

**My `CanBounceFunction` is being called but the bullet isn't bouncing.**

Check `BounceSpeedThreshold`. The callback is only invoked if the bullet's current speed is above
the threshold — below it, the hit is treated as terminal regardless of what the callback returns.
Also check `MaxBounces` — if the lifetime bounce budget is exhausted, the callback is skipped
entirely.

---

**What does `ResetPierceOnBounce` actually do?**

After each confirmed bounce, it clears the list of already-pierced instances and resets the pierce
count to zero. This means the bullet's post-bounce arc can re-pierce surfaces that were already
pierced on the previous arc. Without it, once an instance is in the "already pierced" list, the
bullet passes through it silently on every subsequent arc.

---

**How does `CoriolisLatitude` / `CoriolisScale` work on the behavior table?**

It doesn't — those fields are in `DEFAULT_BEHAVIOR` for documentation purposes only. Coriolis is a
solver-level setting, not a per-bullet one. Use `Solver:SetCoriolisConfig(latitude, scale)`.
Setting these fields on the behavior table has no runtime effect.

---

## 6DOF Physics

**What is 6DOF and when should I use it?**

6DOF (six degrees of freedom) gives bullets full aerodynamic physics: lift from angle of attack,
pitching moment for static stability, pitch/yaw damping to kill wobble, roll damping to decay axial
spin, AoA-dependent drag, and gyroscopic precession. Use it when orientation matters — sniper
rounds that must nose toward velocity, spinning shells that precess, guided missiles, or any context
where the bullet's attitude is visible or physically significant.

For most game projectiles — standard pistol or rifle fire, grenades, arrows — the simpler drag and
Magnus stack is sufficient and dramatically cheaper to evaluate. Reserve 6DOF for bullets where the
attitude physics actually changes gameplay or presentation.

---

**My bullet doesn't curve or react to angle of attack at all.**

Check three things in order:
1. `SixDOFEnabled = true` via `:SixDOF():Enabled(true)`
2. `LiftCoefficientSlope > 0` — lift defaults to `0`, which disables it entirely
3. `ReferenceArea > 0` — this scales all aerodynamic forces; if it is zero, no force reaches the solver

Also confirm `BulletMass > 0` via `:Physics():BulletMass()`. `:Build()` returns `nil` if mass is
zero when 6DOF is enabled.

---

**The bullet immediately tumbles or spins out of control.**

`MomentOfInertia` is likely too small, or `PitchDampingCoeff` is `0`. Without damping, every
aerodynamic torque permanently accumulates angular velocity, compounding each step. Add
`PitchDampingCoeff` first — `0.02` is a safe starting value — then adjust `MomentOfInertia`
until the wobble response feels right. A stiffer restoring torque via `PitchingMomentSlope`
(negative values) also helps stabilise the bullet.

---

**Why is `BulletMass` required for 6DOF but optional in standard casts?**

Standard casting integrates velocity directly (`v += a * dt`) using drag coefficients that are
already tuned to produce the right velocity change — mass is never needed. 6DOF produces raw
aerodynamic force vectors that must be converted to acceleration via `a = F / m`. Zero mass would
produce a division by zero.

---

**What units does `AirDensity` use, and what values should I use?**

kg/m³. The default is `1.225` (sea level, 15°C). Common reference values:

| Altitude | Density |
|----------|---------|
| Sea level | 1.225 |
| 2 km | 1.007 |
| 4 km | 0.819 |
| 8 km | 0.526 |

Lower values reduce all aerodynamic forces proportionally — useful for high-altitude engagements or
environments with thin atmosphere.

---

**Can I use 6DOF without Magnus spin?**

Yes. `InitialAngularVelocity` can seed axial spin directly without setting
`:Magnus():SpinVector()`. If neither is set, the bullet starts with zero angular velocity and only
develops spin from aerodynamic torques, which is physically correct for an unspun round. Set
`SpinMOI > 0` only if you need gyroscopic precession.

---

**Does 6DOF work in `newParallel()`?**

Yes — all 6DOF computation is pure math with no Instance access or cross-Actor callbacks.
`InitialOrientation` and `InitialAngularVelocity` are passed by value and serialized correctly.
There's no parallel-specific penalty beyond the extra math per step.

---

## Performance

**When should I use `Vetra.newParallel()` instead of `Vetra.new()`?**

Once you have roughly 50+ bullets in flight simultaneously. Below that, the Actor messaging
overhead costs as much as the work being parallelised. Above it, the parallel version scales
dramatically better — at 1,000 bullets it's roughly 10× faster, at 5,000 it's 32×. See the
[Benchmarks](./guides/benchmarks) page for the full data.

---

**`newParallel` but `CastFunction` doesn't work. Why?**

Functions can't cross Actor boundaries via Roblox's message passing API. The parallel solver
dispatches work to Actor shards via `SendMessage`, which can only carry serializable data — not
function references. Use `Vetra.new()` if you need a custom cast function.

---

**How many Actor shards should I use?**

Start at `4`–`6`. More shards don't always mean more throughput — there's a coordination overhead
per shard, and eventually you hit diminishing returns. The benchmark was run at 64 shards and the
parallel frame time was still flat below 10ms at 20,000 bullets, so for most games the default of
`4` is enough.

---

**The parallel solver fell back to serial without me noticing.**

If internal Actor construction fails, `newParallel` falls back silently and logs an error. Check
the Output window. The solver still works — you just won't get parallel performance.

---

## Networking

**Do I have to register behaviors in the same order on client and server?**

Yes, strictly. Fire payloads carry only a 2-byte u16 hash. Both sides assign hashes sequentially by
registration order. If they differ, every fire request will be rejected as `RejectedUnknownBehavior`.
Enforce this by requiring the same shared `ModuleScript` on both sides — never register
conditionally or in environment-specific order.

---

**Why am I seeing `RejectedOriginTolerance` for legitimate players?**

Your `MaxOriginTolerance` is probably too tight for the ping your players are experiencing. The
server reconstructs where the player could plausibly have been at the fire timestamp — on a 150ms
connection, character position can drift a meaningful number of studs in that window. Start at
`20`–`25` studs and loosen if you're seeing false rejections from players you trust.

---

**`OnValidatedHit` fires with `result = nil`. Is that normal?**

Yes. When a bullet expires by distance or speed (rather than hitting a surface), `result` is `nil`.
Always check before reading `result.Instance` or `result.Position`.

---

**Can VetraNet handle shotguns that fire multiple pellets simultaneously?**

Yes. Each pellet is a separate `Net:Fire()` call with its own `BulletContext`. Each one counts
against the player's `MaxConcurrentPerPlayer` limit, so shotguns with many pellets deplete that
budget faster. Size `MaxConcurrentPerPlayer` to account for your maximum burst — for a 12-pellet
shotgun with a 20-round limit you'd want at least `24`+.

---

## Signals

**`OnTravel` is causing performance issues. What should I do?**

Switch to `OnTravelBatch`. Instead of one signal emission per cast per frame, you get one emission
with all travelling casts in a single table. This eliminates per-cast signal overhead and lets you
iterate them yourself in one pass. Also make sure your `OnTravel` handler isn't doing expensive
work — it runs on the `Fire` path, not `FireSafe`, so it must not throw or yield.

---

**I cancelled termination in `OnPreTermination` but the bullet died anyway.**

The 3-strike rule. Each termination reason is tracked separately — after 3 consecutive cancels for
the same reason, the bullet is force-terminated regardless. This prevents infinite loops from
handlers that always cancel. The counter resets to zero on any non-cancelled termination.

---

**Is it safe to call `Solver:Fire()` from inside an `OnHit` handler?**

Yes — signal handlers run on the main thread and `Fire()` is safe to call re-entrantly. The new
cast is added to the active list and stepped on the next frame.

---

## Comparisons

**How is Vetra different from FastCastRedux?**

FastCastRedux was the standard for Roblox projectiles for years and it earned that position — it
introduced the analytic trajectory model that Vetra builds on. But it has hard architectural limits
that can't be patched around.

The most immediate is cost. FastCastRedux connects a **new RunService event for every single
bullet**. Fire 100 bullets and you have 100 live RunService connections, each ticking every frame
independently. Vetra uses a single loop per solver that steps all active casts in one pass — the
cost scales with bullet count, not with connection overhead.

Beyond performance, FastCastRedux has no bounce, no drag, no homing, no Magnus effect, no Coriolis,
no tumble, no fragmentation, no LOD, no spatial partitioning, no server-side validation, and no
networking layer. It handles pierce and travel, and that's the extent of the physics surface.
Building a weapon system on top of it means writing all of that yourself, and the absence of a
typed builder means every behavior is a raw table with no validation.

FastCastRedux is also no longer actively maintained. The author has said so publicly. Bug reports go
unanswered.

Finally, FastCastRedux is written with `--!nocheck` — Luau's strict mode is explicitly disabled.
There is no type safety. Vetra is written `--!strict` throughout.

---

**How is Vetra different from FastCast2?**

FastCast2 is a community fork of FastCastRedux that adds Spherecast / Blockcast support, a
built-in object cache, and parallel scripting via Actors. It's a genuine improvement over the
original in those specific areas. But several significant issues remain.

**Features.** FastCast2 still has no bounce, no drag, no homing, no Magnus, no Coriolis, no tumble,
no fragmentation, no LOD, no spatial partitioning, no server-side hit validation, and no networking
layer. `CastFunction` in Vetra already covers Spherecast and Blockcast without needing separate
API surface.

**The parallel implementation.** FastCast2's Actor-based parallel scripting attempts to pass the
full behavior table — including `CanPierceFunction` and other function callbacks — over Actor
message boundaries. Functions cannot be serialized across Actor boundaries in Roblox's parallel
system. The callbacks either silently fail or produce errors at runtime. Vetra's parallel solver
handles this correctly by running all user callbacks on the main thread after each parallel physics
pass, so `CanBounceFunction`, `CanPierceFunction`, and `HomingPositionProvider` always work
regardless of which solver you're using.

**The license.** FastCast2 ships under **CC BY-NC-ND 4.0** for its original content. That license
prohibits commercial use and prohibits derivatives. If you're building a game that generates revenue
— through game passes, developer products, or any other monetization — FastCast2's license terms
restrict that use. Vetra is MIT. Use it however you want.

**Stability.** FastCast2 is at version 0.0.9. It's actively changing and the API is not stable.

The short version: FastCast2 is a community effort to keep FastCastRedux alive and that's worth
something. But it starts from the same architectural foundation, carries the same feature gaps, and
adds a licensing constraint that makes it unsuitable for commercial projects.

---

**How does Vetra's 6DOF compare to other Roblox ballistics systems?**

No other publicly available Roblox projectile library implements six-degrees-of-freedom
aerodynamics. FastCastRedux and FastCast2 both lack it entirely — their physics model is a point
mass with no orientation, no aerodynamic torque, and no angular dynamics. There is no pathway to
add 6DOF to either without replacing the solver core.

Outside Roblox, the reference model for 6DOF projectile simulation comes from small-arms research
(McCoy's *Modern Exterior Ballistics*, the BRL 6DOF model). Vetra covers the same fundamental
forces:

| Force / moment | Vetra field |
|----------------|-------------|
| Lift (dCL/dα) | `LiftCoefficientSlope` |
| Pitching moment (dCm/dα) | `PitchingMomentSlope` |
| Pitch/yaw damping (Cmq) | `PitchDampingCoeff` |
| Roll damping (Clp) | `RollDampingCoeff` |
| AoA-dependent drag | `AoADragFactor` |
| Gyroscopic precession | `SpinMOI` + spin seeded from `Magnus.SpinVector` |

The main simplification relative to a full BRL model is the linearisation with AoA — coefficients
scale as `CLα·sin(α)` rather than being resolved against a full Mach-indexed table. For game
projectile trajectories where small-angle flight dominates, this is the right tradeoff. When you
need Mach-variable coefficients, the `CLAlphaMachTable`, `CmAlphaMachTable`, `CmqMachTable`, and
`ClpMachTable` fields let you supply your own lookup tables. For ballistic research or
extreme-range simulation, a dedicated exterior ballistics tool is still more appropriate.

For Roblox games, Vetra V6 is the only option that offers this level of physical fidelity in a
maintained, MIT-licensed, production-ready library.

---

**Can I migrate from FastCastRedux or FastCast2 to Vetra?**

Yes, and it's usually straightforward because the conceptual model is similar. Both use an analytic
trajectory with per-bullet state, a pierce callback, and cosmetic bullet support. The main
differences in practice:

- Signals are on the **solver** in Vetra, not on each caster instance. Connect once, receive events
  from all bullets.
- Behaviors are built with `BehaviorBuilder` or passed as raw tables to `Solver:Fire()` — not stored
  on the caster.
- Bounce, drag, and other physics features are new fields. You don't need to rework existing pierce
  and travel logic to add them.
- If you were using PartCache with FastCastRedux, replace it with a `CosmeticBulletProvider`
  function that retrieves from your own pool.

There's no automated migration tool. But most FastCastRedux weapon scripts are short enough that
rewriting to Vetra's API takes less than an hour.


**How do I see where bullets are going?**

Enable the visualizer:

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Debug()
        :Visualize(true)
    :Done()
    :Build()
```

This draws cast segments, hit normals, bounce vectors, and corner-trap markers directly in the
world. Zero runtime cost when disabled.

---

**A bullet is getting stuck bouncing in a corner forever.**

Corner-trap detection handles this — it terminates bullets that are oscillating between surfaces.
If it's not triggering, your `CornerTimeThreshold`, `CornerDisplacementThreshold`, or
`CornerEMAThreshold` values may be too loose for your geometry. Tighten them, or reduce
`CornerPositionHistorySize` to make the detector more aggressive. The Grenade preset has
corner-trap tuned for tight-space ricochets and is a good reference starting point.

---

**How do I tell which bullet fired a specific signal?**

Every signal handler receives `context` as its first argument — the `BulletContext` that was passed
to `Solver:Fire()`. Use `context.Id` for a unique integer identifier, or attach your own identifier
to `context.UserData` before firing.