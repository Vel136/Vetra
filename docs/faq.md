---
sidebar_position: 5
title: FAQ
---

# FAQ

The questions that come up most often, grouped by topic.

---

## General

**What is Vetra?**

A projectile simulation module for Roblox. It handles bullet movement and hit detection, and
provides bounce, penetration, drag, homing, Magnus, tumble, fragmentation, 6DOF aerodynamics, a
parallel solver, and occupancy grids. You configure a behavior, fire a bullet, and react to signals.

**Is Vetra free?**

Yes, MIT licensed. Commercial or otherwise, use it however you want.

**What version is this?**

This documentation covers **Vetra V7.0.0**.

**Does it run on the client, the server, or both?**

Both. `Vetra.new()` connects to the right RunService event automatically, `RenderStepped` on the
client, `Heartbeat` on the server.

---

## Setup

**Where does the Vetra folder go?**

`ReplicatedStorage`, so both client and server can require it. See [Installation](./installation).

**Do I need one solver or many?**

One per independent bullet system. Most games need exactly one. You'd only make several if you had
fundamentally separate contexts, say a server weapon system and a client-only particle system.

---

## Behaviors

**`BehaviorBuilder` vs a raw table passed to `Fire()`, what's the difference?**

They produce the same `VetraBehavior`. The builder adds typed setters, build-time validation, a
frozen result, and dirty-tracked composition (`:Clone()`, `:Impose()`, `:Merge()`). A raw table is
fine for quick tests or one-off fires.

**How do I make weapon variants from a shared base?**

`:Clone()` for an independent copy, then chain setters:

```lua
local Base  = Vetra.BehaviorBuilder.Sniper()
local Heavy = Base:Clone():Pierce():Max(5):Done():Build()
local Light = Base:Clone():Physics():MaxDistance(800):Done():Build()
-- Base is untouched
```

For reusable modifiers, `:Merge(a, b)` is non-destructive (it clones first, then imposes each). Use
`:Impose(other)` to copy only the explicitly-set fields of `other` onto an existing builder.

**I have a frozen behavior from a registry, how do I tweak one field?**

`BehaviorBuilder.Inherit(frozen)` returns a mutable builder with every field pre-populated:

```lua
local tweaked = Vetra.BehaviorBuilder.Inherit(existing)
    :Physics():MaxDistance(2000):Done()
    :Build()
```

**Pierce and bounce both have filters, which runs first?**

Pierce, always. If the pierce filter returns `true`, the bounce filter is never checked for that hit.
They're mutually exclusive per surface contact, see [Penetration](./features/penetration#pierce-and-bounce-together).

**My `CanBounceFunction` runs but the bullet doesn't bounce.**

