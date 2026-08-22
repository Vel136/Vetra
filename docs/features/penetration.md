---
sidebar_position: 2
title: Penetration
---

# Penetration

Penetration, piercing, is a bullet passing *through* a surface and continuing out the other side,
losing some speed on the way. Where a bounce reflects, a pierce transmits. Vetra resolves the entry
and exit, applies speed loss, tracks what's already been pierced, and can bend the exit direction or
even shatter the round into fragments on the way through.

---

## The Minimum Pierce

Like bounce, penetration is opt-in and gated by a `Filter`. Return `true` to punch through a
surface, `false` to treat it as solid.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Pierce()
        :Max(2)                  -- pierce at most 2 surfaces
        :SpeedRetention(0.8)     -- keep 80% of speed per pierce
        :Filter(function(context, result, velocity)
            return true          -- pierce everything
        end)
    :Done()
    :Build()
```

Use it to pierce only thin materials, only tagged cover, or only while the bullet is fast enough to
matter.

```lua
:Filter(function(context, result, velocity)
    return result.Instance:HasTag("Penetrable") and velocity.Magnitude > 100
end)
```

**`Filter`, `CanPierceFunction` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `context` | `BulletContext` | The live bullet firing this hit. Read `UserData`, position, etc. |
| `result` | `RaycastResult` | The entry-face hit. `result.Instance`, `.Position`, `.Normal`, `.Material`, `.Distance`. |
| `velocity` | `Vector3` | The bullet's velocity at the moment of contact. |
| **returns** | `boolean` | `true` to pierce through, `false` to treat the surface as solid. |

---

## Every Pierce Field

| Setter | Field | Default | Meaning |
|--------|-------|--------:|---------|
| `:Max(n)` | `MaxPierceCount` | `3` | Lifetime pierce budget. |
| `:Filter(fn)` | `CanPierceFunction` | `nil` | Per-hit predicate. Without it, nothing pierces. |
| `:SpeedThreshold(n)` | `PierceSpeedThreshold` | `50` | Below this speed the bullet can't pierce, the hit is terminal. |
| `:SpeedRetention(n)` | `PierceSpeedRetention` | `0.8` | Fraction of speed kept per pierce (`1` = no loss). |
| `:NormalBias(n)` | `PierceNormalBias` | `1.0` | How much the exit direction bends toward the surface normal. |
| `:PierceDepth(n)` | `PierceDepth` | `0` | Extra forward offset applied when re-emerging, to clear the back face. |
| `:PierceForce(n)` | `PierceForce` | `0` | Additional velocity cost scaled by surface thickness. |
| `:ThicknessLimit(n)` | `PierceThicknessLimit` | `500` | Surfaces thicker than this (studs) stop the bullet instead of letting it through. |

---

## Speed Loss and the Speed Floor

Two fields govern how a bullet decays as it drills through cover:

- **`SpeedRetention`** is the flat fraction of speed kept per pierce. At `0.8`, a bullet exits each
  wall at 80% of its entry speed. Three walls in a row and it's down to ~51%.
- **`SpeedThreshold`** is the floor. Once the bullet is slower than this, it can no longer pierce,
  the next penetrable surface stops it and `OnHit` fires.

For thickness-aware loss, `PierceForce` adds a speed cost proportional to how far the bullet
travelled *inside* the material, so a thick wall bleeds more speed than a thin panel. Pair it with
`ThicknessLimit` to make genuinely thick geometry impenetrable:

```lua
:Pierce()
    :Max(4)
    :SpeedRetention(0.85)
    :PierceForce(40)          -- thicker walls cost more speed
    :ThicknessLimit(6)        -- anything over 6 studs thick is solid
    :Filter(function() return true end)
:Done()
```

---

## Bending the Exit

Real rounds deflect slightly as they pass through material. `PierceNormalBias` bends the exit
direction toward the surface normal, `0` exits perfectly straight, higher values kick the round
off-axis on the way out. `PierceDepth` nudges the re-emergence point forward so the bullet clears
the back face cleanly instead of re-detecting the same wall.

---

## Pierce and Bounce Together

A surface contact is resolved as **exactly one** of pierce or bounce. **Pierce is always evaluated
first.** If the pierce filter returns `true`, the bullet passes through and the
[bounce](./bounce) filter is never consulted for that hit. They are mutually exclusive per contact.

This ordering lets you build a round that pierces soft cover but ricochets off hard cover, the
pierce filter greenlights wood and drywall, and anything it rejects falls through to the bounce
filter for metal and stone.

```lua
:Pierce()
    :Max(3)
    :Filter(function(ctx, result) return result.Instance:HasTag("SoftCover") end)
:Done()
:Bounce()
    :Max(2)
    :Restitution(0.6)
    :Filter(function(ctx, result) return result.Instance:HasTag("HardCover") end)
:Done()
```

### Re-piercing after a bounce

By default, once an instance is in the bullet's "already pierced" list, later arcs pass through it
silently. `ResetPierceOnBounce` (on the [bounce](./bounce) builder) clears that list after every
bounce, so a ricocheting bullet can pierce the same wall again on a later arc:

```lua
:Bounce()
    :ResetPierceOnBounce(true)
    :Filter(function() return true end)
:Done()
```

---

## Pierce Triggers Two More Features

A pierce is the trigger for two behavioral features that live under **Additions**:

- **[Fragmentation](./additions/fragmentation)**, shatter into a cone of child bullets at the
  pierce point. Enable with `:Fragmentation():OnPierce(true)`.
- **[Tumble on pierce](./physics/tumble)**, a round that punches through a soft target exits
  *destabilised*: yawing, slowing fast, doing less damage at range. Enable with
  `:Tumble():OnPierce(true)`.

Both fire on the same pierce event, so a single anti-personnel round can pierce, tumble, and
fragment all at once.

---

## Reacting to Pierces

```lua
Signals.OnPierce:Connect(function(context, result, velocity, pierceCount)
    print(("Pierced %s, %d total, now %.0f studs/s")
        :format(result.Instance.Name, pierceCount, velocity.Magnitude))
end)
```

**`OnPierce` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `context` | `BulletContext` | The bullet that pierced. |
| `result` | `RaycastResult` | The surface that was pierced. |
| `velocity` | `Vector3` | Exit velocity, after speed retention is applied. |
| `pierceCount` | `number` | Running total of pierces for this bullet. |

### Overriding a pierce mid-resolution

`OnPrePierce` fires before the pierce resolves; `OnMidPierce` fires during. Both receive a `mutate`
callback applied synchronously.

```lua
-- Before: override the entry normal or the incoming velocity
Signals.OnPrePierce:Connect(function(context, result, velocity, mutate)
    mutate(nil, velocity * 1.1)   -- (normal?, velocity?)
end)

-- During: override the exit velocity directly
Signals.OnMidPierce:Connect(function(context, result, velocity, mutate)
    mutate(velocity)   -- (velocity?), keep full speed through this surface
end)
```

**`OnPrePierce` `mutate` parameters:** `(normal: Vector3?, velocity: Vector3?)`, pass `nil` to leave
a value untouched.

**`OnMidPierce` `mutate` parameters:** `(velocity: Vector3?)`, the resolved exit velocity.

:::caution Don't yield in hook handlers
`mutate` is only live during the synchronous handler. Calling it after the handler returns (or
yielding with `task.wait` inside the handler) logs a warning and has no effect.
:::
