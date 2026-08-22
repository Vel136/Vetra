---
sidebar_position: 3
title: Speed Profiles
---

# Speed Profiles

Real bullets behave differently above and below the speed of sound. A supersonic round is punching a
shockwave through compressed air; as it decelerates through the transonic zone it becomes briefly
unstable, it can yaw, deflect, and lose accuracy, before settling into steady subsonic flight.

Speed profiles let you configure **different physics for different speed regimes** on the same
bullet. The solver tracks the bullet's speed against your thresholds and blends in the matching
profile.

---

## The Setup

`SpeedThresholds` is a list of speeds (studs/s) at which the profile switches and
`OnSpeedThresholdCrossed` fires. Roblox's real speed of sound reference is **343 studs/s** if you're
using 1 stud = 1 metre.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Drag()
        :Coefficient(0.002)
        :Model(Vetra.BehaviorBuilder.DragModel.G7)
    :Done()
    :SpeedProfiles()
        :Thresholds({ 343 })            -- cross-over at the sound barrier
        :Supersonic()
            :DragCoefficient(0.0015)    -- lower drag slicing through compressed air
        :Done()
        :Subsonic()
            :DragCoefficient(0.004)     -- higher drag in the unstable transition
            :Restitution(0.4)           -- sloppier bounces when slow
            :NormalPerturbation(0.06)   -- more scatter on contact
        :Done()
    :Done()
    :Build()
```

---

## Profile Fields

Each of `:Supersonic()` and `:Subsonic()` accepts the same optional overrides. Anything you don't
set falls back to the bullet's base behavior, a profile only overrides the fields you name.

| Setter | Overrides | Description |
|--------|-----------|-------------|
| `:DragCoefficient(n)` | `DragCoefficient` | Drag scale for this regime. |
| `:DragModel(enum)` | `DragModel` | Drag curve for this regime. |
| `:Restitution(n)` | `Restitution` | Bounce energy retention while in this regime. |
| `:MaterialRestitution(t)` | `MaterialRestitution` | Per-material restitution overrides for this regime. |
| `:NormalPerturbation(n)` | `NormalPerturbation` | Bounce scatter while in this regime. |

| Setter (on `:SpeedProfiles()`) | Field | Default | Description |
|-------------------------------|-------|--------:|-------------|
| `:Thresholds(t)` | `SpeedThresholds` | `{}` | Speeds (studs/s) at which the profile switches and the signal fires. |
| `:Supersonic()` | `SupersonicProfile` | `nil` | Profile applied while faster than the highest crossed threshold. |
| `:Subsonic()` | `SubsonicProfile` | `nil` | Profile applied while slower. |

---

## Reacting to the Crossing

`OnSpeedThresholdCrossed` fires whenever the bullet's speed passes one of your thresholds, perfect
for swapping a tracer colour, changing the fire sound, or triggering the sonic-crack audio.

```lua
Signals.OnSpeedThresholdCrossed:Connect(function(context, threshold, ascending, speed)
    if threshold == 343 and not ascending then
        -- bullet just went subsonic
        context.UserData.Tracer.Color = Color3.fromRGB(120, 160, 255)
    end
end)
```

**`OnSpeedThresholdCrossed` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `context` | `BulletContext` | The bullet that crossed a threshold. |
| `threshold` | `number` | Which threshold value was crossed. |
| `ascending` | `boolean` | `true` if speeding up through it, `false` if slowing down through it. |
| `speed` | `number` | The bullet's speed at the moment of crossing. |

---

## When To Bother

For most games this is optional flavour. It earns its keep in milsim-adjacent experiences, or
anywhere you want a long-range shot to feel *distinct* from a close one, a sniper round that leaves
supersonic and crisp, destabilises through transonic, and arrives subsonic and lazy is a weapon
players learn the feel of. If your game doesn't need that, leave `SpeedThresholds` empty and the
whole system costs nothing.
