---
sidebar_position: 2
title: Installation
---

# Installation

Vetra is one folder and one `require`. There is no build step, no external dependency to fetch, and
nothing to configure before your first shot.

---

## Requirements

| | |
|---|---|
| **Platform** | Roblox (Luau, `--!strict` throughout) |
| **Location** | `ReplicatedStorage`, both client and server must be able to require it |
| **Dependencies** | None external. Ships with one bundled internal module, [VeSignal](./credits#dependencies). |
| **Version** | This documentation covers **Vetra V7.0.0**. |

---

## Roblox Studio (drag & drop)

1. Get the **Vetra** model from the Creator Marketplace (or open the `.rbxm` release).
2. Drag the `Vetra` folder into **ReplicatedStorage**.
3. Require it from any script:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.Vetra)
```

That's it. The folder is self-contained, everything under `Vetra` (Core, Physics, Occupancy,
Parallel, and the builders) is required internally.

---

## Verify It Works

Drop this in a **LocalScript** under `StarterPlayerScripts` and press Play. You should see a hit
print in the output when the ray finds the ground.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.Vetra)

local Solver  = Vetra.new()
local Signals = Solver:GetSignals()

Signals.OnHit:Connect(function(context, result)
    print(result and ("Hit " .. result.Instance:GetFullName()) or "Expired")
end)

local camera  = workspace.CurrentCamera
local context = Vetra.BulletContext.new({
    Origin    = camera.CFrame.Position,
    Direction = camera.CFrame.LookVector,
    Speed     = 300,
})

Solver:Fire(context, Vetra.BehaviorBuilder.Pistol():Build())
```

If it prints a hit, you're installed correctly. Head to **[Get Started](./intro)** to build a real
weapon, or jump straight into the **[Features](./features/bounce)**.

---

## Where the Pieces Live

You require the top-level `Vetra` and reach everything through it, you never require submodules
directly:

| Access | What it is |
|--------|------------|
| `Vetra.new()` | The serial solver |
| `Vetra.newParallel()` | The parallel (Actor) solver |
| `Vetra.BehaviorBuilder` | Fluent behavior builder + presets |
| `Vetra.BulletContext` | Per-shot context constructor |
| `Vetra.Enums` | Named constants (`DragModel`, `TerminateReason`, ...) |
| `Vetra.StaticOccupancy` / `Vetra.DynamicOccupancy` / `Vetra.VoxelBaker` | [Occupancy grids](./features/optimizations/occupancy/static) |
| `Vetra.OccupancyChunks` | [Saving a baked grid into the place file](./features/optimizations/occupancy/static#serialization-bake-once-load-forever) |

Full signatures are in the **[API Reference](/api/)**.
