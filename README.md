# HybridSolver

Analytic-trajectory projectile simulation for Roblox with pierce, bounce, high-fidelity raycasting, and fluent typed behavior configuration.

## Installation

Drop the `HybridSolver` folder into `ReplicatedStorage` and require it from your weapon scripts.

## Quick Start
```lua
local HybridSolver = require(ReplicatedStorage.HybridSolver)
local BulletContext = require(ReplicatedStorage.HybridSolver.BulletContext)

local Solver = HybridSolver.new()
local Signals = Solver:GetSignals()

local Behavior = HybridSolver.BehaviorBuilder.new()
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

- **HybridSolver** — core simulation engine
- **BehaviorBuilder** — fluent typed configuration builder
- **BulletContext** — public-facing projectile state API