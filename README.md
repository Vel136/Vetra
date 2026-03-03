# Vetra

Analytic-trajectory projectile simulation for Roblox with pierce, bounce, high-fidelity raycasting, and fluent typed behavior configuration.

## Installation

Drop the `Vetra` folder into `ReplicatedStorage` and require it from your weapon scripts.

## Quick Start
```lua
local Vetra = require(ReplicatedStorage.Vetra)
local BulletContext = require(ReplicatedStorage.Vetra.BulletContext)

local Solver = Vetra.new()
local Signals = Solver:GetSignals()

local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(500)
        :MinSpeed(5)
    :Done()
    :Bounce()
        :Max(3)
        :Restitution(0.7)
        :Filter(function(ctx, result, vel)
            return true
        end)
    :Done()
    :Build()

Signals.OnHit:Connect(function(context, result, velocity)
    print("Hit!", result)
end)

local context = BulletContext.new({
    Origin    = muzzlePosition,
    Direction = direction,
    Speed     = 200,
})

Solver:Fire(context, Behavior)
```

## Modules

- **Vetra** — core simulation engine
- **BehaviorBuilder** — fluent typed configuration builder
- **BulletContext** — public-facing projectile state API

## Documentation
Documentation can be found here:
https://vetra-docs.netlify.app
