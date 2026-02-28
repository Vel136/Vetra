# Getting Started

HybridSolver is an analytic-trajectory projectile simulation module for Roblox.
It supports pierce, bounce, high-fidelity sub-segment raycasting, and fluent typed behavior configuration via `BehaviorBuilder`.

## Installation

Drop the `HybridSolver` folder into `ReplicatedStorage` and require it from your weapon scripts.

## Basic Setup

```lua
local HybridSolver  = require(ReplicatedStorage.HybridSolver)
local BulletContext = require(ReplicatedStorage.HybridSolver.BulletContext)

-- Create the solver once (connects the frame loop)
local Solver  = HybridSolver.new()
local Signals = Solver:GetSignals()

-- Connect to signals once at initialisation
Signals.OnHit:Connect(function(context, result, velocity)
    if result then
        print("Hit", result.Instance.Name, "at", result.Position)
    else
        print("Bullet expired (distance or speed)")
    end
end)

Signals.OnBounce:Connect(function(context, result, velocity, bounceCount)
    print("Bounce #" .. bounceCount)
end)
```

## Firing a Bullet

```lua
-- Build a behavior (do this once per weapon type, not per shot)
local Behavior = HybridSolver.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(500)
        :MinSpeed(5)
    :Done()
    :Bounce()
        :Max(3)
        :Restitution(0.7)
        :Filter(function(ctx, result, vel)
            return true -- bounce off everything
        end)
    :Done()
    :Build()

-- Fire
local context = BulletContext.new({
    Origin    = muzzlePosition,
    Direction = direction,
    Speed     = 200,
})

Solver:Fire(context, Behavior)
```

## Using Presets

`BehaviorBuilder` ships with three preset constructors as a starting point:

```lua
-- Sniper: long range, pierce-capable, high fidelity
local SniperBehavior = HybridSolver.BehaviorBuilder.Sniper():Build()

-- Grenade: low speed, bouncy, gravity-affected
local GrenadeBehavior = HybridSolver.BehaviorBuilder.Grenade():Build()

-- Pistol: standard range, single pierce
local PistolBehavior = HybridSolver.BehaviorBuilder.Pistol():Build()
```

You can chain additional overrides on any preset before calling `:Build()`:

```lua
local Behavior = HybridSolver.BehaviorBuilder.Sniper()
    :Physics()
        :MaxDistance(2000)
    :Done()
    :Build()
```

## Attaching Metadata

Use `UserData` to attach weapon-specific data that travels with the bullet and is available in every signal handler:

```lua
context.UserData.Damage    = 75
context.UserData.ShooterId = Players.LocalPlayer.UserId

Signals.OnHit:Connect(function(context, result, velocity)
    print("Damage:", context.UserData.Damage)
    print("Fired by:", context.UserData.ShooterId)
end)
```

## Terminating Early

```lua
-- From a signal handler or any code holding the context
context:Terminate()
```

## Enabling the Visualizer

Set `VisualizeCasts = true` in your behavior (or use `:Debug():Visualize(true):Done()`) to draw
cast segments, normals, bounce vectors, and corner trap markers in the world. Has zero runtime cost when disabled.

```lua
local Behavior = HybridSolver.BehaviorBuilder.new()
    :Debug()
        :Visualize(true)
    :Done()
    :Build()
```
