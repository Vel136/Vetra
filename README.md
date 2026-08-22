# Vetra

A projectile engine for Roblox. It moves bullets, detects hits, and provides a
stack of combat features to build on: bounce, penetration, drag, Magnus, tumble,
fragmentation, 6DOF aerodynamics, homing, and optimization systems for scaling to
many bullets.

Written in Luau, `--!strict` throughout. No external dependencies.

## Install

Vetra is one folder and one `require`. There is no build step.

1. Get the **Vetra** model from the Creator Marketplace, or open the `.rbxm` release.
2. Drag the `Vetra` folder into `ReplicatedStorage`.
3. Require it:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.Vetra)
```

Both client and server need to be able to require it.

If you are working from this repository directly, the library source lives in
`src/`, which corresponds to the `Vetra` folder in the instructions above.

## Quick start

Three pieces make a working gun: a solver, a behavior, and a context.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.Vetra)

-- 1. The solver owns the frame loop. Create one and keep it.
--    You do not create one solver per bullet; most games need exactly one.
local Solver  = Vetra.new()
local Signals = Solver:GetSignals()

-- 2. Connect once at startup. You receive events from every bullet
--    this solver ever fires.
Signals.OnHit:Connect(function(context, result, velocity)
    if result then
        print("Hit", result.Instance.Name, "at", result.Position)
    else
        print("Bullet expired without hitting anything")
    end
end)

-- 3. A behavior is the ruleset for a kind of bullet. Build it once
--    per weapon type, not once per shot.
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(500)
        :MinSpeed(5)
    :Done()
    :Bounce()
        :Max(3)
        :Restitution(0.7)
    :Done()
    :Build()

-- 4. A context carries one shot.
local Context = Vetra.BulletContext.new({
    Origin    = muzzle.Position,
    Direction = (target - muzzle.Position).Unit,
    Speed     = 200,
    UserData  = { Damage = 75 },
})

Solver:Fire(Context, Behavior)
```

`result` is `nil` when a bullet ends by running out of distance or speed rather
than striking a surface. Always check it before reading `result.Instance`.

`context.UserData` travels with the shot and is available in every signal.

## Presets

`BehaviorBuilder` ships presets you can fire immediately or chain overrides onto:

```lua
local Sniper  = Vetra.BehaviorBuilder.Sniper():Build()   -- 1500 studs, pierce, high-fidelity
local Grenade = Vetra.BehaviorBuilder.Grenade():Build()  -- slow, bouncy, corner-trap aware
local Pistol  = Vetra.BehaviorBuilder.Pistol():Build()   -- 300 studs, single pierce

local LongSniper = Vetra.BehaviorBuilder.Sniper()
    :Physics():MaxDistance(2000):Done()
    :Build()
```

## API surface

You require the top-level `Vetra` and reach everything through it. You never
require submodules directly.

| Access | What it is |
|--------|------------|
| `Vetra.new()` | The serial solver |
| `Vetra.newParallel()` | The parallel (Actor) solver |
| `Vetra.BehaviorBuilder` | Fluent behavior builder and presets |
| `Vetra.BulletContext` | Per-shot context constructor |
| `Vetra.Enums` | Named constants (`DragModel`, `TerminateReason`, ...) |
| `Vetra.StaticOccupancy` | Baked voxel occupancy grid |
| `Vetra.DynamicOccupancy` | Occupancy over registered moving parts |
| `Vetra.VoxelBaker` | Builds a static grid from world geometry |
| `Vetra.OccupancyChunks` | Saves a baked grid into the place file |
| `Vetra.Profiler` | Instrumentation hooks |

## Features

- **Interaction:** bounce with restitution and filters, penetration and pierce
  limits, corner-trap detection.
- **Physics:** gravity and drag (including G-series drag tables), Magnus effect,
  tumble, gyroscopic drift, wind, Coriolis, full 6DOF rigid-body aerodynamics,
  homing, fragmentation.
- **Simulation:** high-fidelity sub-segment stepping for fast bullets against
  thin geometry, frame budgeting, trajectory resimulation.
- **Scaling:** a parallel Actor-based solver, LOD throttling by distance,
  spatial partitioning, and static/dynamic occupancy culling.

If you have hit the common problem of fast bullets passing through thin walls,
see the Tunnelling and Precision documentation.

## Documentation

Full guides and the API reference are published from the `docs/` folder via
Moonwave.

## License

MIT. See [LICENSE](LICENSE).
