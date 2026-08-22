---
sidebar_position: 1
title: Bounce
---

# Bounce

A bounce is a bullet reflecting off a surface it did not pass through. Vetra handles the full
ricochet: it reflects the velocity about the surface normal, applies energy loss, optionally
scatters the reflection, and continues the bullet along a new arc from the impact point. Each bounce
starts a fresh trajectory segment, so a bullet can ricochet repeatedly and keep an accurate position
throughout its flight.

---

## The Minimum Bounce

Bounce is opt-in. A behavior with no bounce configuration treats every hit as terminal. To make a
bullet ricochet, give it a `Filter`, the function that decides, per surface, whether this hit
should bounce.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Bounce()
        :Max(3)              -- lifetime bounce budget
        :Restitution(0.7)    -- keep 70% of speed each bounce
        :Filter(function(context, result, velocity)
            return true      -- ricochet off everything
        end)
    :Done()
    :Build()
```

Return `true` to bounce, `false` to terminate on this surface. Use it to bounce only off metal, only
above a speed, only on tagged parts, whatever your game needs.

```lua
:Filter(function(context, result, velocity)
    return result.Instance:HasTag("Ricochet") and velocity.Magnitude > 120
end)
```

**`Filter`, `CanBounceFunction` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `context` | `BulletContext` | The live bullet hitting this surface. |
| `result` | `RaycastResult` | The impact. `result.Instance`, `.Position`, `.Normal`, `.Material`, `.Distance`. |
| `velocity` | `Vector3` | The bullet's velocity at the moment of impact. |
| **returns** | `boolean` | `true` to ricochet, `false` to terminate on this surface. |

---

## Every Bounce Field

| Setter | Field | Default | Meaning |
|--------|-------|--------:|---------|
| `:Max(n)` | `MaxBounces` | `5` | Lifetime bounce budget. When exhausted, the next hit is terminal. |
| `:Filter(fn)` | `CanBounceFunction` | `nil` | Per-hit predicate. Without it, nothing bounces. |
| `:SpeedThreshold(n)` | `BounceSpeedThreshold` | `20` | Below this speed, hits are terminal, the filter is never called. |
| `:Restitution(n)` | `Restitution` | `0.7` | Fraction of speed retained per bounce (`1` = perfectly elastic). |
| `:MaterialRestitution(t)` | `MaterialRestitution` | `{}` | Per-`Enum.Material` restitution overrides. |
| `:NormalPerturbation(n)` | `NormalPerturbation` | `0.0` | Random scatter added to the reflected direction (radians-ish). Makes ricochets feel dirty. |
| `:ResetPierceOnBounce(b)` | `ResetPierceOnBounce` | `false` | Clear the pierced-instance list after each bounce so the next arc can re-pierce them. |

---

## Restitution: How Bouncy Is Bouncy

`Restitution` is the fraction of speed a bullet keeps when it bounces. `0.7` means each ricochet
leaves the surface at 70% of the speed it arrived with, the bullet loses energy and its arcs get
shorter until it drops below `BounceSpeedThreshold` and dies.

Different surfaces should bounce differently. `MaterialRestitution` overrides the global value per
material:

```lua
:Bounce()
    :Max(6)
    :Restitution(0.6)                       -- default for anything unlisted
    :MaterialRestitution({
        [Enum.Material.Metal]   = 0.85,     -- rings off hard and lively
        [Enum.Material.Grass]   = 0.25,     -- deadens on contact
        [Enum.Material.Fabric]  = 0.1,      -- practically absorbs it
    })
    :Filter(function() return true end)
:Done()
```

---

## The Speed Floor

`BounceSpeedThreshold` is the speed below which a bullet can no longer bounce. Once its speed drops
under the threshold, whether from restitution loss, drag, or a steep impact, the next hit is
treated as terminal and `OnHit` fires instead of `OnBounce`.

This is what makes a grenade eventually *settle* instead of jittering forever, and it's the first
thing to check when a `CanBounceFunction` "isn't being called": if the bullet is already below
threshold, the filter is skipped entirely.

:::tip Diagnosing "my bullet won't bounce"
Two silent gates sit in front of your filter: `BounceSpeedThreshold` (too-slow bullets are terminal)
and `MaxBounces` (an exhausted budget skips the filter). Check both before suspecting the filter
itself.
:::

---

## Scattering the Reflection

A perfectly mirror-like bounce looks artificial. `NormalPerturbation` adds randomized jitter to the
reflected direction so ricochets fan out instead of tracing a clean geometric reflection.

```lua
:Bounce()
    :Restitution(0.65)
    :NormalPerturbation(0.08)   -- subtle scatter; larger = wilder ricochets
    :Filter(function() return true end)
