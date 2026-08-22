---
sidebar_position: 2
title: High Fidelity
---

# High Fidelity

High fidelity is Vetra's answer to [tunnelling](./tunnelling): instead of one straight raycast per
frame, the frame's travel is broken into a series of shorter rays that follow the bullet's real
curved path. It's on by default, and for most games the defaults are fine. This page is for when
they aren't.

---

## How It Works

Every frame, a bullet moves some distance. High fidelity divides that distance into pieces no longer
than `SegmentSize` studs and casts a ray across each piece in turn:

```
SubSegments = floor(FrameDisplacement / SegmentSize)
```

That formula is the whole feature, and it's worth understanding because it explains the cost:

- A bullet moving **2 studs** this frame with `SegmentSize = 0.5` casts **4** rays.
- The same bullet moving **0.3 studs** casts **1** ray, the same as having HF off.

So the cost scales with **how far the bullet actually moved**, not with a fixed rate. Slow bullets
and small frame deltas cost almost nothing extra. Fast bullets, and hitches where a frame covers a
lot of ground, automatically get more rays, which is exactly when you need them.

There is a ceiling: a single frame will never subdivide past an internal cap, so one catastrophic
frame spike can't request thousands of raycasts.

---

## Setting It Up

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :HighFidelity()
        :SegmentSize(0.5)      -- max studs per ray
        :FrameBudget(4)        -- max ms/frame spent subdividing
        :AdaptiveScale(1.5)    -- how fast it adapts to the budget
        :MinSegmentSize(0.1)   -- floor the adaptive controller won't go below
    :Done()
    :Build()
```

| Setting | Default | What it does |
| --- | --- | --- |
| `SegmentSize` | `0.5` | Max length of one ray. Smaller = more rays = tighter path following. `0` disables HF. |
| `FrameBudget` | `4` | Milliseconds per frame the solver may spend on sub-segments, shared across all HF bullets. |
| `AdaptiveScale` | `1.5` | How aggressively segment size grows/shrinks to stay near budget. Must be `> 1`. |
| `MinSegmentSize` | `0.1` | The adaptive controller will not coarsen beyond this. Must be `<= SegmentSize`. |

`:HighFidelity()` also carries `:MaxBouncesPerFrame(n)` (default `10`), a cap on how many bounces a
single bullet may resolve in one frame, which matters when a bullet is trapped in a tight corner.

### Turning it off

```lua
:HighFidelity():SegmentSize(0):Done()
```

`SegmentSize = 0` disables subdivision entirely, one ray per frame. Reasonable for slow projectiles
(grenades, thrown objects) or bullets that only ever meet thick geometry.

---

## Choosing a Segment Size

`SegmentSize` is the only setting most games need to think about. The trade is simple: **smaller
follows the true path more closely and costs more rays.**

| Situation | Try |
| --- | --- |
| Thin geometry (fences, railings, window frames, thin walls) | `0.1` to `0.3` |
| General purpose, mixed geometry | `0.5` (default) |
| Thick geometry only, or slow projectiles | `1` to `5`, or disable |
| Many bullets, performance-bound | Raise it and lean on `FrameBudget` |

A useful way to think about the value: it's roughly *the finest detail you want the bullet to be able
to notice*. Setting it well below the thinnest thing in your map buys accuracy you can't observe.

:::tip Protection during frame hitches
Because subdivision scales with distance travelled, a **large** `SegmentSize` still acts as insurance
against lag spikes. At a steady 60fps a bullet's per-frame hop may be under the threshold and cost a
single ray; when a hitch makes one frame cover far more ground, it automatically subdivides. You
don't need a separate "enable on slow frames" setting, that behaviour is built in.
:::

---

## The Frame Budget

`FrameBudget` is a ceiling on how much time the solver spends subdividing **per frame, across every
high-fidelity bullet**. When it's spent, remaining sub-segments are skipped for that frame.

That makes it a safety valve rather than a target: it stops a hundred simultaneous bullets from
turning into a frame-rate collapse. If you fire a lot at once, they share the budget rather than
each taking their own.

The solver also **adapts**. It measures how long subdivision actually took, and:

- Over budget, it **grows** segment size (fewer, longer rays next frame).
- Comfortably under, it **shrinks** it back toward your configured value, never below
  `MinSegmentSize`.

So `SegmentSize` is best read as "the accuracy I want when there's time for it" and `MinSegmentSize`
as "the accuracy I insist on regardless". If you need a hard guarantee that bullets can never skip
past something, set `MinSegmentSize`, not just `SegmentSize`.

---

## Interaction With Other Features

**Throttling: LOD and spatial tiers.** A bullet that is being throttled does not use high fidelity.
That covers both [LOD](../optimizations/lod) and cold [spatial](../optimizations/spatial) tiers, and
they're treated the same way for two reasons.

The first is intent. Throttling is a decision that this bullet is unimportant enough to step 1-in-N;
spending sub-segment accuracy on it works against that decision.

The second is cost. A throttled bullet doesn't stop moving, it banks the frames it skipped and covers
the whole banked span in one step. A tier-4 bullet steps once every four frames, and that step
travels about four frames' worth of distance. Since sub-segments scale with distance, running high
fidelity there would ask for roughly four times the raycasts, concentrated on that one frame, and
many bullets releasing together would stack those bursts into a visible hitch.

So if precise thin-wall hits matter at long range, widen the region that stays at full rate: raise
`LODDistance`, or raise `HotRadius` so more of the world stays in the every-frame ring. Don't expect
high fidelity to run on a bullet you've told the solver to throttle.

**Occupancy grids.** If an [occupancy grid](../optimizations/occupancy/static) can prove a whole
frame's span is empty, subdivision collapses to a single step and the raycasts are skipped entirely.
Grids and high fidelity work well together: the grid makes the common empty-air case nearly free, so
the budget is spent only where geometry actually is.

**Parallel solver.** High fidelity works on `Vetra.newParallel()`. Workers each carry their own
budget rather than sharing the serial solver's frame budget, so parallel HF does more work per frame
rather than throttling as aggressively.

---

## When You Still See Tunnelling

If bullets pass through geometry with high fidelity enabled, work down this list:

1. **Is the bullet being throttled?** HF is disabled while throttled, either by LOD or by sitting in
   a slower [spatial](../optimizations/spatial) ring. Check `LODDistance`, and `HotRadius` if you use
   a spatial partition.
2. **Is an occupancy grid attached, and is the geometry baked into it?** An unbaked wall is invisible
   to bullets, the grid reports the span clear and the raycast never happens. See
   [Static Occupancy](../optimizations/occupancy/static).
3. **Is `SegmentSize` larger than the thing you're trying to hit?** Lower it, or lower
   `MinSegmentSize` so the adaptive controller can't coarsen past it.
4. **Is the frame budget saturated?** With many HF bullets, sub-segments get skipped. Raise
   `FrameBudget`, reduce bullet count, or accept coarser accuracy under load.
