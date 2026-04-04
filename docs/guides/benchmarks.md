---
sidebar_position: 5
---

# Benchmarks

Numbers first, then everything else.

At 5,000 simultaneous bouncing bullets, the serial solver costs **174ms** per frame. The parallel solver costs **5ms**. That's not a rounding error, that's a 32x difference. On a game with a 16ms frame budget, the serial solver stops being viable well before that point. The parallel solver barely notices.

These aren't cherry-picked. The data below is the raw output of Vetra's own benchmarker, captured on a live Roblox server with 64 shards, 120 frames sampled per cell.

---

## The Setup

Three behavior profiles, tested across 13 bullet counts each. Every cell is 120 Heartbeat frames sampled after a 30-frame warmup, with a keep-alive callback that immediately respawns any terminated bullet so the active count stays stable throughout.

- **Travel-only**, bullets fly straight with no callbacks, no bounce resolution. Pure raycast throughput.
- **Bounce (no callback)**, bullets bounce up to 8 times with no `CanBounceFunction`. The bounce logic runs but no Lua callback crosses the thread boundary.
- **Bounce (callback)**, identical, but with a `CanBounceFunction` that returns `true`. Callbacks must flush on the main thread after each parallel pass, so this measures the real cost of user-facing code.
- **Pierce (callback)**, bullets pierce up to 5 times with a `CanPierceFunction`. Same callback flush model as bounce.

Frame time is wall-clock Heartbeat duration. Throughput is average active casts x (1000 / avg ms). Treat everything as relative, not absolute, Roblox's server scheduler adds its own noise floor.

---

## Travel-Only

No callbacks. No bounce resolution. Just bullets moving through space, each firing one raycast per frame. This is the theoretical ceiling of what parallel can do, all work is embarrassingly parallel, nothing needs to touch the main thread.

| Bullets | Serial avg | Parallel avg | Ratio | Parallel throughput |
|--------:|:----------:|:------------:|:-----:|--------------------:|
| 10 | 4.767 ms | 4.334 ms | 0.91x | 2,307 steps/s |
| 25 | 6.874 ms | 4.317 ms | 0.63x | 5,791 steps/s |
| 50 | 10.345 ms | 4.157 ms | **0.40x** | 12,028 steps/s |
| 100 | 10.187 ms | 4.169 ms | 0.41x | 23,988 steps/s |
| 200 | 14.041 ms | 4.159 ms | **0.30x** | 48,086 steps/s |
| 500 | 25.885 ms | 4.159 ms | 0.16x | 120,215 steps/s |
| 1,000 | 45.2 ms | 4.168 ms | **0.09x** | 239,899 steps/s |
| 2,000 | 74.321 ms | 4.206 ms | 0.06x | 475,481 steps/s |
| 5,000 | 174.671 ms | 5.453 ms | **0.03x** | 916,962 steps/s |
| 7,500 |, | 8.581 ms |, | 874,040 steps/s |
| 10,000 |, | 6.617 ms |, | 1,511,333 steps/s |
| 15,000 |, | 7.888 ms |, | 1,901,513 steps/s |
| 20,000 |, | 10.286 ms |, | 1,944,472 steps/s |

The parallel solver's frame time is essentially **flat from 25 to 2,000 bullets**, hovering between 4.1 and 4.3ms. That's the signature of work being distributed across enough cores that adding more bullets just fills unused capacity. The step from 5,000 to 20,000 bullets costs only 5ms more. At 20,000 active bullets, the parallel solver is still well within a 60fps frame budget.

The serial solver has no such ceiling. At 1,000 bullets it's already at 45ms, nearly 3x over budget. At 5,000 it's at 174ms. That's 10 frames of latency from one game system.

---

## Bounce (No Callback)

When bullets bounce, each frame involves more work per cast: velocity reflection math, restitution, normal perturbation, corner-trap detection. But because there's no `CanBounceFunction`, none of that has to flush through the main thread. It all runs in parallel.

