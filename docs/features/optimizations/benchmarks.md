---
sidebar_position: 6
title: Benchmarks
---

# Benchmarks

Real measured numbers, not estimates. Use them to decide which solver and which features to enable,
then measure your own scene, because the answer genuinely depends on what you turn on.

:::note Test conditions
Measured with the Roblox **MicroProfiler in Studio**, `ShardCount = 16` for the parallel solver.
Absolute milliseconds vary by device and scene complexity, so read the **ratios**, not the raw
numbers. Your hardware, your geometry, and your feature mix will move these.
:::

**How to read the columns:**

- **ser/base**, **par/base**: speed relative to that solver's own baseline. Above `1.00x` means the
  config is *faster* than baseline (an optimization); below `1.00x` means it costs more (a feature).
- **par vs ser**: how much faster parallel is than serial for that same config. Below `1.00x` means
  parallel is **slower**.

---

## Optimization Features, 20,000 casts

| Config | serial | parallel | ser/base | par/base | par vs ser |
|--------|-------:|---------:|---------:|---------:|-----------:|
| baseline | 98.86 ms | 47.33 ms | 1.00x | 1.00x | **2.09x** |
| SpatialPartition | 44.29 ms | 35.25 ms | **2.23x** | 1.34x | 1.26x |
| LOD | 76.01 ms | 47.49 ms | 1.30x | 1.00x | 1.60x |
| SpatialPartition + LOD | 45.69 ms | 34.87 ms | 2.16x | 1.36x | 1.31x |
| FireTravel + listener, batch off | 112.37 ms | 62.79 ms | 0.88x | 0.75x | 1.79x |
| FireTravel + listener, batch on | 110.60 ms | 61.87 ms | 0.89x | 0.77x | 1.79x |

**What this says:**

- **Spatial partitioning is the single biggest win on serial**, 2.23x, and it more than halves the
  frame. If you only enable one optimization, make it this one.
- **LOD helps serial (1.30x) but does nothing on parallel** (1.00x, 47.33 -> 47.49 ms is noise). On
  the parallel path the raycasts are already spread across cores, so skipping frames for distant
  bullets reclaims far less.
- **Spatial + LOD is not additive.** Combined (2.16x) is no better than spatial alone (2.23x),
  because [LOD takes precedence](./spatial#relationship-to-lod): a bullet in LOD skips spatial-tier
  classification entirely, so the two overlap rather than stack.
- **Travel events are expensive at volume.** Turning on `FireTravelEvents` with a listener costs
  ~14% on serial and ~25% on parallel versus baseline. Batching recovers only a little (112.37 ->
  110.60 serial). At 20k casts, the cheapest travel event is the one you don't fire.

---

## Physics Features, 5,000 casts

| Config | serial | parallel | ser/base | par/base | par vs ser |
|--------|-------:|---------:|---------:|---------:|-----------:|
| baseline | 26.45 ms | 15.47 ms | 1.00x | 1.00x | 1.71x |
| Coriolis | 26.46 ms | 13.07 ms | 1.00x | 1.18x | **2.02x** |
| Wind | 26.50 ms | 14.35 ms | 1.00x | 1.08x | 1.85x |
| Drag | 30.62 ms | 15.92 ms | 0.86x | 0.97x | 1.92x |
| Magnus | 30.96 ms | 17.83 ms | 0.85x | 0.87x | 1.74x |
| HighFidelity | 35.09 ms | 22.04 ms | 0.75x | 0.70x | 1.59x |
| HighFidelity + SixDOF | 38.68 ms | 22.91 ms | 0.68x | 0.68x | 1.69x |
| Homing | 40.13 ms | 41.19 ms | 0.66x | 0.38x | **0.97x** |
| SixDOF | 89.73 ms | 37.18 ms | 0.29x | 0.42x | **2.41x** |
| SixDOF + Tumble | 89.36 ms | 39.97 ms | 0.30x | 0.39x | 2.24x |
| ALL PHYSICS | 109.22 ms | 66.11 ms | 0.24x | 0.23x | 1.65x |

**What this says:**

- **Coriolis and Wind are free.** Both sit at `1.00x` on serial, they're a couple of vector ops
  folded into the existing acceleration. Enable them without thinking about cost.
- **Drag and Magnus cost ~15%.** Reasonable for what they add. They're recalculated on the
  `DragSegmentInterval` cadence, not per frame, which is why they're this cheap.
- **6DOF is by far the most expensive feature**, 3.4x the baseline cost on serial (26.45 ->
  89.73 ms). It's also where **parallel pays off most** (2.41x). If you need 6DOF at volume, use
  `Vetra.newParallel()`.
- **Homing is the one case where parallel doesn't help** (0.97x, parallel is marginally *slower*).
  This is expected: a `HomingPositionProvider` forces the bullet onto the
  [sync path](./parallel#sync-vs-fire-and-forget), so the provider runs on the main thread every
  frame and you pay coordination overhead without gaining parallelism.
- **Tumble is free once 6DOF is on** (89.73 -> 89.36 ms, i.e. noise). It's riding physics that's
  already being computed.

---

## Picking a Solver

Parallel wins in almost every configuration measured here, between **1.6x and 2.4x**, with two
exceptions worth knowing:

| Situation | Use |
|-----------|-----|
| Heavy physics (6DOF especially) at volume | **Parallel**, biggest gap (2.41x) |
| Large bullet counts, plain travel | **Parallel** (2.09x at 20k) |
| Homing / provider-driven bullets | **Either**, parallel gives no benefit (0.97x) |
| `CastFunction` required | **Serial**, [not supported in parallel](./parallel#the-castfunction-limitation) |
| Same-frame hit reaction needed | **Serial**, parallel is [one frame late](./parallel#events-arrive-one-frame-late) |
| Small counts (tens of bullets) | **Serial**, coordination overhead isn't paid back |

:::caution These are Studio numbers
Studio is not a live server. Treat the ratios as directional and benchmark your own scene before
committing to an architecture, especially near the serial/parallel crossover.
:::
