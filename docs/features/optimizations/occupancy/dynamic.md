---
sidebar_position: 2
title: Dynamic Occupancy
---

# Dynamic Occupancy

[Static occupancy](./static) bakes the unmoving world once. But some of the geometry bullets care
about *moves*, doors, elevators, vehicles, rotating hazards, players' shields. Re-baking a static
grid every frame would be far too expensive.

**Dynamic** occupancy solves this differently. It bakes each moving part **once** into a compact
local-space voxel shape, then each frame it just refreshes that part's **transform**, cheaply
re-projecting the same baked shape into its new position and orientation. Rigid parts that only
translate and rotate never need re-baking.

Like static occupancy, its job is to let the solver skip raycasts for segments it can prove are
empty, but for the moving parts of your scene.

---

## Registering Moving Parts

Create a dynamic set, then register each moving part you want bullets to test against. Registration
bakes the part's shape once in local space and returns an id.

```lua
local Vetra = require(ReplicatedStorage.Vetra)

local dyn = Vetra.DynamicOccupancy.new(4)   -- voxel size (default 4)

local doorId     = dyn:Register(workspace.BlastDoor)
local elevatorId = dyn:Register(workspace.Elevator)
```

`Register(part, nonUniform?)` returns the id, or `nil` if the part is too small to produce a usable
voxel shape (below the minimum voxel count). Keep the id if you'll want to remove the part later.

| Method | Signature | Description |
|--------|-----------|-------------|
| `DynamicOccupancy.new(voxelSize?)` | `(number?)` | Create a set. Voxel size defaults to `4`. |
| `dyn:Register(part, nonUniform?)` | `(BasePart, boolean?) -> number?` | Bake a part's local shape once; returns its id (or `nil` if too small). |
| `dyn:Unregister(id)` | `(number)` | Stop tracking a part. |
| `dyn:UpdateTransforms()` | `()` | Refresh every registered part's transform. Call once per frame. |
| `dyn:Destroy()` | `()` | Tear the set down. |

---

## Updating Each Frame

The whole point of dynamic occupancy is that the parts move, so you must refresh their transforms
each frame. This is the cheap operation, it re-reads each part's `CFrame` and `Size`, not its
geometry.

```lua
game:GetService("RunService").Heartbeat:Connect(function()
    dyn:UpdateTransforms()
end)
```

`UpdateTransforms` also self-heals: if a registered part has been destroyed or unparented, it's
dropped from the active set automatically.

:::caution Rigid motion only
The baked shape is fixed at registration. Translating and rotating a part is free (just a transform
update), but **resizing or deforming** it invalidates the baked shape, the grid keeps testing
against the original dimensions, so bullets collide with the shape the part *used to be*. For parts
that change shape, unregister and re-register whenever the shape changes.
:::

:::danger An unregistered moving part won't be hit
As with [static occupancy](./static#the-idea), a grid is a **filter**: a segment proved clear is
never raycast, so bullets can't hit what the grids don't know about. Registering a moving part is
what makes bullets collide with it.

The one nuance is that the two grids compose, a segment is skipped only when clear of **both**. So a
moving part that overlaps space your static bake already marked occupied still gets a real raycast,
and still gets hit. But a part moving through open air, the usual case, is invisible to bullets until
you register it.
:::

---

## Attaching It to a Behavior

As with static, a dynamic set does nothing until a behavior references it:

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics():MaxDistance(1000):Done()
    :StaticOccupancy(worldGrid)   -- the unmoving map
    :DynamicOccupancy(dyn)        -- the moving parts
    :Build()
```

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:DynamicOccupancy(set)` | `DynamicOccupancy` | `nil` | The dynamic set to test segments against. `nil` disables it. |

A bullet's frame segment is skipped only when it's clear of **both** grids: the static world *and*
every registered dynamic part. If either grid reports the segment might be occupied, the real raycast
runs. So static and dynamic occupancy compose naturally, the static grid handles the map, the
dynamic set handles what moves through it.

---

## How It Differs From Static

| | Static | Dynamic |
|---|--------|---------|
| **Geometry** | Unmoving world (map, terrain) | Moving rigid parts |
| **Bake** | Whole region, once | Each part, once at registration |
| **Per-frame cost** | None (grid is fixed) | `UpdateTransforms()`, a transform refresh per part |
| **Handles motion** | No | Yes (translation + rotation) |
| **Handles resize/deform** | N/A | No, re-register the part |

---

## Direct Queries

Both grids also expose their segment tests directly, which is occasionally useful outside the solver
, for a custom line-of-sight check, an AI's fire-clearance test, or your own cast wrapper:

- `SegmentClear(origin, displacement) -> boolean`, is the segment provably empty?
- `SegmentFirstHit(origin, displacement) -> number`, parametric distance to the first occupied voxel
  along the segment.

`displacement` is the segment's full vector (direction x length), the same convention Vetra's cast
functions use, not a unit direction.

:::note Parallel solver
Dynamic occupancy provides a `Reader` that reconstructs the grids on the worker side from serialized
shape and transform data, so segment tests run inside the parallel workers without crossing Actor
boundaries with live objects. This is wired automatically when you attach a dynamic set to a behavior
fired through `Vetra.newParallel()`.
:::
