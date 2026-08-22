---
sidebar_position: 2
title: Spatial Partitioning
---

# Spatial Partitioning

[LOD](./lod) is binary, a bullet is either in range of one origin or out. Spatial partitioning
generalises that to **many interest points and any number of rings**, so on a server with players
spread across a map, each bullet's step frequency is set by how close it is to *any* player.

---

## Rings and Rates

The solver overlays a uniform grid on the world and classifies each cell by its distance (in **cells**)
from the nearest interest point. Each ring you configure has two numbers:

- **`Radius`**, how far the ring reaches, in **cells**.
- **`Rate`**, the step cadence for cells in that ring, "step 1 frame in `Rate`".

The rate *is* the stride: `1` steps every frame, `2` every 2nd, `4` every 4th. As with LOD,
down-stepped bullets accumulate their skipped deltas and catch up analytically, no visible skipping.

The default configuration is two rings plus a fallback, which is where the HOT / WARM / COLD names
come from:

| Name | Rate | Cells from an interest point | Step cadence |
|------|:----:|------------------------------|--------------|
| **HOT** | `1` | within `HotRadius` cells | every frame |
| **WARM** | `2` | within `WarmRadius` cells | every 2nd frame |
| **COLD** | `4` | beyond `WarmRadius` (if `FallbackRate` = `4`) | every 4th frame |

Those are just conventional numbers, not a fixed set, any rate `>= 1` is valid. Rings are shells, not
discs: each ring owns the band between the previous ring's radius and its own, so they never overlap.
Where two interest points' rings overlap, the **lower rate wins**, a cell that is cold for one player
and hot for another steps every frame.

:::caution Radii are in **cells**, not studs
`HotRadius` and `WarmRadius` count grid cells, each `CellSize` studs wide. At the default
`CellSize = 50` and `HotRadius = 1`, "HOT" means within **+/-1 cell ~= +/-50 studs** of an interest
point, not 1 stud. Multiply by `CellSize` to reason in studs.
:::

---

## Configuring the Partition

Pass a `SpatialPartition` table when constructing the solver. Two rings is all most games need, so
the simple shape is still the right thing to write:

```lua
local Solver = Vetra.new({
    SpatialPartition = {
        Enabled        = true,
        CellSize       = 50,   -- studs per grid cell
        HotRadius      = 1,    -- rate 1 within +/-1 cell  (+/-50 studs)
        WarmRadius     = 3,    -- rate 2 within +/-3 cells (+/-150 studs)
        UpdateInterval = 3,    -- rebuild + reclassify every 3 frames
        FallbackRate   = 4,    -- cells with no nearby interest point (see note below)
    },
})
```

| Key | Default | Description |
|-----|--------:|-------------|
| `Enabled` | `true` | Master switch (any non-`false` value enables it). |
| `CellSize` | `50` | Grid cell width in studs. |
| `HotRadius` | `1` | Inner ring radius in **cells**, at rate `1`. |
| `WarmRadius` | `3` | Outer ring radius in **cells**, at rate `2`. Clamped up to `HotRadius` if smaller. |
| `UpdateInterval` | `3` | Frames between grid rebuilds / reclassification. |
| `FallbackRate` | `1` (every frame) | Rate for cells outside every ring. Set to `4` to make distant bullets cheap. Also accepted as `FallbackTier`. |
| `Tiers` | `nil` | Explicit ring list, replaces `HotRadius`/`WarmRadius`. See below. |

### Custom rings

For more than two bands, pass `Tiers` as an array of `{ Radius, Rate }`. It replaces the
`HotRadius`/`WarmRadius` pair entirely:

```lua
SpatialPartition = {
    CellSize     = 50,
    Tiers        = {
        { Radius = 1, Rate = 1 },   -- every frame within +/-50 studs
        { Radius = 3, Rate = 2 },   -- every 2nd frame out to +/-150
        { Radius = 6, Rate = 4 },   -- every 4th frame out to +/-300
        { Radius = 12, Rate = 8 },  -- every 8th frame out to +/-600
    },
    FallbackRate = 16,              -- everything beyond
}
```

Rings are sorted by radius internally, so declaration order doesn't matter. `Rate` is floored and
clamped to a minimum of `1` (a rate of `0` would freeze the bullet rather than throttle it), and
`Radius` must be `>= 0`. Malformed entries are skipped with a warning rather than erroring; if every
entry is invalid, the config falls back to the default two rings. Rates should rise as radius grows,
an outer ring stepping more often than an inner one logs a warning and is ignored by the min-wins
merge anyway.

:::caution `FallbackRate` is a number, not a string
It must be a **number**, `1` for every frame, `4` for every 4th, **not** the string `"COLD"`. Passing
a non-number logs a warning and defaults to `1`, which means distant bullets are *not* down-stepped
and the whole optimization is silently undone. Pass the literal `4` for COLD.
:::

---

## Feeding Interest Points

The partition classifies cells against the interest points you provide, the positions you care
about, usually every player. Update them each `Heartbeat`:

```lua
local Players = game:GetService("Players")

game:GetService("RunService").Heartbeat:Connect(function()
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

`SetInterestPoints` expects a table of `Vector3`. The grid itself only rebuilds every
`UpdateInterval` frames, so calling this every frame is cheap, you're just updating the source
positions, not forcing a reclassification.

---

## The Big Win: `FallbackRate = 4`

The single most impactful setting for a server under load is `FallbackRate`. Left at its default
(`1`), every cell with no nearby interest point still steps every frame, the partition does work
but saves nothing. Set it to `4` and any bullet not near a player steps at a quarter rate.

On a large map with spread-out players and many simultaneous bullets, that alone can dramatically cut
simulation cost, because most bullets at any instant are nowhere near anyone.

---

## Relationship to LOD

LOD and spatial partitioning are complementary and can run together:

- **LOD** is the simplest tool, one origin, in-or-out. Ideal on the **client** (the camera).
- **Spatial partitioning** handles **many** interest points with graded tiers. Ideal on the
  **server** (all players at once).

The two are evaluated in a fixed order: **LOD takes precedence.** When a bullet is in LOD, the solver
skips spatial-tier classification entirely and uses LOD's own cadence (`LODInterval`, every 3rd frame
by default). Spatial tiering only applies to bullets that are *not* currently in LOD, so the two never
fight, and a bullet is never down-stepped by both systems at once.
