---
sidebar_position: 2
title: Fragmentation
---

# Fragmentation

Instead of continuing as a single round, a bullet can **shatter on pierce**, spawning a cone of
child bullets at the pierce point. Each fragment is a fully live cast that inherits the parent's
behavior: it flies, bounces, pierces, and fires `OnHit` on its own.

Fragmentation is triggered by a [pierce](../penetration), so a fragmenting behavior needs a working
pierce filter for anything to happen.

---

## The Setup

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :Pierce()
        :Max(1)
        :Filter(function() return true end)
    :Done()
    :Fragmentation()
        :OnPierce(true)
        :Count(5)         -- five fragments
        :Deviation(20)    -- spread within a 20 deg half-angle cone
    :Done()
    :Build()
```

---

## Fields

| Setter | Field | Default | Description |
|--------|-------|--------:|-------------|
| `:OnPierce(b)` | `FragmentOnPierce` | `false` | Spawn fragments when the bullet pierces. |
| `:Count(n)` | `FragmentCount` | `3` | Number of child bullets spawned per fragmentation event. |
| `:Deviation(n)` | `FragmentDeviation` | `15` | Cone half-angle in degrees. Fragments spread within this cone around the parent's direction. |

---

## Seeding Fragment Data

`OnBranchSpawned` fires once per child, right after it's created and before it's stepped. Use it to
give fragments their own damage, tags, or identity.

```lua
Signals.OnBranchSpawned:Connect(function(parentContext, childContext)
    childContext.UserData.IsFragment = true
    childContext.UserData.Damage = parentContext.UserData.Damage * 0.25
end)
```

**`OnBranchSpawned` parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `parentContext` | `BulletContext` | The bullet that fragmented. |
| `childContext` | `BulletContext` | The freshly-spawned fragment. Mutate its `UserData` here. |

---

## What Fragments Inherit

Each fragment is a full cast running the same behavior the parent was fired with, so if the parent
had drag, tumble, or bounce configured, the fragments do too. If you want fragments to behave
*differently* from the parent, you have two options:

1. **Tune the shared behavior** so its settings suit both the parent's flight and the fragments'
   short, spread-out arcs.
2. **Fire custom casts in `OnBranchSpawned`**, terminate the auto-spawned child and
   `Solver:Fire()` your own with a dedicated fragment behavior for full control.

---

## Combining With Tumble

A classic anti-personnel round pierces, tumbles, *and* fragments, it punches through cover,
destabilises, and sheds fragments on the way through. Pair `:Fragmentation():OnPierce(true)` with
`:Tumble():OnPierce(true)` on the same behavior and both fire on the pierce event. See
[Tumble](../physics/tumble) for the destabilisation model.
