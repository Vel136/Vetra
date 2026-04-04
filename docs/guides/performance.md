---
sidebar_position: 4
---

# Performance

A single bullet costs almost nothing. A hundred bullets, each bouncing and running drag calculations and firing Magnus forces every 50ms, on a server handling 50 players, that adds up.

This page is about understanding where the cost comes from and how to control it.

---

## Where the Time Goes

Every active cast, every frame, does some subset of these things:

1. **Compute current position**, evaluating `P(t) = Origin + V₀t + ½At²`. This is fast. Three multiplies and two adds per axis.

2. **Raycast**, `workspace:Raycast`. This is the dominant cost. Raycasts cross the engine boundary, touch the physics engine's broadphase and narrowphase, and their cost scales with scene complexity. One bullet doing one raycast per frame is negligible. Two hundred bullets doing raycasts per frame is not.

3. **Drag/Magnus recalculation**, every `DragSegmentInterval` seconds, the solver recomputes the drag deceleration and opens a new trajectory segment. This involves a cross product (Magnus), a lookup table index (G-series models), and a `Kinematics.ModifyTrajectory`. It's cheap but not free, and it happens for every cast with drag enabled.

4. **High-fidelity sub-segments**, if a cast has `HighFidelitySegmentSize` enabled, it fires multiple raycasts per frame instead of one. The adaptive system tries to stay within `HighFidelityFrameBudget` milliseconds, but at high bullet counts this budget applies *per cast*, so 50 high-fidelity casts each spending 4ms would be 200ms of raycast time on one frame. Use high-fidelity selectively.

5. **Signal emissions**, `OnTravel` fires for every active cast every frame. If your `OnTravel` handler is doing expensive work, this cost is multiplied by active cast count.

---

## LOD: Spending Less on Distant Bullets

Not every bullet needs full-frequency simulation. A bullet 600 studs away from every player is invisible and doesn't affect the game state, simulating it at the same frequency as a bullet that just left the barrel is wasteful.

`LODDistance` lets a cast step at reduced frequency when it's farther than a configured distance from the LOD origin:

```lua
-- Build behavior with LOD enabled
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics()
        :MaxDistance(800)
    :Done()
    :Build()

-- Pass LOD distance directly on the raw table:
Solver:Fire(context, setmetatable({
    LODDistance = 300,  -- reduce frequency beyond 300 studs from LOD origin
}, { __index = Behavior }))

-- Update LOD origin every frame (client: camera, server: central interest point)
RunService.RenderStepped:Connect(function()
    Solver:SetLODOrigin(workspace.CurrentCamera.CFrame.Position)
end)
```

When a cast is in LOD mode, Vetra accumulates the missed deltas and applies them when the cast re-enters range. The bullet doesn't teleport, it catches up correctly using the same analytic formula. From the player's perspective nothing changes; they never see a distant bullet skipping.

---

## Spatial Partitioning: HOT, WARM, and COLD

LOD is binary, in range or out. The spatial partition adds three tiers:

- **HOT**, within `HotRadius` studs of an interest point. Full-frequency simulation.
- **WARM**, within `WarmRadius` studs. Reduced frequency.
- **COLD**, outside all warm radii. Further reduced.

Interest points are the positions you care about, players, objectives, anything that might be near active bullets. The partition rebuilds every `UpdateInterval` frames and classifies each cast's current position.

```lua
local Solver = Vetra.new({
    SpatialPartition = {
        HotRadius    = 150,   -- full simulation within 150 studs of a player
        WarmRadius   = 400,   -- reduced simulation within 400 studs
        FallbackTier = "COLD", -- everything beyond 400 studs gets COLD
        UpdateInterval = 3,   -- rebuild every 3 frames
    }
})

-- Update interest points every frame
RunService.Heartbeat:Connect(function()
    local points = {}
    for _, player in Players:GetPlayers() do
        local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if root then
            points[#points + 1] = root.Position
        end
    end
    Solver:SetInterestPoints(points)
end)
```

The combination of LOD and spatial partitioning means a server with 200 active bullets, spread across a large map with players clustered together, is spending almost all of its simulation budget on the bullets that are actually near players, while distant bullets cost almost nothing.

---

## The Parallel Solver

Vetra's serial solver runs every cast on the main thread, one after another. On Roblox's multi-core server hardware there's an alternative.

