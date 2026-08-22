---
sidebar_position: 4
title: SimulateHighFidelity (internals)
---

# SimulateHighFidelity

:::note Internals
This page describes how the subdivision loop is implemented. For the settings you actually configure
(`SegmentSize`, `FrameBudget`, and friends), see [High Fidelity](./high-fidelity).
:::

High-fidelity stepping subdivides one frame's travel into many short raycasts that hug the true
trajectory, so a curving bullet can't chord past geometry its arc crosses (see
[Tunnelling & Precision](./tunnelling)). It has no physics of its own, it drives
[`Simulate`](./simulate)'s step body once per sub-segment, under a time budget.

---

## Serial: `ResimulateHighFidelity.Execute`

Called by `StepProjectile` when a cast is high-fidelity (`HighFidelitySegmentSize > 0`,
`CurrentSegmentSize > 0`, not in LOD). It receives the frame's span and total displacement.

### 1. Decide the sub-segment count

```lua
local DesiredSubs     = math_floor(FrameDisplacement / CurrentSegmentSize)
local SubSegmentCount = math_clamp(DesiredSubs, 1, HF_SUBSEGMENT_SOFT_CAP)
```

The frame's travel is cut into pieces no longer than `CurrentSegmentSize` studs, so the largest
surface a bullet can skip shrinks to that value. `HF_SUBSEGMENT_SOFT_CAP` is a hard ceiling so a
single slow frame (a big `FrameDisplacement`, e.g. after a hitch) can't request thousands of rays.

### 2. The clear-span fast path

Before subdividing, if an occupancy grid can prove the **entire** frame span is clear, and no
per-step physics forces a recalculation that frame (drag / Magnus / 6DOF / homing), the whole
subdivision collapses to `SubSegmentCount = 1`. There's nothing to hit along the span, so one nominal
step is enough. This is the common case in open air and is what keeps HF affordable.

### 3. Step the sub-segments under budget

```lua
local SubSegmentDelta = FrameDelta / SubSegmentCount
for _ = 1, SubSegmentCount do
    local t0 = os_clock()
    SimulateCast.StepProjectile(Solver, Cast, SubSegmentDelta, true)  -- IsSubSegment = true
    FrameBudget.Consume(Budget, os_clock() - t0)

    if not Cast.Alive then break end          -- a sub-segment hit ended the cast
    if FrameBudget.IsExhausted(Budget) then break end
end
```

Each sub-segment is a full step body with `IsSubSegment = true`, so per-frame-only side effects
aren't repeated. Two things end the loop early: the cast **hitting** something (terminate machinery
already ran inside the step), or the shared **frame budget** running out. The budget is per-solver
and shared across every HF bullet, so a frame with many HF bullets divides the time between them,
one bullet can't starve the rest.

### 4. Adapt the segment size

After the loop, `CurrentSegmentSize` is nudged toward the budget for next frame:

- Over `HighFidelityFrameBudget` ms -> **grow** segment size by `AdaptiveScaleFactor` (fewer, longer
  rays next time), capped at `MaxDistance`.
- Under half budget, and not budget-limited, and didn't collapse -> **shrink** by
  `AdaptiveScaleFactor` (finer coverage), floored at `MinSegmentSize`.

So thin-wall coverage self-tunes to what the frame can afford: cheap frames buy more precision,
expensive frames back off rather than tanking the framerate. `MinSegmentSize` is the guarantee, the
controller never coarsens below it.

:::caution Re-entrancy guard
`IsActivelyResimulating` is set for the duration of `Execute`. If a sub-segment step somehow
re-entered high-fidelity resimulation, that's a cascade bug, the guard terminates the cast and
errors rather than recursing.
:::

---

## Parallel: `Parallel/Physics/StepHighFidelity`

The parallel worker's equivalent is `StepHighFidelity(Snapshot, StepDelta, ...)`, a **pure
function** mirroring the serial loop without touching solver state or signals. Same shape:

- **Sub-segment count** from `FrameDisplacement / CurrentSegmentSize`, clamped to the same soft cap.
- **Clear-span fast path**, if occupancy proves the span clear it returns a single travel result
  from a reused `_FastResult` buffer (avoiding a per-frame allocation once raycasts collapse).
- **Budgeted sub-segment loop**, but against a per-worker microsecond budget passed in, rather than
  the serial shared `FrameBudget`. Each sub-segment raycast applies the same ulp-scaled
  [ray-origin back-off](./tunnelling#the-second-trap-rays-that-land-exactly-on-a-surface).
- Instead of firing signals inline, it **returns** the first terminal event (hit / bounce / pierce /
  distance end) it encounters, or a travel result if the whole span was clear. The coordinator runs
  the reaction on the main thread.

### A note on the two budgets

Serial throttles HF through the shared per-frame `FrameBudget`, so under load a serial HF bullet may
do only a fraction of its sub-segments. The parallel worker has its own budget and its own thread, so
it isn't competing with the main-thread frame time. This is why parallel HF can *look* slower in a
naive benchmark (it does the full work) while actually being faster per unit of work, the serial
number is small because it's doing less, not because it's cheaper.
