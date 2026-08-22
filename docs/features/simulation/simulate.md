---
sidebar_position: 3
title: Simulate (internals)
---

# Simulate

:::note Internals
This page describes how Vetra is built, not an API you call. Nothing here is configurable. If you
just want bullets to stop passing through walls, read [Tunnelling](./tunnelling) and
[High Fidelity](./high-fidelity) instead.
:::

`Simulate` is the per-frame step body, one advance of a single cast from where it was to where it
should be this frame, then one raycast across that hop. It is the unit of work every other path is
built from: the single-hop case calls it once, the [high-fidelity](./simulate-high-fidelity) case
calls it many times per frame, and the parallel worker mirrors it in a pure form.

---

## Serial: `SimulateCast.StepProjectile`

On the serial solver (`Vetra.new()`) the frame loop calls `StepProjectile` once per active cast.
It decides *how* to step, then delegates the actual advance to the shared step body.

### 1. Resolve the step delta (LOD / spatial throttling)

Before stepping, `StepProjectile` asks whether this cast is throttled. A cast beyond `LODDistance`,
or in a cold spatial tier, steps only 1 frame in N, accumulating the skipped deltas. On the frame it
*does* step, `StepDelta` is the whole accumulated span, not a single frame, so the analytic catch-up
covers the full gap in one advance. A cast that isn't throttled steps with the raw frame delta.

### 2. Choose single-hop vs high-fidelity

```lua
local UseHighFidelity =
    Behavior.HighFidelitySegmentSize > 0
    and Runtime.CurrentSegmentSize > 0
    and not Runtime.IsLOD
```

- **High-fidelity** -> hand the frame's span to [`ResimulateHighFidelity.Execute`](./simulate-high-fidelity),
  which subdivides it and calls the step body once per sub-segment.
- **Single hop** -> call the step body once for the whole frame.

Note HF is gated off while the cast is in LOD: a throttled bullet is far away and cheap coverage
matters more than thin-wall precision there.

### 3. The shared step body

Whether it runs once or many times, each advance does the same sequence:

1. **Advance the clock.** `ElapsedBeforeAdvance -> ElapsedAfterAdvance`, and derive `LastPosition`,
   `CurrentTargetPosition`, `CurrentVelocity` analytically from the active trajectory
   (`PositionAtTime` / `VelocityAtTime`), or from a `TrajectoryPositionProvider` if one is set (it
   is probed at three times, last / current / current + epsilon, the epsilon pair giving velocity).
2. **Apply per-step physics.** Homing may open a new trajectory segment; Coriolis bends the velocity
   and recomputes the target. Drag / Magnus / gyro recalculation happens on their own cadence
   (`DragSegmentInterval`), not every step.
3. **Tumble / sonic transitions.** Speed-threshold crossings and tumble begin/recover are evaluated
   from the new speed.
4. **The raycast.** If an occupancy grid reports the segment clear, the raycast is skipped entirely.
   Otherwise it fires through `Behavior.CastFunction` (default: `workspace:Raycast`) from
   `LastPosition` to `CurrentTargetPosition`.

   The origin is nudged back by a magnitude-scaled epsilon first, see
   [Tunnelling & Precision](./tunnelling#the-second-trap-rays-that-land-exactly-on-a-surface) for
   why. `DistanceCovered` and travel are still measured from the true `LastPosition`.
5. **React.** A hit runs the bounce / pierce / terminate machinery; a clear step fires `OnTravel`,
   advances `DistanceCovered`, and moves any cosmetic bullet.

### Sub-segment reuse

High-fidelity doesn't have its own physics, it calls this same body with `IsSubSegment = true` and a
fraction of the frame delta. `IsSubSegment` suppresses the things that must happen once per frame
(e.g. the provider-yield warning path), so N sub-segments produce one frame's worth of side effects,
not N.

---

## Parallel: `Parallel/Physics/Step`

The parallel worker can't touch solver state or fire signals from inside an Actor, so its equivalent
of the step body is a **pure function**: `Step(Snapshot, FrameDelta)` takes a plain snapshot of the
cast and returns a plain result describing what happened, no `Solver`, no `Cast` handle, no signals.

It runs the same logical sequence, clock advance, physics, occupancy check, the ulp-scaled ray
back-off, one raycast, and returns one of a small set of event records (`travel`, `hit`,
`bounce_pending`, `pierce_pending`, terminal ends, `skip`). The worker packs that record into a
shared buffer; the coordinator drains it on the main thread and runs the same reaction logic
`SimulateCast` would have run inline. LOD / spatial resolution is factored out into `LODSpatial`
and called by the worker before `Step`, rather than living inside it.

So the split is: **serial does decide-step-react in one call stack; parallel does decide + step on
the worker and react on the coordinator**, with `Step` as the pure middle. The physics is identical
by construction, which is why a bug in one path (the ray-origin seam) reproduced in the other the
moment the clocks matched.
