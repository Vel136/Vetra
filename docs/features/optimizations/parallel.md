---
sidebar_position: 4
title: Parallel Solver
---

# Parallel Solver

`Vetra.new()` steps every cast on the main thread, one after another. `Vetra.newParallel()`
distributes the physics across multiple Roblox **Actors**, separate execution contexts that run
concurrently on different cores. Raycasts, drag, Magnus, homing, bounce math, and corner-trap
detection all happen in parallel; signal firing and user callbacks are flushed on the main thread
afterward.

The API is identical to the serial solver, same `Fire`, same signals, same behaviors. You change
one constructor call and nothing else.

```lua
local Solver = Vetra.newParallel({
    ShardCount = 6,   -- number of Actor shards; 4 is the default
})

Solver:Fire(context, Behavior)   -- exactly as with Vetra.new()
```

| Config key | Default | Description |
|------------|--------:|-------------|
| `ShardCount` | `4` | Number of Actor shards work is distributed across. |
| `SpatialPartition` |, | Same [spatial partition](./spatial) config as the serial solver. |

---

## When It's Worth It

Parallelism has a fixed cost: work must be handed to shards and results gathered back. Below a
threshold, that coordination costs as much as the work it saves.

- **At small counts (tens of bullets)**, the serial solver is usually as fast or faster. Use
  `Vetra.new()`.
- **At volume**, parallel pulls ahead. Measured, it runs roughly **1.6x to 2.4x** faster than serial
  across most configurations, about **2.09x** at 20,000 plain casts and **2.41x** with 6DOF enabled.

The gain is largest where there's the most math to spread across cores: [6DOF](../physics/6dof) is
the standout. It is *not* a magic multiplier that grows without bound, parallel frame time still
rises with bullet count; it just rises more slowly than serial.

**Two cases where parallel does not help:**

- **Homing / provider-driven bullets**, measured at **0.97x** (marginally slower than serial). These
  are forced onto the sync path, so the provider runs on the main thread every frame and you pay
  coordination overhead without gaining parallelism.
- **LOD-heavy scenes**, LOD reclaims ~1.30x on serial but essentially nothing on parallel (1.00x),
  because the raycasts it skips were already spread across cores.

See [Benchmarks](./benchmarks) for the full measured tables.

:::note Verify against your own scene
Those numbers are Studio measurements at `ShardCount = 16`. Exact crossover points depend on your
geometry, behaviors, and hardware, benchmark your real weapon behaviors rather than relying on a
single headline number.
:::

---

## Sync vs Fire-and-Forget

**Both kinds run their physics inside the workers**, the main thread never steps a cast. The
difference is who drives the step, and how much comes back each frame.

The parallel solver classifies every bullet as one of two kinds, automatically:

- **Sync**, stepped in the worker but driven by the Coordinator, which dispatches the step each frame
  and reads a result back. Required when the bullet has a callback the main thread must run,
  `CanBounceFunction`, `CanPierceFunction`, `CanHomeFunction`, `HomingPositionProvider`,
  `TrajectoryPositionProvider`, or when `VisualizeCasts` is on.
- **Fire-and-forget (FF)**, steps autonomously inside the workers with no per-frame main-thread
  involvement for the physics itself. Terminal events (Hit / DistanceEnd / SpeedEnd) come back to the
  Coordinator, and the Coordinator also extrapolates a position for these casts each frame when
  something needs one, see below.

FF casts have near-zero per-frame overhead, worker-side buffers are reused in place after the first
few frames. They're the fast path for high-volume projectiles that don't need per-frame callbacks.

The classification is entirely about **callbacks**, not travel events. A bullet is FF unless it
carries one of the functions or providers listed above, so plain projectiles are on the fast path by
default and there is nothing to opt into.

```lua
-- FF cast: no callbacks, so it steps autonomously in the workers
local ffContext = Vetra.BulletContext.new({
    Origin = origin, Direction = dir, Speed = 200,
})
Solver:Fire(ffContext, Behavior)

-- Sync cast: the CanBounceFunction must run on the main thread, so the
-- Coordinator drives this cast's step each frame
local SyncBehavior = Vetra.BehaviorBuilder.new()
    :Bounce()
        :Max(3)
        :CanBounceFunction(function(context, result) return result.Instance.CanCollide end)
    :Done()
    :Build()
Solver:Fire(Vetra.BulletContext.new({
    Origin = origin, Direction = dir, Speed = 200,
}), SyncBehavior)
```

