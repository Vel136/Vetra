---
sidebar_position: 1
title: Overview
---

# Physics Overview

There's a version of a shooter that technically works, bullets fire, hit things, deal damage, and
still feels weightless. The projectiles travel in laser-straight lines, ignore wind, never slow
down, and arrive at 800 studs exactly as crisply as they left the barrel. It functions. It doesn't
feel like a gun.

The gap between "works" and "feels real" is physics. Vetra's physics stack is a set of forces you
layer on incrementally, each one changes how the bullet moves through the air, and each one is
independent, opt-in, and cheap enough to ignore when you don't need it.

---

## How Forces Are Applied

Each force below adjusts a bullet's acceleration or velocity. When a force changes those, a bounce,
a drag recalculation, a homing correction, the bullet continues along a new arc from its current
state rather than the old one. Forces compose: a round can carry drag, spin drift, and tumble at
once, each contributing to the acceleration the bullet flies under.

---

## Bullet Lifetime

Before any force matters, a cast needs limits, how far it flies and how slow it's allowed to get
before it terminates. These live on `:Physics()`:

| Setter | Field | Default | Terminate reason | Meaning |
|--------|-------|--------:|------------------|---------|
| `:MaxDistance(n)` | `MaxDistance` | `500` | `Distance` | Total **path length** travelled, in studs. Follows the bullet along every arc and bounce. |
| `:MaxDisplacement(n)` | `MaxDisplacement` | `0` (off) | `Displacement` | **Straight-line** distance from the muzzle, in studs. `0` disables it. |
| `:MinSpeed(n)` | `MinSpeed` | `1` | `Speed` | Speed floor. Drops below it (e.g. from drag) -> terminate. |
| `:MaxSpeed(n)` | `MaxSpeed` | `inf` | `Speed` | Speed ceiling. |

:::note `MaxDistance` vs `MaxDisplacement`
`MaxDistance` is **path length**, a bouncing or arcing bullet accumulates it along the whole route.
`MaxDisplacement` is the **as-the-crow-flies** distance from where it was fired. A grenade that
ricochets around a room can rack up a large path length while never getting far from the muzzle;
`MaxDisplacement` caps the latter. They're independent, set either, both, or neither.
:::

---

## The Force Menu

Each of these has its own page. They compose freely, a single round can have drag, spin drift, a
supersonic profile, and tumble-on-pierce all at once.

| Feature | What it does | Page |
|---------|--------------|------|
| **Gravity & Drag** | Bullet drop and air resistance, with G-series ballistic models. | [Gravity & Drag](./gravity-drag) |
| **Speed Profiles** | Different physics above and below the sound barrier. | [Speed Profiles](./speed-profiles) |
| **Magnus Effect** | Spinning bullets curve, the curveball force. | [Magnus & Spin](./magnus) |
| **Gyroscopic Drift** | Slow directional wander from spin-axis precession. | [Magnus & Spin](./magnus#gyroscopic-drift) |
| **Tumble** | Loss of stability, drag spikes, path goes chaotic. | [Tumble](./tumble) |
| **Wind & Coriolis** | Environmental deflection, per-map. | [Wind & Coriolis](./wind-coriolis) |
| **6DOF Aerodynamics** | Full attitude physics: lift, pitching moment, damping, precession. | [6DOF](./6dof) |

Not a force, but related: to replace physics entirely with a scripted path, see
[Custom Trajectories](../additions/trajectory) under **Additions**.

---

## How Forces Are Integrated

Most forces aren't recomputed every single frame, that would be wasteful. Instead, drag, Magnus,
and gyroscopic drift are re-evaluated every `DragSegmentInterval` seconds (default `0.05`), at which
point the solver recomputes the deceleration and opens a new trajectory segment. Between those
recalculation points, the bullet flies the exact analytic arc for its current acceleration.

This is a tunable tradeoff: a shorter interval tracks rapidly-changing forces more tightly at higher
cost; a longer interval is cheaper but coarser. `0.05` is a good default for game projectiles.

```lua
:Drag()
    :Coefficient(0.003)
    :SegmentInterval(0.05)   -- recompute drag/Magnus/gyro every 50ms
:Done()
```

---

## A Word on Restraint

None of these features are mandatory. A plain bounce-and-pierce bullet with no physics works
perfectly well for a lot of games. The physics exist for when you want a weapon to feel like *that
specific weapon*, a sniper that starts supersonic, goes subsonic at range, drifts slightly right
from spin, and has to be led against moving targets. That's a *character* players learn.

Start with the minimum that feels right. Add one force at a time until it matches what you imagined.
The right level of simulation is a creative decision, not a technical one.

---

## Enabling Physics via the Builder

Every physics feature has a dedicated sub-builder off `BehaviorBuilder`. They chain, and each closes
with `:Done()`:

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()   :MaxDistance(900):MinSpeed(30)   :Done()
    :Drag()      :Coefficient(0.003):Model(Vetra.BehaviorBuilder.DragModel.G7):Done()  -- Coefficient is a tuned drag scale, not a BC, see the Gravity & Drag page
    :Magnus()    :SpinVector(Vector3.new(0,0,1)*300):Coefficient(0.00008)     :Done()
    :Tumble()    :OnPierce(true):DragMultiplier(4)                            :Done()
    :Build()
```

You can also pass every field on a raw table to `Solver:Fire()`, both routes produce the same
`VetraBehavior`. The builder just adds typed setters and build-time validation.
