---
sidebar_position: 6
title: Wind & Coriolis
---

# Wind & Coriolis

Two environmental forces that act on every bullet in a solver rather than being baked into a single
behavior. Wind is a push in a direction; Coriolis is the deflection from a rotating world. Both are
set on the **solver**, and individual bullets can opt in or out of wind through a single behavior
field.

---

## Wind

Wind is a solver-wide vector. Set it once (and update it whenever your weather changes), and it's
added into every bullet's acceleration.

```lua
Solver:SetWind(Vector3.new(10, 0, 0))  -- 10 studs/s eastward
```

Per-bullet sensitivity comes from `WindResponse` on the behavior. The solver applies
`wind x WindResponse` to each bullet, so a value of `0.5` feels half the wind and `0` ignores it
entirely, useful for heavy rounds that shouldn't drift, or for disabling wind on cosmetic-only
projectiles.

```lua
-- Light, wind-sensitive round
Solver:Fire(context, { WindResponse = 1.0 })   -- full wind (this is the default)

-- Heavy round, half as affected
Solver:Fire(context, { WindResponse = 0.5 })

-- Ignores wind completely
Solver:Fire(context, { WindResponse = 0.0 })
```

| Method / Field | Where | Default | Description |
|----------------|-------|--------:|-------------|
| `Solver:SetWind(v)` | solver | `Vector3.zero` | The wind vector applied to all bullets. |
| `WindResponse` | behavior | `1.0` | Per-bullet multiplier on the wind. `0` opts out. |

Wind is only computed when a non-zero wind vector is set, so leaving it at the default costs nothing.

---

## Coriolis

The Coriolis effect is the apparent deflection a projectile picks up over a rotating body. On a
spinning world, a bullet fired north in the northern hemisphere drifts east; fired south, it drifts
west; at the equator the drift is purely horizontal. In reality it's a tiny force, irrelevant at
combat range, detectable only by specialist snipers at extreme distance, but in a game you can
exaggerate it into a tactile, map-defining mechanic.

Coriolis is a **solver-level environment setting**, not a per-bullet behavior. Set it once per
map or zone; every bullet fired through that solver is affected equally.

```lua
-- Arctic map: high latitude, strongly exaggerated
Solver:SetCoriolisConfig(75, 1200)

-- Equatorial map: latitude 0, east/west drift only
Solver:SetCoriolisConfig(0, 800)

-- Disabled (this is the default state)
Solver:SetCoriolisConfig(45, 0)
```

### How it's computed

`SetCoriolisConfig(latitude, scale)` builds the rotation vector

```
Omega = EARTH_ANGULAR_RATE * scale * (0, sin phi, cos phi)      where phi = latitude in radians
```

and each frame applies the standard Coriolis acceleration

```
a = -2 * (Omega x velocity)
```

Two things fall out of this:

- **`latitude` sets the *direction* of deflection** through `sin phi` / `cos phi`, the split between
  the vertical (hemisphere) and horizontal (equatorial) components.
- **`scale` sets the *strength*.** It's a flat multiplier on Earth's real angular rate. `scale = 0`
  zeroes `Omega` entirely and disables the effect with no per-frame cost.

| Method | Signature | Description |
|--------|-----------|-------------|
| `Solver:SetCoriolisConfig(latitude, scale)` | `(number, number)` | Latitude in degrees, scale as a multiplier on Earth's rotation rate. `scale = 0` disables. |

### Choosing a scale

Because `scale` multiplies Earth's real (very small) angular rate, useful game values are large. The
following are illustrative starting points, tune them against your map's scale and engagement
ranges rather than treating them as fixed:

| `scale` | Rough feel |
|--------:|------------|
| `0` | Disabled, zero cost (default). |
| `~500` | Subtle; only noticeable at long range. |
| `~1000` | Clearly perceptible at a few hundred studs. |
| `~3000` | Strong; a force players actively compensate for. |

:::caution Behavior-table Coriolis fields do nothing
Coriolis is solver-level only. Any `CoriolisLatitude` / `CoriolisScale` fields you see on a behavior
table exist for documentation and have **no runtime effect**, always configure Coriolis through
`Solver:SetCoriolisConfig`.
:::