`Vetra.newParallel` distributes physics across multiple Roblox Actors, separate execution contexts that run concurrently on different cores. Raycasts, drag, Magnus, homing, bounce math, and corner-trap detection all happen in parallel. Signal firing, user callbacks, and cosmetic updates are flushed on the main thread afterward.

```lua
local Solver = Vetra.newParallel({
    ShardCount = 6,   -- tune to your server's core count; 4–8 is typical
})

-- The API is identical to Vetra.new(), no code changes needed
Solver:Fire(context, Behavior)
```

The benchmarks tell the story clearly. With travel-only bullets (pure raycasts, no callbacks):

| Bullets | Serial | Parallel | Speedup |
|--------:|:------:|:--------:|:-------:|
| 50 | 10.3 ms | 4.2 ms | 2.5x |
| 200 | 14.0 ms | 4.2 ms | 3.4x |
| 1,000 | 45.2 ms | 4.2 ms | **10.8x** |
| 5,000 | 174.7 ms | 5.5 ms | **32x** |
| 20,000 |, | 10.3 ms |, |

The parallel solver's frame time is essentially flat from 25 to 2,000 bullets, hovering around 4ms. That's the signature of work filling unused core capacity. The serial solver, by contrast, hits 45ms at 1,000 bullets and 174ms at 5,000. Adding a `CanBounceFunction` or `CanPierceFunction` costs almost nothing in the parallel path because callbacks are batch-flushed rather than per-cast round-trips.

The crossover point, where parallel overhead is paid off, is around **25–50 bullets** for travel-only work and around **200 bullets** for bounce/pierce with callbacks. Below that, serial and parallel are within noise of each other. Above it, the gap widens every step of the way.

See the [Benchmarks](./benchmarks) guide for full tables, all four profiles, and instructions for running the benchmarker against your own weapon behaviors.

If `newParallel` fails to construct internally, which can happen if Actor parenting fails, it falls back to a serial solver automatically and logs an error. The solver still works. Check output logs if parallel performance isn't being observed.

:::caution CastFunction limitation
`CastFunction`, the override for using `Spherecast` or custom cast logic instead of `workspace:Raycast`, is incompatible with the parallel solver. Functions can't cross Actor boundaries via message passing. If you need `CastFunction`, use `Vetra.new()`.
:::

---

## Tuning `OnTravel`

`OnTravel` fires every frame for every active cast. If you're using it to update a cosmetic bullet's position, this is correct and expected. If you're using it to do anything heavier, damage-over-time zones, proximity checks, expensive table lookups, that cost multiplies with cast count.

For batch processing, `OnTravelBatch` is more efficient. Instead of receiving one event per cast per frame, you receive one event with all travelling casts at once:

```lua
Signals.OnTravelBatch:Connect(function(contexts)
    for _, context in contexts do
        -- update cosmetics, check proximity, etc.
    end
end)
```

The difference matters when you have 150 active casts. With `OnTravel`, you're running 150 separate signal emissions with 150 separate table allocations. With `OnTravelBatch`, you're running one emission with one table and you iterate it yourself.

Also: `OnTravel` runs on the `Fire` path, not `FireSafe`. Handlers **must not throw or yield**. An error in an `OnTravel` handler is not caught and will propagate up. If you're doing anything that could error, use `OnTravelBatch` which uses `FireSafe`.

---

## A Practical Scaling Guide

| Scenario | Recommendation |
|----------|---------------|
| < 25 active bullets | `Vetra.new()`, parallel overhead not worth it |
| 25–200 bullets, no callbacks | `Vetra.newParallel()` already faster |
| 25–200 bullets, with callbacks | Either; difference is within noise |
| 200+ bullets with any callbacks | `Vetra.newParallel()`, gap grows fast from here |
| 1,000+ bullets | `Vetra.newParallel()`, serial is 10x slower |
| High-fidelity on many bullets | Increase `FrameBudget` per cast, reduce `ShardCount` to leave headroom |
| Dense maps with complex geometry | Increase `DragSegmentInterval` to lower drag-recalc frequency |
| Server tracking player positions | `SetInterestPoints` every Heartbeat, not every RenderStepped |

The most impactful single change for a server under load is usually the spatial partition's `FallbackTier`. Setting it to `"COLD"` means bullets outside all player radii are nearly free. On a large map with spread-out players and many simultaneous bullets, this alone can halve simulation cost.

For detailed numbers across every profile and bullet count, see the [Benchmarks](./benchmarks) page.