### Travel events on FF casts

FF does not mean travel signals are lost. Each frame the Coordinator walks the non-sync casts and
extrapolates a position and velocity from the active trajectory when any of these is true:

- `OnTravel` or `OnTravelBatch` has a listener **and** the behavior's `FireTravelEvents` is `true`
  (the default),
- the cast has a cosmetic bullet object to place, or
- `OnSpeedThresholdCrossed` has a listener and the behavior defines speed thresholds.

So `FireTravelEvents = false` suppresses travel emission for that behavior, but it only removes the
per-frame extrapolation when the cast also has no cosmetic bullet and no speed thresholds. With a
cosmetic attached, that work happens regardless.

The Coordinator skips dispatch entirely for shards containing only FF casts, and skips the
homing/provider update pass when no sync casts are active, so a scene of pure FF bullets pays almost
nothing in coordination.

---

## Events Arrive One Frame Late

This is the most important behavioral difference from `Vetra.new()`, and it's inherent to how the
parallel solver works: **every event the parallel solver delivers, `OnHit`, `OnBounce`, `OnPierce`,
`OnTravel`, terminations, is fired one frame after the frame in which it physically happened.**

The cause is double-buffering. Each Heartbeat, the Coordinator does two things in order:

1. **Reads** the results the workers produced *last* frame (from one buffer bank) and fires their
   signals.
2. **Dispatches** this frame's physics to the workers, which run in parallel and write into the
   *other* bank.

Because the read in step 1 happens before the workers have finished step 2, the output a worker
computes on frame `N` is not read and delivered until frame `N+1`. The main thread reads one bank
while the workers fill the other, then they swap. Fire-and-forget casts have the same one-frame
delay: the worker's parallel step writes their events, and the main thread can only drain them on the
next Heartbeat.

In practice this is a single frame (about 16ms at 60fps) of latency between a bullet striking a
surface and your `OnHit` handler running. It does **not** accumulate, it's a fixed one-frame offset,
and it does not affect physical accuracy, the hit resolves at the correct position and time; you're
just *notified* one frame later.

**When it matters:**

- **Precise timing / instant feedback**, if you need a hit reaction on the exact frame of impact
  (a frame-perfect hitstop, a tight parry window), that one-frame delay is observable. Use
  `Vetra.new()` for those bullets; its signals fire synchronously in the same frame.
- **Reading bullet state from a signal**, the `context` position/velocity in a parallel event
  reflects where the bullet was when the worker computed it (last frame), not the current frame.

**When it doesn't matter:** damage application, VFX, sounds, scoreboards, most gameplay. A single
frame is imperceptible for anything that isn't frame-timing-critical, which is the overwhelming
majority of projectile use.

:::note Serial vs parallel signal timing
`Vetra.new()` fires signals synchronously as it steps each cast, so there is **no** frame delay
there. The one-frame offset is exclusive to `Vetra.newParallel()`. If a design depends on
same-frame hit notification, keep those weapons on the serial solver.
:::

---

## The `CastFunction` Limitation

`CastFunction`, the override for using `Spherecast`, `Blockcast`, or custom cast logic instead of
`workspace:Raycast`, is **ignored by the parallel solver**. Functions can't cross Actor boundaries
via Roblox's message-passing API, which only carries serializable data.

```lua
-- This CastFunction silently does nothing under newParallel:
Solver:Fire(context, {
    CastFunction = function(o, d, p) return workspace:Spherecast(o, 0.5, d, p) end,
})
```

If you need a custom cast function, use `Vetra.new()`. Everything else, drag, Magnus, 6DOF, bounce,
pierce, homing, works identically on both solvers.

---

## Automatic Fallback

If the parallel solver can't construct its Actors internally (for example, Actor parenting fails), it
**falls back to a serial solver automatically** and logs an error. Your call site always receives a
working solver, parallel or serial, so setup code never has to branch. If you expected parallel
performance and aren't seeing it, check the Output window for the fallback error.

---

## Does Everything Work in Parallel?

Yes, with the two documented exceptions above (`CastFunction`, and callbacks forcing the sync path):

- **6DOF**, pure math, no Instance access; serializes and runs with no parallel-specific penalty.
- **Bounce / pierce / homing callbacks**, run correctly, batch-flushed on the main thread after each
  parallel physics pass.
- **Corner-trap, tumble, fragmentation, drag, Magnus, Coriolis, wind**, all supported.
