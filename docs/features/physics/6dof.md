---
sidebar_position: 7
title: 6DOF Aerodynamics
---

# 6DOF Aerodynamics

Everything else in the physics stack treats the bullet as a **point**, a position and a velocity,
pushed around by forces. Six-degrees-of-freedom (6DOF) gives the bullet an **orientation** too, and
simulates how that attitude interacts with the airflow: lift when it flies at an angle, a restoring
moment that noses it back toward velocity, damping that kills wobble, and gyroscopic precession from
axial spin.

This is the model you reach for when a bullet's *attitude* matters, a sniper round that must nose
into its velocity, a spinning shell that precesses, a guided munition, or anywhere the bullet's
pointing direction is visible or physically significant. For ordinary pistol and rifle fire,
grenades, and arrows, the simpler [drag](./gravity-drag) and [Magnus](./magnus) stack is sufficient
and much cheaper. Reserve 6DOF for bullets where the attitude physics actually changes gameplay or
presentation.

---

## The Force Model

Each step, 6DOF resolves the bullet's **angle of attack** (alpha), the angle between where it's pointing
and where it's going, and derives forces and moments from it:

| Force / moment | Formula (as implemented) | Field(s) |
|----------------|--------------------------|----------|
| **Lift** | `CLalpha*sin(alpha) * 1/2rhov^2 * A` | `LiftCoefficientSlope`, `ReferenceArea`, `AirDensity` |
| **Pitching moment** | `Cmalpha*sin(alpha) * 1/2rhov^2 * A * L` | `PitchingMomentSlope`, `ReferenceLength` |
| **AoA-dependent drag** | drag x `(1 + AoADragFactor*sin^2alpha)` | `AoADragFactor` |
| **Pitch/yaw damping** | opposes off-axis angular velocity | `PitchDampingCoeff` |
| **Roll damping** | decays axial spin | `RollDampingCoeff` |
| **Gyroscopic precession** | from axial spin about the spin MOI | `SpinMOI`, seeded spin |

Here `rho` is `AirDensity`, `v` is speed, `A` is `ReferenceArea`, and `L` is `ReferenceLength`. The
coefficients scale linearly with `sin(alpha)`, the small-angle linearisation of a full aeroballistic
model, which is the right tradeoff for game projectiles where flight stays near-axial.

---

## Minimum Viable 6DOF

6DOF is off by default. Enabling it and getting a stable, lifting bullet requires a handful of fields
to be non-zero, the aerodynamic forces all scale through `ReferenceArea` and `BulletMass`, so if
either is zero, no force reaches the solver.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(1200)
        :BulletMass(0.011)          -- REQUIRED for 6DOF, forces convert to accel via a = F/m
    :Done()
    :SixDOF()
        :Enabled(true)
        :LiftCoefficientSlope(2.0)  -- lift is 0 by default -> set it or the bullet won't lift
        :ReferenceArea(4.5e-5)      -- scales ALL aero forces; 0 means nothing happens
        :ReferenceLength(0.031)     -- moment arm for the pitching moment
        :MomentOfInertia(2e-5)      -- resistance to pitch/yaw rotation
        :PitchDampingCoeff(0.02)    -- kills wobble; without it, torque accumulates forever
    :Done()
    :Build()