Check `BounceSpeedThreshold` (below it, hits are terminal and the filter is skipped) and `MaxBounces`
(an exhausted budget skips the filter). Both gate the filter silently. See
[Bounce](./features/bounce#the-speed-floor).

---

## Physics

**My bullets don't drop, or drop when I didn't expect.**

Gravity defaults to `workspace.Gravity`, so bullets fall out of the box. Set `Gravity` explicitly to
override it, including `Vector3.zero` for a completely flat path. Any vector is accepted, so upward
and sideways gravity work too. See [Gravity & Drag](./features/physics/gravity-drag#gravity).

**What is `DragCoefficient`, exactly? A ballistic coefficient?**

No. It's a lumped drag *scale* that plugs into `decel = Coefficient * Cd(mach) * speed^2` (for the
default Quadratic model, `Cd = 1`, so units are `1/studs`). It isn't normalized by mass or air
density, so realistic values are small (~`1e-3`), passing a raw BC stalls the bullet instantly.
Calibrate it by firing and comparing velocity loss. Full detail in
[Gravity & Drag](./features/physics/gravity-drag#what-coefficient-actually-is).

**`MagnusCoefficient` makes my bullet swerve wildly.**

It's extremely sensitive, the force scales with spin *and* speed. Start at `0.00005` and increase
incrementally. See [Magnus & Spin](./features/physics/magnus).

**What is hitscan mode and when should I use it?**

`:Hitscan(true)` resolves the whole path, pierce, bounce, all signals, synchronously inside
`Fire()`, with no per-frame physics. Use it for weapons where the bullet-in-flight is never seen
(SMGs, pistols, railguns). Drag, gravity, Magnus, 6DOF, homing, and `MinSpeed` are ignored. See
[Hitscan](./features/additions/hitscan).

**Which `TerminateReason` values exist?**

`Hit`, `Distance`, `Displacement`, `Speed`, `Manual`, and `CornerTrap`. Compare against
`Vetra.Enums.TerminateReason.Hit` rather than the raw string `"hit"` so a rename surfaces as a nil
rather than a silent mismatch.

---

## 6DOF

**My 6DOF bullet doesn't curve or react to angle of attack.**

Check, in order: `SixDOFEnabled = true`; `LiftCoefficientSlope > 0` (lift is `0` by default);
`ReferenceArea > 0` (it scales all forces); and `BulletMass > 0`. Details in
[6DOF](./features/physics/6dof#troubleshooting).

**Why is `BulletMass` required for 6DOF but optional otherwise?**

Standard casting integrates velocity directly with pre-tuned drag coefficients, mass is never
needed. 6DOF produces raw force vectors that become acceleration via `a = F/m`, so zero mass is a
division by zero. `:Build()` returns `nil` if mass is zero while 6DOF is on.

**The bullet immediately tumbles out of control.**

`MomentOfInertia` is likely too small, or `PitchDampingCoeff` is `0` (undamped torque accumulates
forever). Add damping first (`0.02` is a safe start), then tune inertia.

**Does 6DOF work in `newParallel()`?**

Yes, it's pure math with no Instance access, serializes by value, and has no parallel-specific
penalty.

---

## Performance

**When should I use `Vetra.newParallel()` instead of `Vetra.new()`?**

Once you have roughly 25,50+ bullets in flight for travel-only work (more for callback-heavy
behaviors). Below that, Actor coordination costs as much as it saves. Above it, the parallel solver
scales far better and its per-frame time stays flat. Benchmark against your own scene, see
[Parallel Solver](./features/optimizations/parallel).

**How many shards should I use?**

`ShardCount` defaults to `4`, which is enough for most games. Try `4`,`8`; more shards add
coordination overhead and hit diminishing returns.

**`newParallel` but my `CastFunction` doesn't work.**

Functions can't cross Actor boundaries via Roblox's message passing, so `CastFunction` is ignored by
the parallel solver. Use `Vetra.new()` if you need a custom cast function.

**The parallel solver fell back to serial silently.**

If Actor construction fails internally, `newParallel` falls back to serial and logs an error, check
the Output window. Your solver still works; you just don't get parallel performance.

**My bullets crawl in slow motion when many are active.**

High-fidelity mode under load: the frame budget is shared across all HF bullets, so once it's spent
the remaining bullets stop part-way through their sub-segment loop and advance only a fraction of the
frame delta. That's the throttle working as designed, but it looks like slow motion. Reserve HF for
bullets that truly need thin-wall precision, raise `HighFidelitySegmentSize` so fewer sub-segments
are needed, or lean on an [occupancy grid](./features/optimizations/occupancy/static) to collapse
raycasts.

**My spatial partition isn't saving anything.**

Almost always `FallbackRate` (legacy name: `FallbackTier`). It must be a number (`4` = every 4th
frame), not the string `"COLD"`, passing a non-number warns and defaults to `1`, so distant bullets
never down-step. Also remember `HotRadius` / `WarmRadius` are in **cells**, not studs. See
[Spatial Partitioning](./features/optimizations/spatial).

---

## Signals

**`OnTravel` is expensive with many bullets.**

Enable `BatchTravel` on the behavior (`:BatchTravel(true)`). Instead of firing `OnTravel` once per
cast per frame, travelling casts accumulate into a batch that's flushed once per frame through
`OnTravelBatch`, one emission with all of them in a table you iterate yourself. Travel handlers on
either signal **must not throw or yield**, an error will propagate. Keep them cheap and
non-yielding.

**I cancelled termination in `OnPreTermination` but the bullet died anyway.**

Two possible causes. The 3-strike rule: each reason is tracked separately, and after 3 consecutive
cancels for the same reason the bullet is force-terminated. This prevents infinite loops from
always-cancel handlers. The counter resets on any non-cancelled termination.

The other: something called `Cast:Terminate()` or `BulletContext:Terminate()` directly. Manual
terminations skip `OnPreTermination` entirely and cannot be cancelled. To confirm, check the second
argument to `OnTerminated`, a manual kill reports `reason = "manual"`.

**Is it safe to call `Solver:Fire()` from inside a signal handler?**

Yes. Handlers run on the main thread and `Fire()` is re-entrant; the new cast is added to the active
list and stepped next frame.

**How do I tell which bullet fired a signal?**

Every handler receives `context` (the `BulletContext` you passed to `Fire()`) as its first argument.
Use `context.Id` for a unique integer, or attach your own key to `context.UserData` before firing.

---

## Occupancy

**When is an occupancy grid worth baking?**

When most bullet segments cross empty air, long-range fire, open maps, dense volleys. The grid
collapses those into cheap voxel walks and skips the raycast. It helps little when bullets hug
geometry (every segment touches an occupied voxel anyway). See
[Static Occupancy](./features/optimizations/occupancy/static).

**Static vs dynamic, which do I need?**

Static for the unmoving world (bake once). Dynamic for moving rigid parts, doors, vehicles, where
each part is baked once and only its transform is refreshed per frame. They compose: a segment is
skipped only when clear of *both*. See [Dynamic Occupancy](./features/optimizations/occupancy/dynamic).

**Can a grid make a bullet miss a wall it should hit?**

Yes, if the wall isn't represented in the grid. Once a grid is attached it acts as a **filter**: when
it reports a segment clear, the raycast is skipped entirely, and a skipped raycast can't hit
anything. A segment reads clear when every voxel along it is empty, or when it lies entirely outside
the grid's baked bounds.

So a wall that was never baked, is outside the baked region, is tagged `VetraOccIgnore`, or was added
after the bake, is **invisible to bullets**, they pass straight through. Not baking something doesn't
hand it to the normal raycast path, it removes it from the bullet's world. Bake everything you need
bullets to collide with, and re-bake when static geometry changes. See
[Static Occupancy](./features/optimizations/occupancy/static).

**Can a bullet pass through a wall it should hit?**

Two ways, both handled. The first is **tunnelling**: on a curving shot the straight A-B ray for a
frame is only the *chord* of the arc, and a wall the arc crosses but the chord misses goes untested.
Solved by [high-fidelity sub-segments](./features/simulation/tunnelling) that hug the true path.
The second is a Roblox raycast quirk: a ray can't see a surface within ~1 float32 rounding step of
its origin, and its endpoint is exclusive to the same tolerance, so a wall face landing exactly on a
frame boundary can slip through the seam between two consecutive rays. Vetra nudges every internal
ray origin back by a magnitude-scaled epsilon so the rays overlap and nothing can hide in the gap;
the endpoint stays exact, so it never reports a hit early. You don't configure either, both the
serial and parallel solvers apply it. The one exception is a **custom `CastFunction`**, see below.
