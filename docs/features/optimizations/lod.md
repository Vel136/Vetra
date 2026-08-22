---
sidebar_position: 1
title: Level of Detail
---

# Level of Detail (LOD)

A bullet 600 studs from every player is invisible and doesn't affect anything players can see,
simulating it at the same frequency as one that just left the barrel is wasted work. LOD steps
distant bullets **less often**, then catches them up analytically so nothing visibly skips.

---

## How It Works

`LODDistance` is a per-behavior distance in **studs**. Each frame, the solver compares the bullet's
distance from the current **LOD origin** to `LODDistance`:

- **Within** `LODDistance` -> the bullet steps every frame (full fidelity).
- **Beyond** `LODDistance` -> the bullet enters LOD and steps at reduced frequency.

**How many frames does it skip?** That's `LODInterval`: a bullet in LOD steps **1 frame in N**,
skipping `N - 1`. It defaults to `3` (step every 3rd frame, skip 2 of every 3), and is set per
behavior with `:LOD():Interval(n)`. `LODInterval = 1` means "never throttle", the bullet keeps
stepping every frame even while beyond `LODDistance`.

So the two settings split the decision: `LODDistance` controls *when* a bullet enters LOD, and
`LODInterval` controls *how aggressively* it's throttled once it does.

A down-stepped bullet isn't losing information about *where* it is: the solver accumulates the
skipped time deltas and, when it does step, advances the bullet for the full elapsed interval at
once. It lands where it would have, it just computed fewer intermediate points along the way. From a
player's view nothing changes; they don't see a distant bullet stutter.

What it does lose is **collision resolution**, and that has a visible consequence worth understanding
before you turn LOD on.

`LODDistance = 0` (the default) disables LOD for that behavior.

:::caution Travel events keep firing on skipped frames, hits don't
On a skipped frame the solver still fires `OnTravel`, at a position computed **analytically** from
the banked time. No raycast runs on those frames. So travel events report the bullet moving through
space it was never collision-tested against.

The hit is only found later, on the catch-up step, which raycasts the entire banked span at once. The
result is that a hit can be reported at a position the bullet already appeared to fly **past**, up to
`LODInterval - 1` frames ago:

```text
frame 1  OnTravel  (0, 0, 100)   <- analytic, no raycast
frame 2  OnTravel  (0, 0, 200)   <- analytic, no raycast   (a wall is at z=150)
frame 3  step      raycast 0 -> 300, hit at z=150
         OnHit     (0, 0, 150)   <- "behind" the last OnTravel
```

Nothing is wrong with the *hit*, the catch-up raycast covers the whole span, so the wall is found and
the contact point is exact. What's misleading is `OnTravel`: it optimistically reports positions the
bullet may never legitimately reach.

This matters if you drive anything off travel positions, tracers, VFX, or your own hit logic. A
tracer will visibly overshoot the wall by up to `LODInterval - 1` frames and then the hit lands
behind it. Keep `LODDistance` far enough out that this happens where players can't see it, that's
what the setting is for, and treat `OnHit` as authoritative over `OnTravel`.

The same applies to [spatial partitioning](./spatial) throttling, with its tier rate in place of
`LODInterval`.
:::

:::note LOD suspends high-fidelity sub-segments
While a bullet is in LOD, [high-fidelity](../simulation/tunnelling) sub-segment raycasting
is skipped, a distant, down-stepped bullet doesn't pay for thin-wall precision it doesn't need. It
resumes automatically when the bullet comes back into range.
:::

---

## Setting It Up

```lua
-- Enable LOD on a behavior: beyond 300 studs from the LOD origin, step 1 frame in 5
local Behavior = Vetra.BehaviorBuilder.new()
    :Physics():MaxDistance(800):Done()
    :LOD():Distance(300):Interval(5):Done()
    :Build()

-- Tell the solver where the "important" point is, every frame
game:GetService("RunService").RenderStepped:Connect(function()
    Solver:SetLODOrigin(workspace.CurrentCamera.CFrame.Position)
end)
```

| Setter / Method | Field | Default | Description |
|-----------------|-------|--------:|-------------|
| `:LOD():Distance(n)` | `LODDistance` | `0` (off) | Studs from the LOD origin beyond which the bullet down-steps. |
| `:LOD():Interval(n)` | `LODInterval` | `3` | Step 1 frame in `n` once beyond `Distance`. Must be `>= 1`; `1` disables throttling. Floored to an integer. |
| `Solver:SetLODOrigin(v)` |, | `nil` | The reference point LOD distance is measured from. |

:::note LOD needs an origin
`LODDistance` only takes effect when an LOD origin is set. With no origin, every bullet is treated as
in-range and steps at full frequency. On the **client**, update it with the camera position; on the
**server**, use a central point of interest (or use [spatial partitioning](./spatial), which handles
many interest points at once).
:::

---

## Client vs Server

- **Client**, one viewpoint that matters: the camera. `SetLODOrigin(camera position)` each
  `RenderStepped` is exactly right.
- **Server**, there's no single camera. LOD's single origin is less useful here; reach for
  [spatial partitioning](./spatial), which classifies bullets against *many* interest points
  (every player) instead of one.

Together, LOD and spatial partitioning let a server spend almost its entire simulation budget on the
bullets actually near players, while distant bullets cost almost nothing.
