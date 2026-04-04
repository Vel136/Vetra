---
sidebar_position: 2
---

# Making Bullets Feel Real

There's a version of a shooter that technically works, bullets fire, hit things, deal damage, but doesn't *feel* right. Something about the projectiles is weightless. They travel in a laser-straight line, ignore wind, never tumble, and arrive at 300 studs exactly as crisply as they left the barrel.

It functions. It doesn't feel like a gun.

The gap between "technically works" and "feels real" is physics. Not complicated physics, a few forces applied incrementally that change how the bullet travels through the air. This page explains each one: what it is, why it matters, and when you'd actually use it.

---

## Gravity and Bullet Drop

This one you probably already have. A bullet fired horizontally doesn't stay horizontal, it falls. The further the target, the lower you need to aim.

Vetra applies gravity through the acceleration term in its kinematic formula. The default is `workspace.Gravity` pointing downward, read at the time the behavior is built:

```lua
-- Default, uses workspace.Gravity automatically
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(800)
    :Done()
    :Build()
```

If you're building a zero-gravity map, a space level, or an underwater area with reduced gravity, override it:

```lua
:Physics()
    :Gravity(Vector3.new(0, -5, 0))  -- 5 studs/s² downward, floaty, underwater feel
:Done()
```

Bullet drop is the baseline. Everything else layered on top makes it feel *specific* rather than generic.

---

## Drag, Why Bullets Slow Down

In a vacuum, a bullet would travel the same speed across any distance. In air, it doesn't.

Drag is the resistance the air pushes back with. The faster you go, the more it pushes. A supersonic bullet bleeds speed quickly as it compresses the air in front of it. A subsonic bullet slows more gently. Shotgun pellets, which are spherical and blunt, decelerate far faster than the tapered projectile from a rifle.

This matters for gameplay in three ways.

**Damage falloff.** If you tie damage to velocity, a bullet that has slowed down to 60% of its firing speed deals less damage. Long-range hits naturally do less damage than close-range ones without needing a separate distance-based falloff system.

**Lead and arc.** At 800 studs, a slow-moving subsonic round has had several seconds to drop and decelerate. Players aiming at moving targets have to lead more. That's skill-testing in a way that hitscan can never replicate.

**Feel.** A rifle that feels snappy and penetrating at close range but requires careful aim at long range, purely because of physics, feels like a rifle. Not a magic wand with a gun skin.

```lua
local Behavior = BehaviorBuilder.new()
    :Physics()
        :MaxDistance(800)
        :MinSpeed(30)
    :Done()
    :Drag()
        :Coefficient(0.003)
        :Model(BehaviorBuilder.DragModel.G7)   -- long boat-tail, modern rifle standard
        :SegmentInterval(0.05)                 -- recalculate drag every 50ms
    :Done()
    :Build()
```

**Choosing a drag model.** The `:Model()` setter controls which drag curve is used. Always pass a value from `BehaviorBuilder.DragModel` rather than a raw string, typos on raw strings pass the type checker silently and only fail at `:Build()`.

For most rifles and modern guns, `BehaviorBuilder.DragModel.G7` is the right choice. It models a long boat-tail projectile, the standard reference for contemporary small-arms ballistics. For shotgun slugs or blunt projectiles, `G6` applies more drag. For pistols and hollow points, `G8`. For muskets and round shot, `GL` (the "lead ball" model) gives the heavy, arcing feel of pre-rifled weapons.

`Quadratic` is the default and is physically accurate for most situations where historical accuracy isn't required, drag proportional to speed squared. For pure gameplay tuning, it's often all you need.

---

## Supersonic and Subsonic Profiles

Real bullets behave differently depending on whether they're moving faster or slower than the speed of sound.

A supersonic bullet is creating a shockwave in front of it. The drag profile is different. The acoustic signature is the iconic crack followed by the thump of the shot, the crack arriving first because it travelled with the bullet, the thump arriving later from the muzzle. Ballistically, the transition from supersonic to subsonic is a zone of instability where the bullet can yaw, deflect, and lose accuracy.

