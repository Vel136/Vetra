---
sidebar_position: 1
title: Homing
---

# Homing

Homing steers a bullet toward a target position each frame, a guided missile, a seeking arrow, a
lock-on projectile. You supply a function that returns *where the target is right now*, and the
solver turns the bullet toward it within a configurable steering budget.

---

## The Setup

The one required piece is a **position provider**: a function returning the target's current world
position. It's called each step, so returning a live position (rather than a fixed point) makes the
bullet track a moving target.

```lua
local target = workspace.TargetPart

local Behavior = Vetra.BehaviorBuilder.new()
    :Homing()
        :PositionProvider(function(position, velocity)
            return target.Position   -- return nil to disengage mid-flight
        end)
        :Strength(90)             -- max turn rate, degrees/second
        :MaxDuration(5)           -- auto-disengage after 5 seconds
        :AcquisitionRadius(0)     -- 0 = engage immediately
    :Done()
    :Build()
```

---

## Fields

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:PositionProvider(fn)` | `HomingPositionProvider` | `nil` | Returns the target position each step. Return `nil` to disengage. |
| `:Strength(n)` | `HomingStrength` | `90` | Maximum steering rate in **degrees per second**. Higher = tighter turns. |
| `:MaxDuration(n)` | `HomingMaxDuration` | `3` | Seconds before homing auto-disengages and the bullet flies straight. |
| `:AcquisitionRadius(n)` | `HomingAcquisitionRadius` | `0` | Delay engagement until within this many studs of the target. `0` engages at once. |
| `:Filter(fn)` | `CanHomeFunction` | `nil` | Per-step predicate, return `false` to suspend steering this frame. |

---

## The Provider Signature

**`HomingPositionProvider`**, `(position: Vector3, velocity: Vector3) -> Vector3?`

| Parameter | Type | Description |
|-----------|------|-------------|
| `position` | `Vector3` | The bullet's current position. |
| `velocity` | `Vector3` | The bullet's current velocity. |
| **returns** | `Vector3?` | The target position to steer toward, or `nil` to disengage homing entirely. |

Returning `nil` is how you drop a lock: if the target dies, leaves range, or breaks line of sight,
return `nil` and the bullet continues on its current heading.

---

## Gating with a Filter

`CanHomeFunction` runs each step *before* steering. Return `false` to skip steering this frame
without permanently disengaging, useful for flare/countermeasure mechanics or line-of-sight checks.

**`CanHomeFunction`**, `(context, currentPosition: Vector3, currentVelocity: Vector3) -> boolean`

```lua
:Filter(function(context, position, velocity)
    return not context.UserData.Jammed   -- stop tracking while jammed
end)
```

---

## When Homing Ends

Homing disengages when any of these happen: the provider returns `nil`, `MaxDuration` elapses, or
you terminate the bullet. `OnHomingDisengaged` fires when it does.

```lua
Signals.OnHomingDisengaged:Connect(function(context)
    -- lost lock or timed out, swap to dumb-fire visuals, etc.
    context.UserData.Tracking = false
end)
```

**`OnHomingDisengaged` parameters:** `(context: BulletContext)`, just the bullet. The disengagement
is signalled; the reason isn't passed, so track it yourself via `UserData` if you need to distinguish
a timeout from a dropped lock.

---

## Steering Feel

`Strength` is the whole feel of the weapon. Low values (30,60 deg/s) give a lazy, dodgeable seeker that
struggles against agile targets. High values (180 deg/s+) produce an aggressive missile that whips onto
target almost instantly. `MaxDuration` bounds how long it can chase before going ballistic, which
keeps a missed shot from circling forever.

:::note Homing requires main-thread sync in parallel
On `Vetra.newParallel()`, a bullet with a `HomingPositionProvider` is stepped as a **sync** cast
(the provider runs on the main thread each frame). This is automatic, see
[Parallel Solver](../optimizations/parallel#sync-vs-fire-and-forget), it just means seekers don't
get the near-zero-overhead fire-and-forget path that dumb projectiles do.
:::
