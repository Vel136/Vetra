---
sidebar_position: 2
title: Gravity & Drag
---

# Gravity & Drag

The two forces every projectile lives with: gravity pulls it down, drag slows it as it pushes
through the air. Together they turn a laser-straight ray into an arc that drops and decelerates,
the baseline of a bullet that feels physical.

---

## Gravity

Gravity is applied through the acceleration term of the kinematic formula. **By default a bullet
falls under `workspace.Gravity`**, you get real bullet drop out of the box with no configuration.

The `Gravity` field is an *override*: set it and that vector is used verbatim, leave it unset and
the bullet falls under `workspace.Gravity`. Any `Vector3` is accepted, including `Vector3.zero`
and upward or sideways vectors.

```lua
-- Default: no Gravity set -> bullet drops under workspace.Gravity automatically
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(800)
    :Done()
    :Build()
```

For a floaty, underwater, or low-gravity map, override with a gentler vector:

```lua
:Physics()
    :Gravity(Vector3.new(0, -5, 0))   -- gentle 5 studs/s^2 drop
:Done()
```

For a flat, drop-free trajectory, pass `Vector3.zero`:

```lua
:Physics()
    :Gravity(Vector3.zero)            -- no drop at all
:Done()
```

The vector need not point down. An upward or sideways gravity is applied as given, which is useful
for floating embers, magnetic pulls, or inverted-gravity areas.

`:Acceleration()` sets a *constant* extra acceleration on top of gravity (a thruster, a steady
sideways push). Resolved gravity and acceleration are summed into the arc's acceleration term.

---

## Drag

Drag is air resistance. The faster the bullet goes, the harder the air pushes back, so a bullet
bleeds speed fastest right out of the barrel and decelerates more gently as it slows. **Drag is off
by default** (`DragCoefficient = 0`); set a coefficient above zero to enable it.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(800)
        :MinSpeed(30)          -- terminate once the bullet drops below 30 studs/s
    :Done()
    :Drag()
        :Coefficient(0.003)
        :Model(Vetra.BehaviorBuilder.DragModel.G7)   -- modern boat-tail rifle standard
        :SegmentInterval(0.05)                       -- recompute drag every 50ms
    :Done()
    :Build()