Vetra tracks whether a bullet is supersonic (above 343 studs/s) and lets you configure different physics for each regime:

```lua
local Behavior = BehaviorBuilder.new()
    :Drag()
        :Coefficient(0.002)
        :Model(BehaviorBuilder.DragModel.G7)
    :Done()
    :SpeedProfiles()
        :Thresholds({ 343 })
        :Supersonic()
            :DragCoefficient(0.0015)    -- lower drag pushing through compressed air
        :Done()
        :Subsonic()
            :DragCoefficient(0.004)     -- higher drag in the unstable transition zone
            :Restitution(0.4)           -- bounces are sloppier when slow
            :NormalPerturbation(0.06)   -- more scatter on surface contact
        :Done()
    :Done()
    :Build()

Signals.OnSpeedThresholdCrossed:Connect(function(context, threshold, velocity)
    -- swap tracer colour, change fire sound, etc.
end)
```

For most games this level of detail is optional. But if you're building a milsim-adjacent experience or want long-range shots to have a distinct feel from close-range ones, speed profiles are what separate "simulated" from "simulated well."

---

## Magnus Effect, The Curveball

A spinning bullet moving through air doesn't travel straight. It curves.

The force is perpendicular to both the spin axis and the velocity, the Magnus effect. It's why a baseball pitcher can throw a curveball. It's why real-world rifles exhibit spin drift, bullets fired from right-hand twist barrels drift slightly right over long distances. It's why a well-hit topspin tennis ball dips faster than you'd expect.

In a game, this is useful in a few ways. You can build trick-shot mechanics. You can make specific weapons have a characteristic drift that skilled players need to account for. You can create a gun that literally curves its shots around cover.

```lua
local Behavior = BehaviorBuilder.new()
    :Magnus()
        :SpinVector(Vector3.new(0, 0, 1) * 300)  -- rightward spin, 300 rad/s
        :Coefficient(0.0001)
        :SpinDecayRate(0.05)    -- spin decays 5% per second as air slows it
    :Done()
    :Build()
```

:::caution Start small
`MagnusCoefficient` is extremely sensitive. The force is `Cm × (SpinVector × Velocity)`, at 600 studs/s with a spin rate of 300, even `0.0001` produces visible drift. Start at `0.00005` and work up incrementally. Going straight to `0.001` will produce dramatic swerving that looks more like a homing missile than a bullet.
:::

---

## Gyroscopic Drift

Magnus drift is the *lateral* curl caused by spin. Gyroscopic drift is the *directional yaw* caused by the same spin interacting with the bullet's own precession around its velocity axis.

The practical difference: Magnus curves the path cleanly. Gyroscopic drift adds a slow, continuous lateral wander, subtle at short range, accumulating into noticeable deviation at long range.

Real bullets from right-hand rifling drift slightly right and slightly up at long range. This is the combination of gyroscopic precession and Magnus effect. For a milsim game this is a compelling detail. For most games it's noise.

```lua
local Behavior = BehaviorBuilder.new()
    :GyroDrift()
        :Rate(0.4)    -- lateral acceleration in studs/s²
        -- :Axis() not set, defaults to world UP (right-hand rifling)
    :Done()
    :Build()
```

Use this sparingly. It's most effective as a barely-perceptible force that snipers notice at extreme range, not as something that requires overcorrection on every shot.

---

## Tumble, When Bullets Stop Flying

A stable bullet is an aerodynamic bullet. The pointy end leads, the drag is low, the flight is predictable.

A tumbling bullet is a bullet that has lost that stability. It's yawing, pitching, presenting its side to the airflow instead of its nose. Drag spikes. Accuracy collapses. The path becomes chaotic.

This can happen when a bullet slows down below the speed that its rotational stabilisation can maintain. It can happen when a bullet passes through a soft target and exits destabilised. Either way, a tumbling bullet behaves completely differently from a stable one.