| Bullets | Serial avg | Parallel avg | Ratio | Parallel throughput |
|--------:|:----------:|:------------:|:-----:|--------------------:|
| 10 | 4.159 ms | 4.365 ms | 1.05x | 2,291 steps/s |
| 25 | 4.168 ms | 4.165 ms | 1.00x | 6,003 steps/s |
| 50 | 4.364 ms | 4.334 ms | 0.99x | 11,536 steps/s |
| 100 | 4.159 ms | 4.270 ms | 1.03x | 23,421 steps/s |
| 200 | 4.714 ms | 4.386 ms | **0.93x** | 45,596 steps/s |
| 500 | 7.432 ms | 4.198 ms | **0.57x** | 119,095 steps/s |
| 1,000 | 8.389 ms | 4.298 ms | 0.51x | 232,646 steps/s |
| 2,000 | 13.844 ms | 4.334 ms | **0.31x** | 461,467 steps/s |
| 5,000 | 24.159 ms | 4.327 ms | 0.18x | 1,155,485 steps/s |
| 7,500 |, | 4.629 ms |, | 1,620,096 steps/s |
| 10,000 |, | 5.265 ms |, | 1,899,199 steps/s |
| 15,000 |, | 7.574 ms |, | 1,980,502 steps/s |
| 20,000 |, | 9.390 ms |, | 2,129,909 steps/s |

Two things to notice. First: at low counts (10–100 bullets), serial and parallel are essentially tied, the overhead of Actor messaging costs as much as the work being parallelised. This is the crossover zone the docs warn about, and the data shows it clearly.

Second: at 500+ bullets, parallel breaks away hard. The serial solver hits a wall around 1,000 bullets at ~8ms and climbs to 24ms at 5,000. The parallel solver stays under 4.5ms across all of it. Even at 20,000 bouncing bullets, 9.39ms. That's real.

---

## Bounce (Callback) and Pierce (Callback)

Adding a `CanBounceFunction` or `CanPierceFunction` means the parallel solver has to flush callback results through the main thread after each physics pass. This is the realistic profile for any production weapon, you're always going to want some gate logic.

**Bounce (callback):**

| Bullets | Serial avg | Parallel avg | Ratio |
|--------:|:----------:|:------------:|:-----:|
| 10–100 | ~4.2 ms | ~4.2 ms | ≈1.00x |
| 200 | 4.391 ms | 4.149 ms | 0.95x |
| 500 | 6.084 ms | 4.176 ms | **0.69x** |
| 1,000 | 8.454 ms | 4.161 ms | 0.49x |
| 2,000 | 12.142 ms | 4.260 ms | **0.35x** |
| 5,000 | 23.262 ms | 4.164 ms | 0.18x |
| 20,000 |, | 10.283 ms |, |

**Pierce (callback):**

| Bullets | Serial avg | Parallel avg | Ratio |
|--------:|:----------:|:------------:|:-----:|
| 10–100 | ~4.2 ms | ~4.2 ms | ≈1.00x |
| 200 | 4.639 ms | 4.160 ms | **0.90x** |
| 500 | 6.866 ms | 4.275 ms | 0.62x |
| 1,000 | 8.285 ms | 4.167 ms | **0.50x** |
| 2,000 | 11.872 ms | 4.165 ms | 0.35x |
| 5,000 | 25.069 ms | 4.204 ms | 0.17x |
| 20,000 |, | 9.900 ms |, |

The callback flush cost is nearly invisible in the data. Bounce-with-callback vs bounce-without-callback is indistinguishable at every bullet count. The parallel solver handles the main-thread sync without meaningful overhead because it's a deferred batch flush, not a per-cast round-trip.

---

## What These Numbers Mean in Practice

A typical Roblox shooter might have 10–30 simultaneously live bullets at any moment. The serial solver is completely fine there. You'd use `Vetra.new()`, ship it, and never think about this page.

