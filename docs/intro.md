---
sidebar_position: 1
---

# Where to Go From Here

Vetra has a lot of surface area. This page is a map.

---

## "I just want to fire bullets."

Start at [Getting Started](./intro). You need three things: a solver, a behavior, and a context. The
intro page covers all of them in order and gets you to a working gun in under 20 lines.

---

## "My bullets are tunnelling through walls."

That's not a bug in your code, it's a mathematical property of how most projectile systems work.
[Why Your Bullets Miss](./guides/why-bullets-miss) explains exactly what's happening and how Vetra's
analytic trajectory and high-fidelity sub-segment raycasting solve it.

---

## "I want drag, spin drift, or realistic ballistics."

[Making Bullets Feel Real](./guides/physics-features) goes through every physics feature, drag
models, Magnus effect, gyroscopic drift, tumble, fragmentation, Coriolis, with practical guidance
on when each one is worth using and what values to start with.

The quick reference for every field lives in [TypeDefinitions](../api/TypeDefinitions) under
`VetraBehavior`.

---

## "I want full 6DOF aerodynamics, lift, pitching moment, gyroscopic precession."

Enable [SixDOFBuilder](../api/SixDOFBuilder) via `:SixDOF():Enabled(true)`. At minimum you need
`BulletMass`, `ReferenceArea`, `ReferenceLength`, and `MomentOfInertia` set. Everything else
defaults to physically neutral values you can layer on incrementally.

The 6DOF FAQ in the [FAQ](./faq#6dof-physics) covers common setup mistakes, unit questions, and
tuning guidance. The field reference is in [SixDOFBuilder](../api/SixDOFBuilder).

---

## "I need multiplayer, server authority, cosmetics, hit validation."

[Networking and Trust](./guides/networking) explains the architecture: why trusting the client is
dangerous, how VetraNet's trajectory reconstruction works, and what each rejection reason means.

The API reference for setup and signals is [VetraNet](../api/VetraNet) and
[BehaviorRegistry](../api/BehaviorRegistry).

---

## "I need to handle hundreds or thousands of bullets."

[Performance](./guides/performance) covers LOD, spatial partitioning, `OnTravelBatch` vs
`OnTravel`, and when the parallel solver is actually worth using.

The [Benchmarks](./guides/benchmarks) page has the raw numbers, serial vs parallel across four
profiles and 13 bullet counts, and instructions for running the benchmarker against your own
weapon behaviors.

---

## "I need to customise physics mid-flight."

[VetraCast](../api/VetraCast), the object returned by `Solver:Fire()`, exposes `SetVelocity`,
`SetAcceleration`, `SetPosition`, `Pause`, `Resume`, and state reset methods. Use these from signal
handlers to override physics on a live bullet.

For mutating a bounce or pierce *as it resolves* (before the math finalises), see the hook signals
`OnPreBounce`, `OnMidBounce`, `OnPrePenetration`, and `OnMidPenetration` in the
[Vetra signals table](../api/Vetra#GetSignals).

---

## "I want to build behaviors with typed setters and validation."

[BehaviorBuilder](../api/BehaviorBuilder) is the fluent builder, chain `:Physics()`, `:Bounce()`,
`:Pierce()`, `:Drag()`, `:Magnus()`, `:Homing()`, and so on, then call `:Build()` to get a
validated frozen table. Every `VetraBehavior` field is covered by a typed setter.

The individual sub-builders are documented in [SubBuilders](../api/PhysicsBuilder):
[PhysicsBuilder](../api/PhysicsBuilder),
[HomingBuilder](../api/HomingBuilder),
[PierceBuilder](../api/PierceBuilder),
[BounceBuilder](../api/BounceBuilder),
[HighFidelityBuilder](../api/HighFidelityBuilder),
[CornerTrapBuilder](../api/CornerTrapBuilder),
[CosmeticBuilder](../api/CosmeticBuilder),
[DebugBuilder](../api/DebugBuilder),
[DragBuilder](../api/DragBuilder),
[WindBuilder](../api/WindBuilder),
[MagnusBuilder](../api/MagnusBuilder),
[GyroDriftBuilder](../api/GyroDriftBuilder),
[TumbleBuilder](../api/TumbleBuilder),
[FragmentationBuilder](../api/FragmentationBuilder),
[SpeedProfilesBuilder](../api/SpeedProfilesBuilder),
[SixDOFBuilder](../api/SixDOFBuilder),
[TrajectoryBuilder](../api/TrajectoryBuilder),
[LODBuilder](../api/LODBuilder).

:::tip DragModel enum
Use `BehaviorBuilder.DragModel.G7` instead of the raw string `"G7"`. Typos on raw
strings pass the type checker silently and only fail at `:Build()`. `BehaviorBuilder.DragModel`
is a direct re-export of `Vetra.Enums.DragModel`, they are the same table.
:::

## "I need to compare against a termination reason or drag model."

[Enums](../api/Enums) documents every named constant table exposed on `Vetra.Enums`.
Use `Vetra.Enums.TerminateReason.Hit` instead of the raw string `"hit"` in
`OnPreTermination` handlers, if a value is ever renamed, every reference site
produces a nil rather than silently passing the wrong value.

```lua
Signals.OnPreTermination:Connect(function(context, reason, mutate)
    if reason == Vetra.Enums.TerminateReason.Hit then
        mutate(true, nil)  -- cancel termination
    end
end)
```

---

## "I need to track a live bullet's state."

[BulletContext](../api/BulletContext) is the object you create before firing and receive in every
signal handler. It exposes position, velocity, path length, lifetime, and `UserData`.

---

## Quick Reference

| I want to… | Go to |
|------------|-------|
| Fire a bullet | [Getting Started](./intro) |
| Understand why bullets tunnel | [Why Your Bullets Miss](./guides/why-bullets-miss) |
| Add drag, spin, tumble, Coriolis | [Making Bullets Feel Real](./guides/physics-features) |
| Set up multiplayer hit validation | [Networking and Trust](./guides/networking) |
| Scale to hundreds of bullets | [Performance](./guides/performance) |
| See benchmark numbers | [Benchmarks](./guides/benchmarks) |
| Look up every behavior field | [TypeDefinitions](../api/TypeDefinitions) |
| Configure the solver | [Vetra](../api/Vetra) |
| Read or modify a live bullet | [VetraCast](../api/VetraCast) |
| Access bullet state in signals | [BulletContext](../api/BulletContext) |
| Build behaviors with typed setters | [BehaviorBuilder](../api/BehaviorBuilder) |
| Configure 6DOF aerodynamics | [SixDOFBuilder](../api/SixDOFBuilder) |
| Look up enum values | [Enums](../api/Enums) |
| Set up VetraNet networking | [VetraNet](../api/VetraNet) |