```

:::danger `BulletMass` is mandatory for 6DOF
Standard casting integrates velocity directly with drag coefficients already tuned to the right
velocity change, mass is never needed. 6DOF instead produces raw **force** vectors that must become
acceleration via `a = F / m`, so zero mass is a division by zero. `:Build()` returns `nil` if
`BulletMass` is `0` while 6DOF is enabled.
:::

---

## Every 6DOF Field

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:Enabled(b)` | `SixDOFEnabled` | `false` | Master switch. |
| `:LiftCoefficientSlope(n)` | `LiftCoefficientSlope` | `0` | dCL/dalpha. **`0` disables lift entirely.** |
| `:PitchingMomentSlope(n)` | `PitchingMomentSlope` | `0` | dCm/dalpha. Negative values give a stabilising restoring moment. |
| `:PitchDampingCoeff(n)` | `PitchDampingCoeff` | `0` | Cmq. Damps pitch/yaw wobble. `0` means undamped. |
| `:RollDampingCoeff(n)` | `RollDampingCoeff` | `0` | Clp. Decays axial spin over time. |
| `:AoADragFactor(n)` | `AoADragFactor` | `0` | Extra drag at angle of attack: `x(1 + factor*sin^2alpha)`. |
| `:ReferenceArea(n)` | `ReferenceArea` | `0` | Cross-sectional area. **Scales all aero forces, `0` = no forces.** |
| `:ReferenceLength(n)` | `ReferenceLength` | `0` | Moment arm for the pitching moment. |
| `:AirDensity(n)` | `AirDensity` | `1.225` | kg/m^3. Sea level = 1.225. Lower = thinner air, weaker forces. |
| `:MomentOfInertia(n)` | `MomentOfInertia` | `0` | Transverse (pitch/yaw) rotational inertia. |
| `:SpinMOI(n)` | `SpinMOI` | `0` | Axial (roll) moment of inertia. Set `>0` for gyroscopic precession. |
| `:MaxAngularSpeed(n)` | `MaxAngularSpeed` | `200pi` | Angular velocity clamp, rad/s, a stability safety cap. |
| `:InitialOrientation(cf)` | `InitialOrientation` | `nil` | Starting attitude. `nil` = aligned with the fire direction. |
| `:InitialAngularVelocity(v)` | `InitialAngularVelocity` | `nil` | Seed angular velocity (axial spin, initial tumble). |
| `:CLAlphaMachTable(t)` | `CLAlphaMachTable` | `nil` | Mach-indexed lift-slope lookup: `{ {mach, value}, ... }`. |
| `:CmAlphaMachTable(t)` | `CmAlphaMachTable` | `nil` | Mach-indexed pitching-moment-slope lookup. |
| `:CmqMachTable(t)` | `CmqMachTable` | `nil` | Mach-indexed pitch-damping lookup. |
| `:ClpMachTable(t)` | `ClpMachTable` | `nil` | Mach-indexed roll-damping lookup. |

---

## Air Density

`AirDensity` is in kg/m^3 and defaults to sea-level standard, `1.225`. Lower it to weaken every
aerodynamic force proportionally, useful for high-altitude engagements or thin-atmosphere maps.

| Altitude | Density |
|----------|--------:|
| Sea level | 1.225 |
| 2 km | 1.007 |
| 4 km | 0.819 |
| 8 km | 0.526 |

---

## Mach-Variable Coefficients

By default the aero coefficients are constant slopes scaled by `sin(alpha)`. When you need coefficients
that vary with speed, the way real drag and stability change through transonic flight, supply a
Mach-indexed lookup table for any of the four coefficients. Each is a list of `{ mach, value }`
pairs, interpolated at the bullet's current Mach number:

```lua
:SixDOF()
    :Enabled(true)
    :CLAlphaMachTable({ {0.0, 2.0}, {0.9, 2.4}, {1.2, 3.1}, {2.0, 2.7} })
    :CmAlphaMachTable({ {0.0, -0.4}, {1.0, -0.6}, {2.0, -0.5} })
    -- ...plus the required ReferenceArea, MomentOfInertia, etc.
:Done()
```

When a table is set, it overrides the corresponding constant slope. Leave them `nil` for the
simpler linear model.

---

## Troubleshooting

**The bullet doesn't curve or react to angle of attack.** Check, in order:
`SixDOFEnabled = true`; `LiftCoefficientSlope > 0` (it's `0` by default, which disables lift);
`ReferenceArea > 0` (it scales all forces to zero when zero); and `BulletMass > 0`.

**The bullet immediately tumbles or spins out.** `MomentOfInertia` is probably too small, or
`PitchDampingCoeff` is `0`. Without damping every aerodynamic torque permanently accumulates angular
velocity, compounding each step. Add `PitchDampingCoeff` first (`0.02` is a safe start), then adjust
`MomentOfInertia` until the wobble response feels right. A stiffer restoring torque via a negative
`PitchingMomentSlope` also stabilises the round.

**Can I use 6DOF without Magnus spin?** Yes. `InitialAngularVelocity` can seed axial spin directly.
With neither set, the bullet starts at zero angular velocity and only develops spin from aerodynamic
torques, physically correct for an unspun round. Set `SpinMOI > 0` only when you want gyroscopic
precession.

**Does it work in `newParallel()`?** Yes. All 6DOF computation is pure math with no Instance access
or cross-Actor callbacks; `InitialOrientation` and `InitialAngularVelocity` serialize by value.
There's no parallel-specific penalty beyond the extra per-step math.

---

## How It Compares

No other publicly available Roblox projectile library implements six-degrees-of-freedom
aerodynamics, the common alternatives model a point mass with no orientation, no aerodynamic torque,
and no angular dynamics. The reference model for real 6DOF projectile simulation comes from
small-arms research (McCoy's *Modern Exterior Ballistics*, the BRL 6DOF model); Vetra covers the
same fundamental forces, with the linearisation described above as the main simplification. When you
need speed-dependent coefficients, the four Mach tables let you supply your own curves. For genuine
exterior-ballistics research, a dedicated tool is still the right choice, but for a Roblox game, this
is a level of fidelity nothing else offers.
