---
sidebar_position: 3
title: Field Reference
---

# Field Reference

Every `VetraBehavior` field, its default, and what it affects, grouped by the sub-builder that sets
it. Use `BehaviorBuilder` setters (shown in the first column) for typed, validated configuration, or
set the raw **Field** on a plain table passed to `Solver:Fire()`. Both produce the same behavior.

:::note Reading the defaults
Defaults are what a field holds when you never touch it. `nil` or `0` usually means the feature is
**off** until you set it. Fields that link to a deeper page have a full explanation there.
:::

---

## Physics, `:Physics()`

Core motion and lifetime. See [Gravity & Drag](./features/physics/gravity-drag) and the
[physics overview](./features/physics/overview#bullet-lifetime).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:MaxDistance(n)` | `MaxDistance` | `500` | Max **path length** in studs before the cast terminates (`Distance`). |
| `:MaxDisplacement(n)` | `MaxDisplacement` | `0` (off) | Max **straight-line** distance from the muzzle before terminating (`Displacement`). |
| `:MinSpeed(n)` | `MinSpeed` | `1` | Speed floor, drop below it and the cast terminates (`Speed`). |
| `:MaxSpeed(n)` | `MaxSpeed` | `inf` | Speed ceiling. |
| `:Gravity(v)` | `Gravity` | `workspace.Gravity` | Gravity vector. Any `Vector3` is used as given, including `Vector3.zero` for no drop. Unset falls back to workspace gravity. |
| `:Acceleration(v)` | `Acceleration` | `Vector3.zero` | Constant extra acceleration added on top of gravity. |
| `:RaycastParams(rp)` | `RaycastParams` | `RaycastParams.new()` | Raycast filter used for hit detection. Applies *within* a raycast that runs, an [occupancy grid](./features/optimizations/occupancy/static#occupancy-vs-raycastparams) decides whether it runs at all. |
| `:CastFunction(fn)` | `CastFunction` | `workspace:Raycast` | Custom cast (Spherecast/Blockcast/etc.). **Ignored by the parallel solver.** |
| `:BulletMass(n)` | `BulletMass` | `0` | Mass (kg). Unused by standard casting; **required (`> 0`) for [6DOF](./features/physics/6dof).** |

---

## Drag, `:Drag()`

Air resistance. See [Gravity & Drag](./features/physics/gravity-drag#drag).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Coefficient(n)` | `DragCoefficient` | `0` (off) | Master drag **scale** (`decel = Coeff*Cd*v^2`), not a ballistic coefficient. |
| `:Model(enum)` | `DragModel` | `Quadratic` | Drag curve: `Quadratic`, `Linear`, `G1`,`G8`, `GL`, `Custom`. |
| `:SegmentInterval(n)` | `DragSegmentInterval` | `0.05` | Seconds between drag/Magnus/gyro recalculations. |
| `:CustomMachTable(t)` | `CustomMachTable` | `nil` | `{ {mach, cd}, ... }` lookup, required when `DragModel = Custom`. |

---

## Speed Profiles, `:SpeedProfiles()`

Different physics above/below thresholds. See [Speed Profiles](./features/physics/speed-profiles).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Thresholds(t)` | `SpeedThresholds` | `{}` | Speeds (studs/s) at which the profile switches and `OnSpeedThresholdCrossed` fires. |
| `:Supersonic()` | `SupersonicProfile` | `nil` | Profile applied while above the highest crossed threshold. |
| `:Subsonic()` | `SubsonicProfile` | `nil` | Profile applied while below it. |

Each profile (`:Supersonic()` / `:Subsonic()`) overrides these fields for its regime, anything
unset falls back to the base behavior:

| Setter | Overrides | Affects |
|--------|-----------|---------|
| `:DragCoefficient(n)` | `DragCoefficient` | Drag scale for this regime. |
| `:DragModel(enum)` | `DragModel` | Drag curve for this regime. |
| `:Restitution(n)` | `Restitution` | Bounce energy retention in this regime. |
| `:MaterialRestitution(t)` | `MaterialRestitution` | Per-material restitution overrides in this regime. |
| `:NormalPerturbation(n)` | `NormalPerturbation` | Bounce scatter in this regime. |

---

## Magnus, `:Magnus()`

Spin-induced curve. See [Magnus & Spin](./features/physics/magnus).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:SpinVector(v)` | `SpinVector` | `Vector3.zero` | Spin axis (direction) x rate (magnitude, rad/s). |
| `:Coefficient(n)` | `MagnusCoefficient` | `0` (off) | Magnus force scale. **Very sensitive**, start ~`0.00005`. |
| `:SpinDecayRate(n)` | `SpinDecayRate` | `0` | Fraction of spin lost per second. |

---

## Gyroscopic Drift, `:GyroDrift()`

Slow directional yaw. See [Magnus & Spin](./features/physics/magnus#gyroscopic-drift).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Rate(n)` | `GyroDriftRate` | `nil` (off) | Lateral drift rate in **1/s**, acceleration per unit speed (`accel = Rate * speed`). |
| `:Axis(v)` | `GyroDriftAxis` | `nil` -> world UP | Drift axis; `nil` models right-hand rifling. |

---

## Tumble, `:Tumble()`

Loss of stability. See [Tumble](./features/physics/tumble).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:SpeedThreshold(n)` | `TumbleSpeedThreshold` | `nil` (off) | Begin tumbling below this speed. |
| `:DragMultiplier(n)` | `TumbleDragMultiplier` | `3.0` | Drag multiplier applied while tumbling. |
| `:LateralStrength(n)` | `TumbleLateralStrength` | `0` | Chaotic lateral acceleration while tumbling, studs/s^2. |
| `:OnPierce(b)` | `TumbleOnPierce` | `false` | Begin tumbling immediately on first pierce. |
| `:RecoverySpeed(n)` | `TumbleRecoverySpeed` | `nil` (permanent) | Re-stabilise if speed climbs back above this. |

---

## Homing, `:Homing()`

Target steering. See [Homing](./features/additions/homing).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:PositionProvider(fn)` | `HomingPositionProvider` | `nil` | Returns the target position each step; `nil` return disengages. |
| `:Strength(n)` | `HomingStrength` | `90` | Max steering rate, degrees/second. |
| `:MaxDuration(n)` | `HomingMaxDuration` | `3` | Seconds before homing auto-disengages. |
| `:AcquisitionRadius(n)` | `HomingAcquisitionRadius` | `0` | Delay engagement until within this many studs; `0` engages at once. |
| `:Filter(fn)` | `CanHomeFunction` | `nil` | Per-step predicate; return `false` to suspend steering this frame. |

---

## Pierce, `:Pierce()`

Passing through surfaces. See [Penetration](./features/penetration).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Filter(fn)` | `CanPierceFunction` | `nil` | Per-hit predicate; without it, nothing pierces. |
| `:Max(n)` | `MaxPierceCount` | `3` | Lifetime pierce budget. |
| `:SpeedThreshold(n)` | `PierceSpeedThreshold` | `50` | Below this speed the bullet can't pierce (hit is terminal). |
| `:SpeedRetention(n)` | `PierceSpeedRetention` | `0.8` | Fraction of speed kept per pierce. |
| `:NormalBias(n)` | `PierceNormalBias` | `1.0` | How much the exit direction bends toward the surface normal. |
| `:PierceDepth(n)` | `PierceDepth` | `0` | Extra forward offset on re-emergence to clear the back face. |
| `:PierceForce(n)` | `PierceForce` | `0` | Speed cost scaled by surface thickness. |
| `:ThicknessLimit(n)` | `PierceThicknessLimit` | `500` | Surfaces thicker than this (studs) stop the bullet. |

---

## Fragmentation, `:Fragmentation()`

Shatter on pierce. See [Fragmentation](./features/additions/fragmentation).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:OnPierce(b)` | `FragmentOnPierce` | `false` | Spawn child bullets when the bullet pierces. |
| `:Count(n)` | `FragmentCount` | `3` | Number of fragments per event. |
| `:Deviation(n)` | `FragmentDeviation` | `15` | Fragment cone half-angle, degrees. |

---

## Bounce, `:Bounce()`

Ricochet off surfaces. See [Bounce](./features/bounce).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Filter(fn)` | `CanBounceFunction` | `nil` | Per-hit predicate; without it, nothing bounces. |
| `:Max(n)` | `MaxBounces` | `5` | Lifetime bounce budget. |
| `:SpeedThreshold(n)` | `BounceSpeedThreshold` | `20` | Below this speed, hits are terminal (filter is skipped). |
| `:Restitution(n)` | `Restitution` | `0.7` | Fraction of speed retained per bounce. |
| `:MaterialRestitution(t)` | `MaterialRestitution` | `{}` | Per-`Enum.Material` restitution overrides. |
| `:NormalPerturbation(n)` | `NormalPerturbation` | `0.0` | Random scatter added to the reflected direction. |
| `:ResetPierceOnBounce(b)` | `ResetPierceOnBounce` | `false` | Clear the pierced-instance list after each bounce. |

---

## Corner Trap, `:CornerTrap()`

Terminates bullets stuck bouncing in a corner. See [Bounce > Corner Traps](./features/bounce#corner-traps).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:TimeThreshold(n)` | `CornerTimeThreshold` | `0.002` | Time window used to detect a stuck oscillation. |
| `:PositionHistorySize(n)` | `CornerPositionHistorySize` | `4` | How many recent positions the detector tracks. |
| `:DisplacementThreshold(n)` | `CornerDisplacementThreshold` | `0.5` | Min net displacement expected; below it looks trapped. |
| `:EMAAlpha(n)` | `CornerEMAAlpha` | `0.4` | Smoothing factor for the progress moving-average. |
| `:EMAThreshold(n)` | `CornerEMAThreshold` | `0.25` | Smoothed-progress level below which the bullet is terminated. |
| `:MinProgressPerBounce(n)` | `CornerMinProgressPerBounce` | `0.3` | Min fraction of progress each bounce must make. |

---

## High Fidelity, `:HighFidelity()`

Sub-segment raycasting that hugs a curving trajectory so it can't chord past geometry the arc
crosses. See [High Fidelity](./features/simulation/high-fidelity) for how to tune these, and
[Tunnelling & Precision](./features/simulation/tunnelling) for the problem they solve.

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:SegmentSize(n)` | `HighFidelitySegmentSize` | `0.5` | Max chord length per sub-ray; smaller hugs the arc tighter. `0` disables HF. |
| `:FrameBudget(n)` | `HighFidelityFrameBudget` | `4` | Max milliseconds/frame spent on sub-segments (adaptive). |
| `:AdaptiveScale(n)` | `AdaptiveScaleFactor` | `1.5` | How aggressively segment size scales to stay near budget. |
| `:MinSegmentSize(n)` | `MinSegmentSize` | `0.1` | Floor the adaptive controller won't shrink below. |
| `:MaxBouncesPerFrame(n)` | `MaxBouncesPerFrame` | `10` | Cap on bounces resolved in a single frame (loop guard). |

---

## 6DOF, `:SixDOF()`

Full attitude aerodynamics. See [6DOF](./features/physics/6dof).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Enabled(b)` | `SixDOFEnabled` | `false` | Master switch for 6DOF. |
| `:LiftCoefficientSlope(n)` | `LiftCoefficientSlope` | `0` (off) | dCL/dalpha, lift per angle of attack. |
| `:PitchingMomentSlope(n)` | `PitchingMomentSlope` | `0` | dCm/dalpha, restoring moment; negative = stabilising. |
| `:PitchDampingCoeff(n)` | `PitchDampingCoeff` | `0` | Damps pitch/yaw wobble; `0` = undamped. |
| `:RollDampingCoeff(n)` | `RollDampingCoeff` | `0` | Decays axial spin over time. |
| `:AoADragFactor(n)` | `AoADragFactor` | `0` | Extra drag at angle of attack: `x(1 + factor*sin^2alpha)`. |
| `:ReferenceArea(n)` | `ReferenceArea` | `0` | Cross-sectional area; **scales all aero forces** (`0` = none). |
| `:ReferenceLength(n)` | `ReferenceLength` | `0` | Moment arm for the pitching moment. |
| `:AirDensity(n)` | `AirDensity` | `1.225` | Air density, kg/m^3 (sea level = 1.225). |
| `:MomentOfInertia(n)` | `MomentOfInertia` | `0` | Transverse (pitch/yaw) rotational inertia. |
| `:SpinMOI(n)` | `SpinMOI` | `0` | Axial (roll) inertia; `> 0` enables gyroscopic precession. |
| `:MaxAngularSpeed(n)` | `MaxAngularSpeed` | `200pi` | Angular-velocity clamp (rad/s), stability cap. |
| `:InitialOrientation(cf)` | `InitialOrientation` | `nil` | Starting attitude; `nil` = aligned with fire direction. |
| `:InitialAngularVelocity(v)` | `InitialAngularVelocity` | `nil` | Seed angular velocity (spin / initial tumble). |
| `:CLAlphaMachTable(t)` | `CLAlphaMachTable` | `nil` | Mach-indexed lift-slope lookup. |
| `:CmAlphaMachTable(t)` | `CmAlphaMachTable` | `nil` | Mach-indexed pitching-moment-slope lookup. |
| `:CmqMachTable(t)` | `CmqMachTable` | `nil` | Mach-indexed pitch-damping lookup. |
| `:ClpMachTable(t)` | `ClpMachTable` | `nil` | Mach-indexed roll-damping lookup. |

---

## Custom Trajectory, `:Trajectory()`

Scripted path replacing physics. See [Custom Trajectories](./features/additions/trajectory).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Provider(fn)` | `TrajectoryPositionProvider` | `nil` | `(elapsed) -> Vector3?` position function; overrides the kinematic solver. |

---

## Wind, `:Wind()`

Per-bullet wind sensitivity (wind vector is set on the solver). See [Wind & Coriolis](./features/physics/wind-coriolis).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Response(n)` | `WindResponse` | `1.0` | Fraction of the solver's wind applied to this bullet; `0` opts out. |

---

## LOD, `:LOD()`

Distance-based step throttling. See [Level of Detail](./features/optimizations/lod).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Distance(n)` | `LODDistance` | `0` (off) | Studs from the LOD origin beyond which the bullet down-steps. |
| `:Interval(n)` | `LODInterval` | `3` | Step 1 frame in `n` once beyond `Distance`. Must be `>= 1`; `1` disables throttling. Skipped time is banked and released on the catch-up step. |

---

## Occupancy, `:StaticOccupancy()` / `:DynamicOccupancy()`

Voxel-grid raycast skipping. See [Occupancy](./features/optimizations/occupancy/static).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:StaticOccupancy(grid)` | `StaticOccupancy` | `nil` | Baked grid of unmoving geometry; clear segments skip the raycast. |
| `:DynamicOccupancy(set)` | `DynamicOccupancy` | `nil` | Set of moving rigid parts tested the same way. |

---

## Cosmetic, `:Cosmetic()`

Visual bullet part handling.

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Template(inst)` | `CosmeticBulletTemplate` | `nil` | Instance cloned as the visual bullet. |
| `:Container(inst)` | `CosmeticBulletContainer` | `nil` | Parent the cosmetic bullets are placed under. |
| `:Provider(fn)` | `CosmeticBulletProvider` | `nil` | `(ctx) -> Instance?`, pull a bullet from your own pool instead of cloning. |
| `:AutoDelete(b)` | `AutoDeleteCosmeticBullet` | `true` | Destroy the cosmetic bullet automatically when the cast terminates. |
| `:NonQueryable(b)` | `CosmeticBulletNonQueryable` | `true` | Set `CanQuery = false` and `CanTouch = false` on the cloned cosmetic bullet so it cannot be hit by its own raycasts or trigger touch events. Applies to `:Template()` clones only, not parts from `:Provider()`. |

---

## Top-Level Behavior Flags

Set directly on `BehaviorBuilder` (no sub-builder).

| Setter | Field | Default | Affects |
|--------|-------|--------:|---------|
| `:Hitscan(b)` | `IsHitscan` | `false` | Resolve the whole path synchronously in `Fire()`, no per-frame physics. See [Hitscan](./features/additions/hitscan). |
| `:BatchTravel(b)` | `BatchTravel` | `false` | Accumulate travel events and emit them once per frame via `OnTravelBatch`. |
| `:FireTravelEvents(b)` | `FireTravelEvents` | `true` | Fire `OnTravel` for a parallel cast, which forces it onto the sync path. Set `false` to opt out and drop the cast onto the fire-and-forget path, the main optimization lever at volume. See [Parallel](./features/optimizations/parallel#sync-vs-fire-and-forget). |
| `:UserData(v)` | `UserData` | `nil` | Free-form data carried with the bullet, available in every signal handler. |
| `:Debug():Visualize(b)` | `VisualizeCasts` | `false` | Draw cast segments, hit normals, bounce vectors, and corner-trap markers in-world. |

---

## Composition Helpers

Not behavior fields, builder methods for assembling behaviors. See the
[FAQ > Behaviors](./faq#behaviors).

| Method | Does |
|--------|------|
| `:Clone()` | Independent copy of the builder (originals untouched). |
| `:Impose(other)` | Copy only the explicitly-set fields of `other` onto this builder. |
| `:Merge(a, b, ...)` | Non-destructive: clone, then impose each modifier in order. |
| `:When(cond, fn)` | Run `fn(self)` only if `cond` is truthy; otherwise pass through unchanged. |
| `BehaviorBuilder.Inherit(frozen)` | Static, turn a frozen behavior into a mutable, fully-dirty builder. |
| `:Build()` | Validate and produce the final frozen `VetraBehavior`. |
