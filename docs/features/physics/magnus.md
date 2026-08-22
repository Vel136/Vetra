---
sidebar_position: 4
title: Magnus & Spin
---

# Magnus & Spin

A spinning projectile doesn't fly straight. The spin drags a thin layer of air around with it, and
because the bullet is also moving forward, that circulation is faster on one side than the other,
producing a force perpendicular to both the spin axis and the velocity. This is the **Magnus
effect**: the same force that curves a baseball, dips a topspin tennis shot, and gives real rifles
their characteristic spin drift.

---

## Magnus Effect

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Magnus()
        :SpinVector(Vector3.new(0, 0, 1) * 300)  -- axis x rate: rightward twist, 300 rad/s
        :Coefficient(0.00008)
        :SpinDecayRate(0.05)                     -- spin bleeds 5% per second
    :Done()
    :Build()
```

The force is `Coefficient x (SpinVector x Velocity)`, evaluated in the same recalculation pass as
[drag](./gravity-drag#how-often-drag-is-recomputed) (every `DragSegmentInterval` seconds). The spin
vector's **direction** is the axis; its **magnitude** is the spin rate.

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:SpinVector(v)` | `SpinVector` | `Vector3.zero` | Spin axis (direction) x rate (magnitude, rad/s). |
| `:Coefficient(n)` | `MagnusCoefficient` | `0` | Force scale. `0` disables Magnus. |
| `:SpinDecayRate(n)` | `SpinDecayRate` | `0` | Fraction of spin lost per second as air slows the rotation. |

:::caution `MagnusCoefficient` is extremely sensitive
The force scales with both spin rate and speed, so it grows fast. At 600 studs/s with a spin rate of
300, even `0.0001` produces visible drift. **Start at `0.00005`** and increase incrementally. Jumping
straight to `0.001` makes the bullet swerve like a homing missile, not a projectile.
:::

### What it's good for

- **Trick shots**, curve rounds around cover.
- **Weapon character**, give a specific gun a signature drift skilled players learn to correct for.
- **Realistic spin drift**, right-hand-twist barrels drift slightly right over long range.

---

## Gyroscopic Drift

Magnus drift is the *lateral curl* from spin. Gyroscopic drift is the *slow directional yaw* the
same spin causes as the bullet precesses around its own velocity axis. Where Magnus curves the path
cleanly, gyroscopic drift adds a continuous lateral wander, imperceptible up close, accumulating
into real deviation at long range.

It's applied as a lateral acceleration each recalculation step.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :GyroDrift()
        :Rate(0.4)    -- drift rate, 1/s (accel = Rate * speed)
        -- :Axis() left unset -> defaults to world UP (right-hand rifling)
    :Done()
    :Build()
```

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:Rate(n)` | `GyroDriftRate` | `nil` (off) | Drift rate in **1/s**, acceleration *per unit speed*. Unset means no gyro drift. |
| `:Axis(v)` | `GyroDriftAxis` | `nil` -> world UP | Drift axis. `nil` uses world up, modelling right-hand rifling. |

:::caution `GyroDriftRate` is measured in 1/s
The applied acceleration is `Rate * speed`, so drift scales with how fast the round is going and
lateral displacement grows superlinearly with time of flight. A fast round and a slow round
therefore drift by different amounts over the same second, which is what makes drift read
correctly at long range.

Because the rate is per unit speed rather than an absolute acceleration, useful values are
small, on the order of `1e-3`. Start there and tune upward.
:::

Use this sparingly. It's most convincing as a barely-there force that only snipers notice at extreme
range, not something that demands overcorrection on every shot. Real right-hand-rifled bullets
drift slightly right *and* slightly up at long range; that combined signature is Magnus and
gyroscopic drift together.

---

## Combining Them

Magnus and gyroscopic drift stack, and both are evaluated in the drag recalculation pass rather than
every frame. A fully-characterised long-range round might set a spin vector for the curl, a small
Magnus coefficient for visible drift, and a tiny gyro rate for the creeping yaw.

Under the hood each force is a small vector computation: Magnus is `SpinVector x Velocity` scaled by
the coefficient, and gyroscopic drift is `Axis x Velocity` normalized and scaled by the drift rate.
Both early-out to zero when the spin, velocity, or rate is effectively zero, so a bullet that hasn't
enabled them pays nothing.