```lua
local Behavior = BehaviorBuilder.new()
    :Pierce()
        :Max(1)
        :Filter(function(ctx, result, vel) return true end)
    :Done()
    :Tumble()
        :OnPierce(true)          -- begin tumbling immediately after first pierce
        :DragMultiplier(4.0)     -- drag multiplied by 4, slows down fast
        :LateralStrength(8)      -- chaotic lateral acceleration in studs/s²
        -- :SpeedThreshold() not set, pierce-based onset only
        -- :RecoverySpeed() not set, once tumbling, permanent
    :Done()
    :Build()

Signals.OnTumbleBegin:Connect(function(context, velocity)
    -- visual: swap tracer to a tumbling sprite, change audio
end)
```

The result: bullets that exit a target are fast and predictable. Bullets that exit are slower, erratic, and do less damage at range, which is physically accurate. It turns pierce from "bullet ignores one wall" into "bullet changes character after passing through something."

---

## Fragmentation

When a round hits and breaks apart, it sends shards outward in a cone. Fragmentation simulates this by spawning child bullets at the pierce point, each flying in a slightly different direction.

```lua
local Behavior = BehaviorBuilder.new()
    :Pierce()
        :Max(1)
        :Filter(function(ctx, result, vel) return true end)
    :Done()
    :Fragmentation()
        :OnPierce(true)
        :Count(5)         -- five fragments
        :Deviation(20)    -- spread within a 20-degree half-angle cone
    :Done()
    :Build()

Signals.OnBranchSpawned:Connect(function(parentContext, childContext)
    -- inherit a fraction of the parent's damage
    childContext.UserData.Damage = parentContext.UserData.Damage * 0.25
    childContext.UserData.IsFragment = true
end)
```

Each fragment is a fully live cast. It can bounce, it can hit things, it fires `OnHit` independently. If you want fragments that have their own drag and tumble, that's available too, either set it on the shared behavior the fragments inherit, or intercept `OnBranchSpawned` and fire new casts with custom behavior immediately.

---

## Coriolis Effect

The Coriolis effect is the deflection caused by Earth's rotation. A bullet fired north in the northern hemisphere drifts slightly east. Fired south, it drifts west. At the equator the drift is purely horizontal. At the poles, it rotates the bullet's ground track.

In a real weapon at real-world distances and velocities, the Coriolis effect is real but tiny, irrelevant at combat ranges, detectable at extreme long range by specialist snipers. In a game, it can be exaggerated into a visible, tactile mechanic.

This is a **map-level setting**, not a bullet-level one. Every bullet fired through the same solver is affected equally, it's a property of the simulated environment, not the weapon.

```lua
-- Arctic map, latitude 75°, 1200× exaggeration
Solver:SetCoriolisConfig(75, 1200)

-- Equatorial map, latitude 0°, east/west drift only
Solver:SetCoriolisConfig(0, 800)

-- Turn it off for standard maps (default)
Solver:SetCoriolisConfig(45, 0)
```

At scale `1000`, Coriolis is clearly perceptible at ~300 studs. At `3000` it's a dominant force players must actively compensate for. It's a useful differentiator for maps that want to feel geographically grounded, or as a hardmode modifier in competitive modes.

---

## Putting It Together

None of these features are mandatory. A simple bounce-and-pierce setup without drag will work perfectly well for most shooters. The physics features exist for when you want the weapon to feel like *that specific weapon*, not just a projectile with hitboxes.

A sniper rifle that starts supersonic, transitions to subsonic at range, drifts slightly right from spin drift, and requires leading against moving targets at long range, that's a *character*. Players learn its specific feel. Mastering it becomes part of the skill expression.

The right level of simulation for your game is a creative decision, not a technical one. Start with the minimum that makes the weapon feel right. Add physics one feature at a time until it feels like what you were imagining.