```

### Why drag matters for gameplay

- **Damage falloff for free.** Tie damage to `velocity.Magnitude` and long-range hits naturally do
  less, no separate distance-falloff system needed.
- **Lead and arc.** A subsonic round at 800 studs has had seconds to slow and drop. Players must
  lead moving targets, which is skill hitscan can't replicate.
- **Feel.** A rifle that's snappy up close but demands careful aim at range, purely from physics,
  reads as a rifle, not a gun-shaped hitscan wand.

---

## Drag Fields

| Setter | Field | Default | Meaning |
|--------|-------|--------:|---------|
| `:Coefficient(n)` | `DragCoefficient` | `0` | Master drag scale (**not** a ballistic coefficient, see below). `0` disables drag. |
| `:Model(enum)` | `DragModel` | `Quadratic` | Which drag curve to use (see table below). |
| `:SegmentInterval(n)` | `DragSegmentInterval` | `0.05` | Seconds between drag/Magnus/gyro recalculations. |
| `:CustomMachTable(t)` | `CustomMachTable` | `nil` | Required when `DragModel = Custom`: `{ {mach, cd}, ... }`. |

`:MinSpeed(n)` (on `:Physics()`, default `1`) is the speed floor: once drag pulls the bullet below
it, the cast terminates with the `Speed` reason.

---

## Drag Models

Always pass a value from `Vetra.BehaviorBuilder.DragModel` (a direct re-export of `Vetra.Enums.DragModel`)
rather than a raw string or number, a typo becomes a nil-index warning at the call site instead of
a silent wrong value or a `:Build()`-time error.

| Enum | Description |
|------|-------------|
| `DragModel.Quadratic` | Deceleration proportional to speed^2. **Default**; accurate for most subsonic play. |
| `DragModel.Linear` | Deceleration proportional to speed. |
| `DragModel.G1` | Flat-base spitzer; general-purpose standard. |
| `DragModel.G2` / `G3` / `G4` | Aberdeen / atypical projectile shapes. |
| `DragModel.G5` | Boat-tail spitzer; mid-range rifles. |
| `DragModel.G6` | Semi-spitzer flat-base; shotgun slugs. |
| `DragModel.G7` | Long boat-tail; modern long-range / sniper standard. |
| `DragModel.G8` | Flat-base semi-spitzer; hollow points / pistols. |
| `DragModel.GL` | Lead round ball; cannons / muskets / buckshot. |
| `DragModel.Custom` | Requires `CustomMachTable = { {mach, cd}, ... }`. |

For most games, **Quadratic** (the default) is all you need. Reach for a G-series model when you
want a weapon's deceleration curve to match a real projectile class, `G7` for a modern rifle, `GL`
for a musket's heavy arc.

---

## What `Coefficient` Actually Is

This trips people up, so it's worth being precise. **`Coefficient` is not a ballistic coefficient
(BC).** It's a lumped drag-scale that plugs directly into the deceleration formula. Each frame the
solver computes the drag deceleration as:

| Model | Deceleration magnitude |
|-------|------------------------|
| `Quadratic` | `Coefficient * speed^2` |
| `G1`...`GL`, `Custom` | `Coefficient * Cd(mach) * speed^2` |
| `Linear` | `Coefficient * speed` |

where `speed` is the current speed in studs/s, `Cd(mach)` is the model's drag curve looked up at the
bullet's Mach number (`speed / speed_of_sound`), and `c` is the speed of sound. The result is applied
as an acceleration opposing the velocity direction.

Two consequences fall out of this:

- **For the default Quadratic model, `Coefficient` carries units of `1/studs`.** Decel
  (`studs/s^2`) = `Coefficient * speed^2` (`studs^2/s^2`), so the coefficient must be `1/studs`. That's
  why realistic values are small, around `1e-3`, not order-1.
- **It is not normalized by mass or air density.** Nothing upstream divides by `BulletMass` or
  scales by `AirDensity` for the standard drag path (those matter for [6DOF](./6dof), which is a
  different force model). So passing a raw BC like `0.462`, or `1/BC`, produces roughly `1e5 studs/s^2`
  of deceleration and stalls the bullet in milliseconds.

### Calibrating against a real bullet

If you want physically-faithful ballistics, don't guess, calibrate. Vetra's own accuracy test
matches a 168gr Sierra MatchKing (G1, BC 0.462, 823 m/s muzzle) against a reference ballistic solver
and lands on:

```lua
:Drag()
    :Model(Vetra.Enums.DragModel.G1)
    :Coefficient(0.00266)   -- lumped drag scale for BC ~= 0.462 G1 at sea level
    :SegmentInterval(0.001)
:Done()
```

That value holds velocity to within ~1% out to ~600 yards and keeps drop under ~1.6% the whole way.
The takeaway: pick your drag model, then tune `Coefficient` by firing and comparing total velocity
loss to your reference, it's a scaling knob, not a physical constant you can copy from a data sheet.

:::tip For pure gameplay, don't overthink it
If you're not chasing real-world ballistics, `Coefficient` is just a "how fast does it slow down"
dial. Start around `0.002`,`0.003` with `Quadratic`, fire a few shots, and turn it up or down until
the falloff feels right.
:::

---

## How Often Drag Is Recomputed

Drag isn't re-evaluated every frame, that would be wasteful. Instead the solver recomputes
deceleration every `DragSegmentInterval` seconds (default `0.05`) and opens a new trajectory segment
with the updated acceleration. Between those points the bullet flies the exact analytic arc.

A shorter interval tracks fast-changing forces more tightly at higher cost; a longer interval is
cheaper but coarser. On dense maps under heavy bullet load, raising `DragSegmentInterval` is one of
the cheapest ways to reclaim CPU. `0.05` is a solid default.

:::note One interval, three forces
`DragSegmentInterval` governs the recalculation cadence for drag, [Magnus](./magnus), and
[gyroscopic drift](./magnus#gyroscopic-drift) together, they're evaluated in the same pass.
:::
