---
sidebar_position: 3
title: Hitscan
---

# Hitscan

Hitscan resolves a bullet's **entire path synchronously inside `Fire()`**, no per-frame stepping,
no gravity, no drag. The bullet travels in straight lines between bounces and terminates before
`Fire()` returns. By the time the call finishes, `OnHit` has already fired.

Use it for weapons where the bullet arriving instantly *is* the point: railguns, lasers, instant-hit
scanners, SMGs and pistols whose rounds are never visible in flight.

---

## Enabling It

`Hitscan` is a top-level builder switch, not a sub-builder:

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Hitscan(true)
    :Physics()
        :MaxDistance(1000)
    :Done()
    :Build()

Solver:Fire(context, Behavior)
-- OnHit has already fired by the time this line runs.
```

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:Hitscan(b)` | `IsHitscan` | `false` | Resolve the whole path synchronously in `Fire()`. |

---

## What Still Works

Hitscan isn't "just a raycast", it runs the **full hit chain**, only synchronously:

- **Pierce and bounce** both apply. `CanPierceFunction` and `CanBounceFunction` are respected, and
  the bullet can pierce and ricochet through multiple surfaces in a single `Fire()` call.
- **All signals fire** in the normal order, `OnHit`, `OnBounce`, `OnPierce`, `OnTerminated`, just
  before `Fire()` returns rather than across frames.

The corner-trap detector, termination cancelling, and fragment spawning all behave as they do for a
physics cast.

---

## What Doesn't Apply

Because distance is consumed in one pass instead of stepped per frame, **anything speed- or
time-dependent is ignored**:

- `DragCoefficient`, `SpinVector` / `MagnusCoefficient`, gravity, [6DOF](../physics/6dof), homing,
  and tumble have no effect.
- `MinSpeed` and drag-based speed attenuation don't apply, the bullet doesn't decelerate.

:::caution Need a fast bullet *with* physics?
Don't reach for hitscan. Increase the projectile's `Speed` and lower its `MaxDistance` instead, you
keep drop, drag, and every other force while still resolving almost instantly.
:::

---

## Choosing Between Hitscan and a Fast Cast

| You want... | Use |
|-----------|-----|
| Instant arrival, no bullet-in-flight, no physics | **Hitscan** |
| A visible tracer that travels, with drop/drag | A physics cast with high `Speed` |
| Instant hits through cover (railgun) | **Hitscan**, full pierce/bounce chain resolves at once |
| Bullet drop or velocity-based damage falloff | A physics cast (drag is ignored under hitscan) |
