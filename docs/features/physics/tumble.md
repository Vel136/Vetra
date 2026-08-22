---
sidebar_position: 5
title: Tumble
---

# Tumble

A stable bullet flies nose-first: low drag, predictable arc. A **tumbling** bullet has lost that
stability, it's yawing and pitching, presenting its flank to the airflow instead of its point. Drag
spikes, accuracy collapses, and the path turns chaotic.

This happens in two situations Vetra models: a bullet slows below the speed its spin can stabilise,
or it punches through a soft target and exits destabilised. Either way, a tumbling round behaves
completely differently from a stable one, which is exactly what makes it interesting.

---

## Two Ways To Start Tumbling

**Speed-triggered.** Set `SpeedThreshold` and the bullet begins tumbling once it decelerates below
that speed.

**Pierce-triggered.** Set `OnPierce(true)` and the bullet begins tumbling the instant it pierces
anything, turning "the bullet ignored one wall" into "the bullet changed character after passing
through something."

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Pierce()
        :Max(1)
        :Filter(function() return true end)
    :Done()
    :Tumble()
        :OnPierce(true)          -- tumble immediately after the first pierce
        :DragMultiplier(4.0)     -- drag x4 while tumbling, slows down fast
        :LateralStrength(8)      -- chaotic lateral accel, studs/s^2
        -- :SpeedThreshold() unset -> pierce-based onset only
        -- :RecoverySpeed()  unset -> once tumbling, stays tumbling
    :Done()
    :Build()
```

---

## Fields

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:SpeedThreshold(n)` | `TumbleSpeedThreshold` | `nil` (off) | Begin tumbling below this speed. Unset disables speed-triggered tumble. |
| `:DragMultiplier(n)` | `TumbleDragMultiplier` | `3.0` | Drag is multiplied by this while tumbling. |
| `:LateralStrength(n)` | `TumbleLateralStrength` | `0` | Magnitude of the chaotic lateral acceleration, studs/s^2. |
| `:OnPierce(b)` | `TumbleOnPierce` | `false` | Begin tumbling immediately on the first pierce. |
| `:RecoverySpeed(n)` | `TumbleRecoverySpeed` | `nil` (permanent) | If set, the bullet recovers stability once it re-accelerates above this speed. |

:::note At least one trigger
Setting `DragMultiplier` / `LateralStrength` alone does nothing, a bullet only tumbles once a
trigger fires. Provide `SpeedThreshold`, `OnPierce(true)`, or both.
:::

---

## Recovery

By default tumbling is permanent, once destabilised, the bullet stays that way until it dies. Set
`RecoverySpeed` to let it stabilise again if it climbs back above that speed (rare in practice, since
tumbling *increases* drag, but useful for scripted scenarios or bullets under thrust).

---

## Reacting to Tumble

```lua
Signals.OnTumbleBegin:Connect(function(context, velocity)
    -- swap the tracer to a tumbling sprite, change the whistle audio
    print("Tumbling at", velocity.Magnitude, "studs/s")
end)

Signals.OnTumbleEnd:Connect(function(context, velocity)
    print("Recovered at", velocity.Magnitude, "studs/s")
end)
```

Both signals pass `(context: BulletContext, velocity: Vector3)`, the bullet and its velocity at the
moment stability is lost or regained. `OnTumbleEnd` only fires if a `RecoverySpeed` is configured and
reached.

---

## The Gameplay Payoff

Pair tumble-on-pierce with a [penetration](../penetration) build and the round gets a whole second
act: it exits cover slower, erratic, and doing less damage at range, which is physically accurate
and mechanically legible. Players quickly learn that shooting an enemy *through* a wall lands a
weaker, wilder hit than a clean shot, without you writing a single special case.