A bullet-hell game, a large-scale military simulation, an artillery mode, a scenario where shotguns fire 12 pellets simultaneously and 20 players are all shooting, those are different conversations. At 200+ bullets, the parallel solver is measurably faster and the margin widens every step of the way.

The honest version of the guidance in the API docs: use `Vetra.new()` until you feel the serial solver's cost in your profiler. Then switch to `newParallel` and these numbers tell you exactly what to expect.

---

## Running the Benchmarker Yourself

The benchmarker that produced these results is included with Vetra. It's a self-contained ModuleScript you drop into your project and run once. Results print to the Output window in the same format as above.

### Setup

1. Place the `VetraBenchmark` ModuleScript somewhere accessible, `ServerScriptService` works fine.
2. Add an `ObjectValue` named `VetraReference` as a child of the script, with its `Value` pointing at the `Vetra` ModuleScript.
3. Require it from a `Script` and call `:Run()` inside a `task.spawn`:

```lua
local VetraBenchmark = require(script.Parent.VetraBenchmark)

task.spawn(function()
    local Bench = VetraBenchmark.new()
    Bench:Run()
end)
```

### Configuration

`VetraBenchmark.new()` accepts an optional config table:

```lua
local Bench = VetraBenchmark.new({
    BulletCounts          = { 10, 50, 100, 500, 1000 }, -- which counts to test
    SampleFrames          = 120,    -- Heartbeat frames sampled per cell
    WarmupFrames          = 30,     -- frames to discard before sampling
    ShardCount            = 8,      -- Actor shards for the parallel solver
    ParallelOnlyThreshold = 500,    -- skip serial above this count
    Origin                = Vector3.new(0, 50, 0),  -- fire origin
    SpreadDeg             = 25,     -- cone spread in degrees
})
```

All fields are optional, unset fields fall back to defaults. The default `BulletCounts` runs the full 13-step sweep from 10 to 20,000 and takes roughly 3–4 minutes.

For a quick sanity check, run a narrow sweep:

```lua
local Bench = VetraBenchmark.new({
    BulletCounts          = { 50, 200, 500 },
    SampleFrames          = 60,
    ParallelOnlyThreshold = 9999, -- never skip serial
})
Bench:Run()
```

### Custom Profiles

Pass a second argument to replace the default four profiles with your own:

```lua
local Bench = VetraBenchmark.new(nil, {
    {
        name = "Sniper with drag",
        behavior = {
            MaxDistance     = 1500,
            DragCoefficient = 0.003,
            DragModel       = "G7",
            MaxPierceCount  = 3,
            CanPierceFunction = function(ctx, result, vel)
                return true
            end,
        },
    },
    {
        name = "Grenade",
        behavior = {
            MaxDistance   = 400,
            MaxBounces    = 6,
            Restitution   = 0.55,
            CanBounceFunction = function(ctx, result, vel)
                return true
            end,
        },
    },
})
Bench:Run()
```

Each profile runs the full bullet-count sweep independently. If you care specifically about how a particular weapon's physics cost scales, define it here and the benchmarker will tell you exactly when the serial solver starts hurting.

### Reading the Output

The benchmarker prints a live row as each cell finishes, so you can watch it progress:

```
serial       | Travel-only              |   500 bullets | avg 25.885 ms  min 23.099  max 41.11  σ 2.614 | 19316 cast-steps/s
parallel     | Travel-only              |   500 bullets | avg 4.159 ms   min 2.19   max 5.828  σ 0.765 | 120215 cast-steps/s
  → parallel/serial ratio: 0.161x  [PARALLEL FASTER]
```

The `σ` column is standard deviation. High σ means the frame time was inconsistent, often a sign of garbage collection pressure or Roblox scheduler interference during that sample window. If a cell's σ is unusually large relative to its average, treat that row with more skepticism and re-run.

After all profiles complete, a summary table is printed with all results side-by-side for easy comparison.

:::caution One run per instance
`Bench:Run()` asserts if called more than once on the same instance. Create a new instance for each run.
:::
