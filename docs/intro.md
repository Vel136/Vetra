---
sidebar_position: 1
title: Get Started
---

# Get Started

Vetra is a projectile engine for Roblox. It moves bullets, detects hits, and gives you a stack of
combat features to build on: bounce, penetration, drag, Magnus, tumble, fragmentation, 6DOF
aerodynamics, homing, and optimization systems for scaling to many bullets.

This page gets you from nothing to a bullet that hits something. Three pieces do it: a **solver**,
a **behavior**, and a **context**.

:::tip Bullets tunnelling through thin walls?
If you've hit the common problem of fast bullets passing through thin geometry, see
[Tunnelling & Precision](./features/simulation/tunnelling).
:::

---

## 1. The Solver

The solver owns the frame loop. Create it once and keep it, every bullet you fire is stepped by
this single object.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.Vetra)

local Solver  = Vetra.new()
local Signals = Solver:GetSignals()
```

`Vetra.new()` connects to the correct RunService event automatically, `RenderStepped` on the
client, `Heartbeat` on the server, and steps every active cast in a single pass. You do **not**
create one solver per bullet. Most games need exactly one.

---

## 2. Listen to Signals

Every event a bullet produces is delivered through the solver's signal table. Connect once, at
startup, and you receive events from every bullet the solver ever fires.

```lua
Signals.OnFire:Connect(function(context, behavior)
    -- Fires the instant Fire() registers the cast, before the first step.
    print("Fired:", context.Id)
end)

Signals.OnHit:Connect(function(context, result, velocity)
    if result then
        print("Hit", result.Instance.Name, "at", result.Position)
    else
        print("Bullet expired without hitting anything")
    end
end)
```

`result` is `nil` when a bullet ends by running out of distance or speed rather than striking a
surface, always check it before reading `result.Instance`.

---

## 3. Define a Behavior

A **behavior** is the ruleset for a kind of bullet: how far it flies, how it bounces, what physics
apply. Build it once per weapon type, not once per shot.

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(500)
        :MinSpeed(5)
    :Done()
    :Bounce()
        :Max(3)
        :Restitution(0.7)
        :Filter(function(context, result, velocity)
            return true -- ricochet off everything
        end)
    :Done()
    :Build()
```

`BehaviorBuilder` gives you typed setters, build-time validation, and a frozen result. You can also
pass a plain table to `Fire()` for quick tests, both produce the same `VetraBehavior`.

---

## 4. Fire

A **context** carries one shot: where it started, which way it's going, how fast, and any data you
want to travel with it.

```lua
local BulletContext = Vetra.BulletContext

local context = BulletContext.new({
    Origin    = muzzle.Position,
    Direction = (target - muzzle.Position).Unit,
    Speed     = 200,
    UserData  = { Damage = 75 },
})

Solver:Fire(context, Behavior)
```

That's a working gun. The solver steps the bullet each frame, your `OnHit` handler runs when it
lands, and `context.UserData.Damage` is available in every signal.

---

## Don't Start From Scratch

`BehaviorBuilder` ships presets you can fire immediately or chain overrides onto:

```lua
local Sniper  = Vetra.BehaviorBuilder.Sniper():Build()   -- 1500 studs, pierce, high-fidelity
local Grenade = Vetra.BehaviorBuilder.Grenade():Build()  -- slow, bouncy, corner-trap aware
local Pistol  = Vetra.BehaviorBuilder.Pistol():Build()   -- 300 studs, single pierce

-- Chain overrides on any preset before :Build()
local LongSniper = Vetra.BehaviorBuilder.Sniper()
    :Physics():MaxDistance(2000):Done()
    :Build()
```

---

## Where to Next

- **[Installation](./installation)**, drop the module in and require it.
- **[Bounce](./features/bounce)** and **[Penetration](./features/penetration)**, the two core
  interaction models.
- **[Physics](./features/physics/overview)**, drag, spin, tumble, 6DOF, and the rest.
- **[Simulation](./features/simulation/tunnelling)**, how a bullet is stepped, and how tunnelling
  and raycast precision are handled.
- **[Optimizations](./features/optimizations/lod)**, scale to thousands of bullets.
- **[API Reference](/api/)**, every class, field, and signal.