:Done()
```

Keep it small. At `0.05`,`0.1` bounces look physical and imperfect. Much higher and the bullet
sprays unpredictably, which is occasionally what you want (buckshot off a wall) but rarely the
default.

---

## Reacting to Bounces

`OnBounce` fires after each confirmed ricochet, with the running bounce count:

```lua
Signals.OnBounce:Connect(function(context, result, velocity, bounceCount, bounceForce)
    print(("Bounce #%d off %s at %.0f studs/s")
        :format(bounceCount, result.Instance.Name, velocity.Magnitude))
    -- decrement damage per ricochet, spawn a spark, play a ping...
    context.UserData.Damage *= 0.8
end)
```

**`OnBounce` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `context` | `BulletContext` | The bullet that bounced. |
| `result` | `RaycastResult` | The surface it bounced off. |
| `velocity` | `Vector3` | Post-bounce velocity (after restitution and perturbation). |
| `bounceCount` | `number` | Running total of bounces for this bullet. |
| `bounceForce` | `Vector3` | The impulse imparted at the impact, for physics reactions / recoil. |

---

## Overriding a Bounce Mid-Resolution

For fine control you can intercept a bounce *while the reflection math runs*. `OnPreBounce` fires
before the reflection is computed; `OnMidBounce` fires after. Both receive a `mutate` callback whose
effect is applied synchronously.

```lua
-- Force flat-floor reflection by overriding the surface normal
Signals.OnPreBounce:Connect(function(context, result, velocity, mutate)
    mutate(Vector3.new(0, 1, 0), nil)   -- (newNormal, newIncomingVelocity)
end)

-- Force a specific restitution after the reflect math runs
Signals.OnMidBounce:Connect(function(context, result, postVelocity, mutate)
    mutate(nil, 0.9, nil)   -- (postVelocity?, restitution?, perturbation?)
end)
```

**`OnPreBounce`**, `(context, result, velocity, mutate)`; its `mutate(normal?, incomingVelocity?)`
overrides the surface normal and/or the incoming velocity *before* the reflection is computed.

**`OnMidBounce`**, `(context, result, postVelocity, mutate)`; its
`mutate(postVelocity?, restitution?, perturbation?)` overrides the reflected velocity, restitution,
and scatter *after* the reflection is computed. Pass `nil` for any value to leave it untouched.

:::caution Don't yield in hook handlers
`mutate` is only live during the synchronous handler. Calling it after the handler returns logs a
warning and does nothing. Never `task.wait()` inside `OnPreBounce` / `OnMidBounce`.
:::

---

## Corner Traps

Bullets bouncing inside tight geometry can get stuck oscillating between two walls forever. Vetra's
**corner-trap detector** watches each bouncing bullet's position history and terminates ones that
stop making forward progress, ending them with the `CornerTrap` reason instead of looping.

It only engages for bullets that are actually bouncing (it needs a `CanBounceFunction` and sustained
ricochets to have anything to detect). Tune it through `:CornerTrap()` if your geometry is unusually
tight:

```lua
:CornerTrap()
    :MinProgressPerBounce(0.3)   -- each bounce must advance the bullet at least this fraction
    -- :TimeThreshold(), :DisplacementThreshold(), :EMAThreshold() also available
:Done()
```

The **Grenade** preset ships with corner-trap tuned for tight-space ricochets and is a good
reference starting point.

---

## Bounce vs Penetration

A single surface contact resolves as **either** a bounce **or** a [penetration](./penetration),
never both. Pierce is always evaluated first: if the pierce filter returns `true`, the bullet passes
through and the bounce filter is never consulted for that hit. See
[Penetration](./penetration#pierce-and-bounce-together) for how they interact.
