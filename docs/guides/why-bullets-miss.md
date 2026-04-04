---
sidebar_position: 1
---

# Why Your Bullets Miss

You fire a shot at a wall from close range. It goes straight through.

You try again from a few studs back. It hits perfectly. You step forward one more time, and it tunnels through again.

You've been there. Most people who build shooters on Roblox have. You debug it for an hour before quietly accepting that this is just how it is. You push the muzzle out a bit further, increase the part's thickness, and move on.

The frustrating part is that the code looks completely right. The bullet was fired. The hit never registered. Nothing is obviously wrong. But something is, and it's not your code, it's the *math* underneath it.

---

## The Problem Has a Name

It's called **Euler integration**, and almost every game uses it without thinking about it.

The idea is simple: each frame, you know where the bullet is and how fast it's moving, so you just nudge it forward:

```
newPosition = currentPosition + velocity * deltaTime
```

Simple. Cheap. Almost correct. The problem is that word *almost*.

Imagine a bullet travelling at 600 studs per second and your game is running at 60fps. That's a delta time of roughly `0.0167` seconds per frame. Multiply them together and your bullet moves **10 studs per frame**. Not continuously, in one discrete hop from A to B.

Now imagine a wall that is 2 studs thick sitting somewhere between A and B.

The bullet started before the wall. It ended after the wall. You cast a ray between those two points and it hits. Good.

But what if the wall is 0.5 studs thick? Now A is before the wall and B is *well past* the wall. The raycast still hits.

What if the wall is a union, made up of thin geometry, and the bullet starts and ends outside the bounding box? The raycast misses entirely. Your bullet passed through physics that never had a chance to be detected.

This is **tunnelling**. It's not a bug in your weapon code. It's an architectural consequence of asking "where did the bullet jump to this frame" instead of "what did the bullet pass through this frame."

---

## Frame Rate Makes It Worse

Here's the part that makes this problem genuinely unfair: it gets worse at lower frame rates, and better at higher ones. Your weapon might work fine during testing and randomly fail for players on older hardware.

At 60fps, `dt ≈ 0.017s`, and your 600 studs/s bullet hops 10 studs per frame.  
At 30fps, `dt ≈ 0.033s`, and that same bullet hops **20 studs per frame**.

The player on a slow machine isn't just seeing a worse-looking game, their bullets are tunnelling through surfaces that would have been detected on a faster machine. The same weapon behaves differently depending on hardware. That's not acceptable for a shooter.

---

## The Drift Problem

There's a second, quieter problem that Euler integration causes: error accumulates over time.

Every frame you compute `newPosition = currentPosition + velocity * deltaTime`. Sounds exact. But floating-point arithmetic isn't perfectly precise, and more importantly, `deltaTime` itself isn't constant. It bounces around every frame. A heavy frame gets a large `dt`. A light frame gets a small one.

These tiny fluctuations compound. A bullet that *should* arc gracefully under gravity will drift slightly off its true parabolic path after a few hundred studs. Not visibly, not catastrophically, but enough that hit detection gets sloppier the longer the bullet has been in flight. Snipers feel this more than anything.

For server-side validation, this drift is a real problem. The server needs to reconstruct where the client's bullet was at any given point in time. If both sides are using Euler integration and their frame rates differ even slightly, their reconstructed positions diverge, and the server starts rejecting legitimate hits.

---

## What Vetra Does Instead

Vetra doesn't update position by nudging. It uses the exact kinematic formula:

```
P(t) = Origin + V₀·t + ½·A·t²
```

This is the closed-form equation of motion for constant acceleration. Given a starting position, an initial velocity, and an acceleration, it tells you *exactly* where the bullet is at time `t`, not approximately, *exactly*. No accumulated drift. No frame-rate dependency. The same bullet fired on a 15fps machine and a 120fps machine will trace an identical path.

Each frame, Vetra computes where the bullet *was* at the start of the frame and where it *is* at the end, and raycasts between those two points. Because it has the exact position at both ends, the ray is always correct regardless of frame time variance.

When a bounce or velocity change happens, Vetra doesn't mutate the current position, it **opens a new trajectory segment** that begins at the exact current state. This is why you can have a bullet bounce three times and still get its position to sub-millimetre accuracy at any moment in its history: every arc is a clean parabola defined from known initial conditions.

The validator on the server uses these same stored trajectories to reconstruct the bullet's position at any point in time, independently of when it received the hit report. Two machines, two frame rates, one shared ground truth.

---

## But What About Thin Walls?

Analytic position fixes the drift problem, but by itself it still has the tunnelling issue. You're still casting one ray per frame across whatever distance the bullet travelled. A fast bullet can still hop over thin geometry.

This is what **high-fidelity mode** solves. When you enable it for a cast, Vetra subdivides each frame's travel into multiple smaller raycasts, sub-segments, so the maximum possible miss gap is `HighFidelitySegmentSize` studs instead of "one full frame of travel."

```lua
local Behavior = Vetra.BehaviorBuilder.new()
    :HighFidelity()
        :SegmentSize(0.2)  -- no surface thinner than 0.2 studs will be missed
        :FrameBudget(4)    -- spend at most 4ms per frame on sub-segments
    :Done()
    :Build()
```

The `FrameBudget` is important. If you set `SegmentSize` to `0.01` studs and fire 200 bullets, you'd be making tens of thousands of raycasts per frame. Vetra's adaptive system tracks the actual wall-clock cost of each cast's sub-segments and scales the segment size up or down in real time to stay near your budget. Thin-surface coverage self-adjusts to what the frame can afford.

The Sniper preset starts with `SegmentSize = 0.2` and a budget of `2ms`. That's tight enough to catch almost anything while leaving plenty of headroom for the rest of your game.

---

## The Takeaway

Bullets miss for a reason. It's not random, and it's not your fault, it's a mathematical property of the simulation approach underneath the weapon system.

Euler integration is fast and simple, but it accumulates error, drifts over time, and trades correctness for frame rate. For casual or slow-moving projectiles, this is often fine. For anything that needs to be fast, precise, or validated server-side, it falls apart.

Vetra's analytic approach means the bullet's position is always exact, independent of frame rate, and agreed on by both client and server. High-fidelity sub-segments close the tunnelling gap. The combination is what makes sniper rifles feel snappy at range and server validation work reliably, not luck, not fudge factors.

If you've been compensating for tunnelling by making walls thicker, you can stop now.
