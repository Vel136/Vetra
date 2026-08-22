---
sidebar_position: 4
title: Custom Trajectories
---

# Custom Trajectories

Sometimes you don't want physics at all, you want the bullet to follow an exact scripted path. A
custom trajectory replaces Vetra's kinematic solver with a function you write: given the time since
firing, return where the bullet should be. Vetra still raycasts between successive positions, so
hit detection, bounce, and signals all keep working on top of your path.

Use it for spline-driven projectiles, orbiting or spiralling abilities, cinematic shots, or any
movement that isn't "a mass under acceleration."

---

## The Setup

The provider takes **elapsed time** and returns a **world position**. Return `nil` to end the path
and terminate the cast.

```lua
local origin = muzzle.Position
local speed  = 200

local Behavior = Vetra.BehaviorBuilder.new()
    :Trajectory()
        :Provider(function(elapsed)
            -- A rising spiral around the fire axis
            local forward = elapsed * speed
            local wobble  = 6
            return origin
                + Vector3.new(0, 0, -forward)
                + Vector3.new(math.cos(elapsed * 10) * wobble, math.sin(elapsed * 10) * wobble, 0)
        end)
    :Done()
    :Build()

Solver:Fire(context, Behavior)
```

---

## The Provider Signature

**`TrajectoryPositionProvider`**, `(elapsed: number) -> Vector3?`

| Parameter | Type | Description |
|-----------|------|-------------|
| `elapsed` | `number` | Seconds since this cast was fired. |
| **returns** | `Vector3?` | The bullet's world position at `elapsed`, or `nil` to end the path and terminate. |

:::caution Return a `Vector3`, not a `CFrame`
The provider returns a **position vector**. If you're composing the path with `CFrame` math, take
its `.Position` before returning.
:::

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:Provider(fn)` | `TrajectoryPositionProvider` | `nil` | The scripted position function. Setting it takes over from the kinematic solver. |

---

## What Still Works

Because Vetra raycasts between each pair of returned positions, a custom-trajectory bullet still
participates in the interaction layer:

- **Hit detection** runs on the segment between the previous and current position each frame.
- **Bounce and pierce** resolve on those hits exactly as they would for a physics cast (subject to
  your filters).
- **All signals**, `OnTravel`, `OnHit`, `OnBounce`, `OnPierce`, `OnTerminated`, fire normally.

---

## What Doesn't Apply

The physics forces are bypassed entirely, you're defining position directly, so gravity, drag,
Magnus, tumble, and 6DOF have nothing to act on. If you want *most* of the physics but a small custom
nudge, don't use a trajectory provider; instead adjust a live bullet from a signal handler with
[`VetraCast`](/api/VetraCast)'s `SetVelocity` / `SetAcceleration` / `SetPosition`.

:::note Provider runs on the main thread in parallel
Like homing, a `TrajectoryPositionProvider` forces a bullet onto the **sync** path under
`Vetra.newParallel()`, the function runs on the main thread each frame. See
[Parallel Solver](../optimizations/parallel#sync-vs-fire-and-forget).
:::
