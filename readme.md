<div align="center">

**Every shot lands where physics says it should.**

[![Version](https://img.shields.io/badge/version-6.3-blue)](https://github.com/Vel136/Vetra/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/XMYMRKcd3g)


</div>

---

Vetra is an analytic-trajectory projectile simulation module for Roblox. Where most weapon systems move bullets by nudging `position += velocity * dt` each frame, drifting, tunnelling, disagreeing between client and server, Vetra uses the exact kinematic formula `P(t) = Origin + V₀t + ½At²`. No drift. No frame-rate dependency. A shared ground truth.

## Features

- **Analytic trajectory**, exact position at any time, independent of frame rate
- **High-fidelity sub-segment raycasting**, no bullet tunnels through thin geometry
- **Pierce**, multi-surface penetration with momentum modeling and exit-point detection
- **Bounce**, restitution, per-material coefficients, normal perturbation, corner-trap detection
- **Drag**, linear, quadratic, or G-series empirical models (G1, G5, G6, G7, G8, GL, Custom)
- **Magnus effect**, lateral force on spinning projectiles
- **Gyroscopic drift**, long-range directional yaw from spin precession
- **6DOF aerodynamics**, lift, pitching moment, pitch/yaw damping, roll damping, gyroscopic precession
- **Coriolis deflection**, configurable per map, latitude-accurate with exaggeration scale
- **Tumble**, destabilisation on speed loss or pierce, chaotic drag multiplier
- **Fragmentation**, cone-distributed child bullets on pierce
- **Hitscan**, single-frame hit resolution that skips kinematics; full pierce, bounce, and signal support with no per-frame cost
- **Homing**, frame-by-frame steering with strength, duration, and acquisition radius
- **Trajectory provider**, replace kinematics with any custom position curve
- **Supersonic / subsonic profiles**, different drag, restitution, and scatter per speed regime
- **LOD and spatial partitioning**, HOT / WARM / COLD tiers, interest-point driven
- **Parallel physics**, distributes raycasts across Roblox Actors; ~flat 4–10ms up to 20,000 bullets
- **VetraNet**, full networking middleware: serialization, rate limiting, origin validation, trajectory reconstruction, cosmetic replication, drift correction, all over one `RemoteEvent`
- **Typed builder**, `BehaviorBuilder` with build-time validation and frozen output
- **MIT licensed**

## Installation

Get Vetra from the Roblox Creator Store:

**[→ Install Vetra on Roblox](https://create.roblox.com/store/asset/75033515621317/Vetra)**

Then drop the `Vetra` folder into `ReplicatedStorage` and require it from your weapon scripts.
```lua
local Vetra = require(game.ReplicatedStorage.Vetra)
```

## Quick Start

```lua
local Vetra         = require(ReplicatedStorage.Vetra)
local BulletContext = Vetra.BulletContext

local Solver  = Vetra.new()
local Signals = Solver:GetSignals()

Signals.OnHit:Connect(function(context, result, velocity)
    if result then
        print("Hit", result.Instance.Name)
    end
end)

local Behavior = Vetra.BehaviorBuilder.Sniper():Build()

local context = BulletContext.new({
    Origin    = muzzlePosition,
    Direction = direction,
    Speed     = 900,
})

Solver:Fire(context, Behavior)
```

## Performance

Parallel solver frame times measured on a live Roblox server, 120-frame samples:

| Active bullets | Serial | Parallel | Speedup |
|---------------:|:------:|:--------:|:-------:|
| 50 | 10.3 ms | 4.2 ms | 2.5× |
| 200 | 14.0 ms | 4.2 ms | 3.4× |
| 1,000 | 45.2 ms | 4.2 ms | 10.8× |
| 5,000 | 174.7 ms | 5.5 ms | 32× |
| 20,000 |, | 10.3 ms |, |

The parallel solver's frame time is essentially flat from 25 to 2,000 bullets. See the [Benchmarks](https://vel136.github.io/Vetra/docs/guides/benchmarks) page for full data across all four profiles.

## Documentation

Full documentation at **[vel136.github.io/Vetra](https://vel136.github.io/Vetra/)**

- [Getting Started](https://vel136.github.io/Vetra/docs/intro)
- [Why Your Bullets Miss](https://vel136.github.io/Vetra/docs/guides/why-bullets-miss)
- [Making Bullets Feel Real](https://vel136.github.io/Vetra/docs/guides/physics-features)
- [Networking and Trust](https://vel136.github.io/Vetra/docs/guides/networking)
- [Performance](https://vel136.github.io/Vetra/docs/guides/performance)
- [Benchmarks](https://vel136.github.io/Vetra/docs/guides/benchmarks)
- [FAQ](https://vel136.github.io/Vetra/docs/faq)

## Community

- [Discord Server](https://discord.gg/XMYMRKcd3g)
- [Instagram](https://www.instagram.com/vedevelopment/)
- [X / Twitter](https://x.com/vedevelopment_)
- [TikTok](https://www.tiktok.com/@vedevelopment)

## License

MIT License, Copyright © 2026 VeDevelopment
