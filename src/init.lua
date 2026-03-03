--!native
--!optimize 2
--!strict
-- ─── Vetra v2.0.1 ─────────────────────────────────────────────────────
--[[
    MIT License

    Copyright (c) 2026 VeDevelopment

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]

-- ─── Vetra ────────────────────────────────────────────────────────────
--[[
    Vetra — Analytic-trajectory projectile simulation module for Roblox.

    ── Architecture Overview ────────────────────────────────────────────────────

    This module maintains a flat array of active VetraCast objects on each
    solver instance, each representing one in-flight projectile. On every frame,
    _StepProjectile iterates that array and advances each projectile by the
    frame delta.

    Trajectory mathematics is computed analytically rather than via Euler
    integration. The projectile's world-space position at any time T is derived
    directly from the kinematic equation:

        P(t) = Origin + V0*t + 0.5*A*t²

    This design choice is fundamental to the module's correctness guarantees.
    Euler integration (P += V*dt; V += A*dt per frame) accumulates floating-point
    error at every step. Over long flight times or after many bounces, that error
    causes the simulated arc to visibly diverge from the intended parabola. The
    analytic form computes each position independently from the segment's fixed
    parameters, so accumulated error is structurally impossible regardless of
    frame count or flight duration. The tradeoff is that the trajectory must be
    representable as a constant-acceleration arc — non-constant forces require
    opening a new trajectory segment.

    After computing the analytic positions for the previous and current frames,
    a single raycast is performed between them to detect surface contacts. Each
    contact is resolved in priority order: pierce first, then bounce, then
    terminal impact. Pierce is evaluated before bounce because a bullet capable
    of piercing a surface must never simultaneously bounce off it — they are
    mutually exclusive physical outcomes. Enforcing this priority in code prevents
    compounding both effects on a single contact, which would produce physically
    incoherent results.

    ── Instance Isolation ───────────────────────────────────────────────────────

    Each call to Factory.new() produces a fully independent solver instance. All
    mutable state — the active cast registry, signal objects, bidirectional
    context maps, and per-frame raycast budget — lives on the instance table,
    not at module scope. The consequences of this design are:

        • Casts registered on instance A are only stepped by instance A's frame
          loop. Two solvers never interleave or share cast state.
        • Signals are per-instance. A handler connected to instance A's OnHit
          signal will never fire for a cast that belongs to instance B.
        • Multiple Factory.new() calls are valid and produce genuinely separate
          physics contexts. This is useful for separating server-authoritative hit
          validation from client-side cosmetic traces without cross-contamination.

    All internal functions that require solver state accept the Solver instance
    as their first explicit parameter. Pure functions that operate only on a
    single cast (PositionAtTime, VelocityAtTime, ModifyTrajectory, IsCornerTrap,
    ResolveBounce) take no Solver argument because they never access instance
    state.

    ── Context Integration ──────────────────────────────────────────────────────

    Every cast is paired with a BulletContext via a bidirectional weak map stored
    on the solver instance. BulletContext is the public-facing object that weapon
    code interacts with. This separation enforces a hard API boundary: weapon
    scripts read and write context fields (Position, Velocity, UserData) while
    the solver drives all internal physics state. The solver updates the context
    via _UpdateState each frame so any consumer polling the context between
    connections always sees current data.

    ── Signal Model ─────────────────────────────────────────────────────────────

    Signals are per-solver-instance and shared across all casts on that instance.
    Consumers connect once per solver and receive events from every cast it manages.
    Centralising signals this way avoids the per-cast connect/disconnect lifecycle
    and eliminates a class of connection-leak bugs where callers forget to
    disconnect when a cast ends. The BulletContext argument passed on every
    emission allows consumers to identify which cast triggered the event and
    dispatch accordingly.

    ── Performance Notes ────────────────────────────────────────────────────────

        • The active cast registry uses swap-remove (O(1)) so terminating a cast
          mid-array never shifts subsequent elements. This matters when many
          bullets terminate in the same frame (e.g. a shotgun blast where all
          pellets hit simultaneously).
        • Weak maps on both directions of the cast-to-context link allow GC to
          reclaim terminated cast objects without any explicit cleanup call on
          the consumer side.
        • RaycastParams objects are pooled to avoid per-fire allocation pressure.
          At high fire rates (dozens of bullets per second), creating a new
          RaycastParams on every call would generate significant GC churn.
        • Analytic position computation avoids the per-frame velocity integration
          step that Euler methods require, and produces no accumulated error over
          the cast's lifetime.
]]

-- ─── Services ────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ─── Sub-Module Requires ─────────────────────────────────────────────────────
--[[
    ParamsPooler:
        Manages a reusable pool of RaycastParams objects. Allocating a new
        RaycastParams on every Fire() call generates GC pressure at high fire
        rates. The pool maintains a set of pre-allocated objects and hands them
        out via Acquire(), returning them via Release(). Critically, the pool
        clones the caller's params rather than using them directly — this ensures
        that filter list mutations performed by the pierce system (which appends
        or removes instances as the bullet travels) never corrupt the caller's
        original RaycastParams object. Without cloning, a single params object
        shared between multiple Fire() calls would accumulate stale filter
        entries from every previous pierce chain that used it.

    Visualizer:
        Optional debug renderer that draws cast segments, surface normals,
        bounce directions, corner trap markers, and velocity vectors in the 3D
        world. All Visualizer calls are gated behind Behavior.VisualizeCasts,
        so the visual system is entirely dormant (zero runtime cost) in
        production builds where that flag is false.

    Type:
        Luau type definition module for VetraCast, CastTrajectory, and related
        structures. Imported here purely for type annotations and has no runtime
        effect. Keeping type definitions in a dedicated module prevents circular
        dependency chains and allows other modules to share the same type
        vocabulary without requiring Vetra itself.

    BehaviorBuilder:
        Fluent typed builder for constructing VetraBehavior configuration tables.
        Consumers chain namespace methods (:Physics(), :Bounce(), :Pierce(), etc.)
        and call :Build() to receive a validated, frozen VetraBehavior. Vetra
        does not depend on BehaviorBuilder internally — Fire() accepts any table
        that structurally matches VetraBehavior regardless of how it was constructed.
        BehaviorBuilder is re-exported on the Factory table so consumers only need to
        require Vetra and access the builder via Vetra.BehaviorBuilder,
        avoiding an extra require path.

    Signal:
        Lightweight event emitter. Each Factory.new() call creates a fresh set of
        Signal objects, ensuring events from different solver instances are fully
        isolated. Per-instance signal objects also mean there is no shared signal
        state that could cause cross-instance event leakage.

    LogService:
        Structured logger accepting an identity string (prefixed to every message)
        and a flag to enable printing in non-Studio builds. Structured prefixes
        allow filtering solver output in the console independently of other systems
        without relying on search strings.

    t:
        Runtime type-checking utility. Used in Fire() to validate caller-supplied
        input at the API boundary before any internal state is allocated. Failing
        fast at the boundary with a descriptive message is preferable to a
        cryptic nil-index error inside a physics function three call frames deep.
]]
local ParamsPooler    = require(script.RaycastParamsPooler)
local Visualizer      = require(script.TrajectoryVisualizer)
local Type            = require(script.TypeDefinition)
local BehaviorBuilder = require(script.BehaviorBuilder)

local BulletContext = require(script.BulletContext)

local VeSignal     = require(script.VeSignal)
local LogService = require(script.Logger)
local t          = require(script.TypeCheck)

-- ─── Logger ──────────────────────────────────────────────────────────────────

--[[
    Module-level logger. The IDENTITY string "Vetra" is prepended to
    every log message this module emits. This makes it trivial to filter solver
    output in the developer console without wading through messages from
    unrelated systems. The second argument (true) keeps logging active in
    non-Studio builds, which is intentional: physics bugs that only surface
    in live servers need to be observable without requiring a Studio reproduction.
]]
local IDENTITY = "Vetra"
local Logger = LogService.new(IDENTITY, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

--[[
    Frequently called globals are cached into upvalue locals at module load time.
    In Luau, resolving an upvalue uses a direct slot index inside the closure,
    whereas a global lookup requires a hash-table probe on the environment table
    every time the name is read. For functions called hundreds of times per second
    across all active casts — position computation, bounce timing, sub-segment
    iteration — this difference is measurable at scale.

    The specific globals cached here and why they appear on the hot path:

        OsClock:
            Called on every bounce to record Runtime.LastBounceTime for corner-trap
            detection, and in ResimulateHighFidelity to measure per-sub-segment
            wall time against the frame budget. At 60Hz with 20 active bullets
            and 40 sub-segments each, OsClock is called thousands of times per
            second — caching it meaningfully reduces environment lookups.

        CFrameNew:
            Called every frame per bullet to orient the cosmetic part toward its
            direction of travel. Also called by several Visualizer helpers when
            debug rendering is active.

        MathMax:
            Used in adaptive segment size adjustment to clamp the lower bound
            of CurrentSegmentSize above MinSegmentSize.

        MathClamp:
            Used in ResimulateHighFidelity to constrain SubSegmentCount to the
            range [1, MAX_SUBSEGMENTS].

        MathFloor:
            Used in sub-segment count calculation. The raw division of
            FrameDisplacement / CurrentSegmentSize is a float; flooring it
            produces the integer count of whole raycasts that fit in the frame.
]]
local OsClock    = os.clock
local CFrameNew  = CFrame.new
local MathMax    = math.max
local MathClamp  = math.clamp
local MathFloor  = math.floor

-- ─── Runtime Environment Detection ───────────────────────────────────────────

--[[
    Determines whether this module is executing on the server or the client.
    This check runs once at module load time and the result is stored as a
    boolean constant, avoiding a repeated property lookup on RunService every
    frame.

    The result dictates which RunService event each solver instance's simulation
    loop connects to:

        Server → Heartbeat:
            Heartbeat fires after Roblox's internal physics simulation step has
            settled for the frame. Using it on the server ensures that hit
            positions are resolved against the most up-to-date authoritative
            world state, which matters for server-side damage validation.

        Client → RenderStepped:
            RenderStepped fires before the frame is composited and sent to the
            GPU. Using it on the client ensures cosmetic bullet visuals are
            positioned correctly at render time. If Heartbeat were used on the
            client instead, bullet visuals would always lag one frame behind
            their logical position, producing a subtle but visible trailing
            offset on fast projectiles.
]]
local IS_SERVER = RunService:IsServer()

-- ─── Constants ───────────────────────────────────────────────────────────────

--[[
    GLOBAL_FRAME_BUDGET_MS:
        The maximum total wall-clock time in milliseconds that a Vetra
        instance may spend on high-fidelity sub-segment raycasts across all of
        its active casts within a single frame. The budget is consumed by
        ResimulateHighFidelity as each sub-segment raycast completes, and once
        it reaches zero, any remaining sub-segments for all casts on that
        instance are skipped for the rest of the frame.

        4ms is chosen because a 60Hz frame allocates roughly 16.7ms total, of
        which Roblox's internal systems consume the majority. Leaving script
        budget at around 4ms for high-fidelity raycasts preserves headroom for
        game logic without producing visible frame hitches under typical bullet
        loads. This budget is reset at the start of each _StepProjectile call.

        Because the budget lives on the solver instance (not at module scope),
        two concurrent solver instances each receive the full 4ms allocation
        independently rather than competing for a shared pool.

    MAX_SUBSEGMENTS:
        Hard upper bound on the number of sub-segment raycasts a single cast may
        perform in a single frame. Even at extreme speeds with a very small
        CurrentSegmentSize, no single cast can issue more than 500 raycasts per
        frame. Without this cap, a bullet moving at thousands of studs per second
        with a segment size of 0.01 would attempt ~10,000 raycasts in one frame
        and freeze the game thread. This cap is a last-resort safety valve; in
        normal operation MaxPierceCount and the frame budget throttle the count
        long before 500 is reached.

    PROVIDER_TIMEOUT:
        Maximum number of seconds CosmeticBulletProvider is expected to take before
        a warning is logged. The provider is called synchronously inside Fire(),
        which runs on the game's main thread. Any yield inside the provider would
        stall the thread that called Fire() — typically a weapon script running
        inside a RunService event — blocking all subsequent work in that event
        connection until the yield resolves. A 3-second threshold is generous for
        any synchronous operation; exceeding it almost certainly indicates an
        accidental task.wait() or a slow Instance search inside the provider.

    DEFAULT_GRAVITY:
        Captures workspace.Gravity at module load time and stores it as a
        downward Vector3 (negative Y component) that can be directly used as an
        acceleration term. This serves two purposes:
            1. Avoids reading the workspace property on every Fire() call.
            2. Ensures gravity is consistent across a cast's lifetime even if
               workspace.Gravity is changed mid-session by another script.
        The negated form is pre-computed so callers adding it to Acceleration
        never need to negate it at the call site, removing one potential source
        of sign errors.

    NUDGE:
        A small displacement (0.01 studs) applied along the ray or normal direction
        after a pierce or bounce to move the next raycast's origin safely clear of
        the contact surface. Without this offset, the next workspace:Raycast() call
        would originate on the surface plane itself. Due to floating-point precision
        limits, a ray origin exactly on a surface may re-detect that same surface at
        near-zero distance, producing a spurious double-hit or, in the bounce case,
        an instant re-bounce that reverses the bullet's direction. 0.01 studs is
        imperceptibly small in practice but large enough to reliably clear
        floating-point surface contact ambiguity.

    ZERO_VECTOR:
        Cached to avoid constructing Vector3.zero at every comparison site. Also
        used as a sentinel value for "no previous bounce data" in Runtime fields
        (LastBounceNormal, LastBouncePosition). Using the zero vector as a sentinel
        allows IsCornerTrap to gate its normal-opposition and spatial-proximity
        guards behind a single `~= ZERO_VECTOR` check rather than carrying a
        separate boolean field for each guard. This keeps the VetraCast table
        lean and makes the sentinel's meaning self-documenting at the check site.
]]
local GLOBAL_FRAME_BUDGET_MS = 4
local MAX_SUBSEGMENTS        = 500
local PROVIDER_TIMEOUT       = 3
local DEFAULT_GRAVITY        = Vector3.new(0, -workspace.Gravity, 0)
local NUDGE                  = 0.01
local ZERO_VECTOR            = Vector3.zero

-- ─── Default Behavior ────────────────────────────────────────────────────────

--[[
    DEFAULT_BEHAVIOR is the authoritative fallback for every field in
    VetraBehavior. When Fire() receives a partial behavior table, any missing
    field is resolved against this table. The defaults are chosen to be physically
    reasonable and safe out-of-the-box so that a caller with minimal configuration
    still gets a sensible, non-degenerate projectile.

    Field-by-field rationale:

        Acceleration = Vector3.zero:
            Extra non-gravity acceleration (e.g. sustained rocket thrust) defaults
            to none. Gravity is handled via a separate Gravity field and added to
            Acceleration inside Fire() so the two forces remain conceptually
            distinct and individually overridable.

        MaxDistance = 500:
            Prevents bullets from simulating indefinitely in open worlds. 500 studs
            covers most first-person or third-person combat distances. Stray bullets
            that miss every surface are culled at this limit rather than running
            forever and accumulating wasted simulation cost.

        MinSpeed = 1:
            Bullets that have decelerated to near-zero (e.g. after repeated
            energy-absorbing bounces) are culled cleanly at 1 stud/second. At this
            speed the bullet is visually imperceptible and no longer contributes
            meaningful gameplay, making it safe to terminate without visible
            artifacts.

        HighFidelitySegmentSize = 0.5:
            Sub-segments are approximately 0.5 studs long. This means a bullet
            moving at standard speed will issue ~10 raycasts per frame at 60Hz,
            and even a wall only 1 stud thick will be reliably intersected without
            tunnelling. Smaller values increase fidelity at the cost of more raycasts
            per frame; larger values reduce cost at the risk of thin-surface tunnelling.

        Restitution = 0.7:
            Retains 70% of kinetic energy per bounce, producing a moderately bouncy
            feel similar to a rubber ball. This is lossy enough that a bullet cannot
            bounce indefinitely — repeated bounces converge the speed toward zero —
            while energetic enough for the bouncing to appear purposeful and
            interesting.

        PenetrationSpeedRetention = 0.8:
            Each pierce absorbs 20% of the bullet's kinetic energy, simulating the
            mechanical work done deforming the material. This makes longer pierce
            chains progressively less lethal and provides a natural ceiling on how
            many targets a single bullet can damage at meaningful impact speed.

        PierceNormalBias = 1.0:
            Requires the bullet's impact angle dot product to be at least 0.0,
            meaning all approach angles qualify for piercing (even a near-grazing
            trajectory). Reducing this value toward 0 would restrict piercing to
            near-perpendicular impacts only, preventing bullets that skim a surface
            at shallow angles from tunnelling through it.
]]

local DEFAULT_BEHAVIOR: VetraBehavior = {
	Acceleration                 = Vector3.new(0, 0, 0),
	MaxDistance                  = 500,
	RaycastParams                = RaycastParams.new(),
	MinSpeed                     = 1,
	CanPierceFunction            = nil,
	MaxPierceCount               = 3,
	PierceSpeedThreshold         = 50,
	Gravity                      = Vector3.new(0, -workspace.Gravity, 0),
	PenetrationSpeedRetention    = 0.8,
	ResetPierceOnBounce			 = false,
	PierceNormalBias             = 1.0,
	CanBounceFunction            = nil,
	MaxBounces                   = 5,
	BounceSpeedThreshold         = 20,
	Restitution                  = 0.7,
	MaterialRestitution          = {},
	NormalPerturbation           = 0.0,
	HighFidelitySegmentSize      = 0.5,
	HighFidelityFrameBudget      = 4,
	AdaptiveScaleFactor          = 1.5,
	MinSegmentSize               = 0.1,
	MaxBouncesPerFrame           = 10,
	CornerTimeThreshold          = 0.002,
	CornerNormalDotThreshold     = -0.85,
	CornerDisplacementThreshold  = 0.5,
	CosmeticBulletTemplate       = nil,
	CosmeticBulletContainer      = nil,
	VisualizeCasts               = false,
}

-- ─── Physics Helpers ─────────────────────────────────────────────────────────
--[[
    PositionAtTime and VelocityAtTime are pure functions: they derive their
    result entirely from their parameters and have no side effects on any shared
    state. They intentionally accept no Solver argument — they never touch instance
    or module-level tables. This makes them safe to call from any context and
    trivial to reason about in isolation.

    Both functions sit on the most critical hot path in the module. Every active
    cast calls PositionAtTime at least twice per frame (once for the previous
    position, once for the current position) and VelocityAtTime at least once.
    At 20 active bullets and 40 sub-segments each, that is 1600+ calls per frame.
    Keeping these functions free of table lookups, closures, and branch overhead
    is therefore important for maintaining consistent frame times.
]]

--[=[
    PositionAtTime

    Description:
        Computes the exact world-space position of a projectile at a given time
        offset within a trajectory segment using the standard kinematic equation
        for constant acceleration:

            P(t) = Origin + V0*t + (1/2)*A*t²

        This is the analytic form of the position equation, meaning it computes
        the result in closed form directly from the segment's fixed parameters
        without stepping through intermediate time values. It is deliberately
        chosen over Euler integration (P += V*dt; V += A*dt each frame) for
        two fundamental reasons:

        1. Euler integration accumulates floating-point error on every step. Over
           long flight times or many frames, the simulated arc drifts away from
           the true parabola. For a sniper bullet that travels 500 studs, even a
           small per-frame error multiplies into a visible arc distortion at range.
           The analytic form produces bit-identical results regardless of how many
           frames have elapsed, because every position is computed independently
           from the same fixed parameters.

        2. Euler integration requires both position and velocity to be tracked and
           mutated together each frame. The analytic form derives both from the
           segment's immutable initial conditions, making the trajectory state
           simpler to store and reason about — each segment is fully described by
           Origin, V0, A, and StartTime.

    Parameters:
        ElapsedTime: number
            Seconds elapsed since this trajectory segment's StartTime. This is
            always (Runtime.TotalRuntime - ActiveTrajectory.StartTime), not
            wall-clock time. After a bounce opens a new segment, ElapsedTime
            correctly resets to zero for the new arc because StartTime is set
            to the bounce time — ensuring the formula evaluates the new arc from
            its own origin, not from the original fire point.

        TrajectoryOrigin: Vector3
            World-space origin of this trajectory segment. For the initial firing,
            this is the muzzle position. After a bounce it is the contact point
            offset along the surface normal by NUDGE to clear floating-point
            surface ambiguity and prevent the first raycast on the new arc from
            immediately re-detecting the same surface.

        InitialVelocity: Vector3
            Velocity vector at the start of this trajectory segment in studs per
            second. After a bounce this is the reflected and energy-scaled velocity
            produced by ResolveBounce.

        Acceleration: Vector3
            The constant acceleration acting on the bullet for the entirety of
            this segment. Typically the sum of gravity and any additional
            Behavior.Acceleration. The combined value is computed once in Fire()
            and stored on the trajectory so this function never needs to add the
            two terms together at runtime.

    Returns:
        Vector3
            The exact world-space position at ElapsedTime seconds into this
            trajectory segment. The result is precise to floating-point limits
            regardless of how many frames have elapsed since the segment started.

    Notes:
        The t² / 2 form and 0.5 * t^2 are mathematically identical. The exponent
        notation is used here because it mirrors the standard physics notation and
        is marginally easier to verify against a textbook. Luau compiles both to
        the same bytecode.
]=]
local function PositionAtTime(
	ElapsedTime: number,
	TrajectoryOrigin: Vector3,
	InitialVelocity: Vector3,
	Acceleration: Vector3
): Vector3
	-- Standard constant-acceleration kinematic position formula.
	-- The origin term is invariant; the velocity term grows linearly with time;
	-- the acceleration term grows quadratically. Luau evaluates Vector3 arithmetic
	-- left-to-right respecting standard operator precedence, so no extra
	-- parentheses are required to produce the correct result.
	return TrajectoryOrigin + InitialVelocity * ElapsedTime + Acceleration * (ElapsedTime ^ 2 / 2)
end

--[=[
    VelocityAtTime

    Description:
        Computes the exact velocity vector of a projectile at a given time offset
        within a trajectory segment by evaluating the analytic first derivative of
        the kinematic position equation:

            V(t) = V0 + A*t

        Like PositionAtTime, this is analytic and produces exact results without
        accumulating per-frame error. The velocity is evaluated on every active
        cast every frame because it is consumed by multiple downstream systems:

            Speed threshold checks:
                Pierce speed, bounce speed, and MinSpeed culling all compare
                CurrentVelocity.Magnitude against their respective thresholds.
                Using the analytic value here means the check is always accurate
                at the exact moment of the potential surface interaction, not at
                the frame's start position.

            Cosmetic orientation:
                The visible bullet part is oriented by building a CFrame toward
                (Position + Velocity.Unit), aligning the part's forward axis with
                the direction of travel. Using the analytically correct velocity
                direction at the current moment ensures the cosmetic part is never
                visually misaligned relative to its actual trajectory.

            Signal arguments:
                OnHit, OnBounce, and OnPierce all receive the velocity at the time
                of the event so consumers can compute impact force, apply damage
                falloff, or play velocity-dependent VFX without needing to
                re-derive it themselves.

    Parameters:
        ElapsedTime: number
            Seconds elapsed since this trajectory segment's StartTime. Same
            semantics as PositionAtTime — this is segment-local time, not total
            cast lifetime.

        InitialVelocity: Vector3
            Velocity at the beginning of the trajectory segment. Unchanged for
            the segment's lifetime; only varies between segments (e.g. after a
            bounce applies reflection and restitution).

        Acceleration: Vector3
            The constant acceleration for this segment. Same value stored on the
            segment's Acceleration field.

    Returns:
        Vector3
            The exact velocity vector at ElapsedTime seconds into this segment.
            The magnitude of this vector is the bullet's current speed in studs
            per second. The vector is not normalised; callers that need a unit
            direction vector should call .Unit themselves. Normalising here would
            discard the magnitude, which most callers also need for threshold
            comparisons.
]=]

local function VelocityAtTime(
	ElapsedTime: number,
	InitialVelocity: Vector3,
	Acceleration: Vector3
): Vector3
	-- First derivative of the kinematic position equation. Under constant
	-- acceleration, velocity changes linearly with time. V0 is the velocity at
	-- the segment's start; A*t is the cumulative velocity gain from acceleration
	-- over the elapsed interval. Adding them gives the exact velocity at time T
	-- without any accumulated per-step error.
	return InitialVelocity + Acceleration * ElapsedTime
end

-- ─── Trajectory Modifier ─────────────────────────────────────────────────────

--[=[
    ModifyTrajectory

    Description:
        Applies a mid-flight change to one or more kinematic parameters of a cast
        (position, velocity, or acceleration). This is the single shared
        implementation used by every CAST_STATE_METHODS setter: SetPosition,
        SetVelocity, SetAcceleration, AddPosition, AddVelocity, and AddAcceleration
        all delegate here. Centralising the logic means the "should we mutate in
        place or open a new segment?" decision is made in exactly one location and
        cannot diverge across six separate setter implementations.

        There are two cases based on whether simulation time has elapsed on the
        current trajectory segment:

        Case 1 — Zero elapsed time (StartTime == TotalRuntime):
            The change is being applied at the precise instant the current segment
            started — no simulation has run on it yet. Mutating the segment in place
            is safe because there is no recorded history to preserve. This is the
            zero-overhead fast path: it avoids a table allocation and a table.insert
            call. This case is commonly hit when Fire() constructs the initial segment
            and immediately applies a velocity override before the first frame step.

        Case 2 — Positive elapsed time (StartTime < TotalRuntime):
            The current segment has already been partially simulated. The historical
            positions recorded in its arc are real data that consumers (e.g. replays
            or trajectory renderers) may be reading. To preserve that history while
            redirecting the bullet from this point forward, the current segment is
            closed by recording its EndTime, then a new segment is opened from the
            analytically computed handoff position and velocity. The new segment
            begins with the caller's overrides (or the computed handoff values for
            any nil arguments). This ensures that the full Trajectories history
            remains accurate as an append-only log of every arc the bullet has
            travelled.

        CancelResimulation is set to true when a new segment is opened. This flag
        is read by ResimulateHighFidelity's inner loop as a signal to stop
        processing remaining sub-segments. Continuing to step sub-segments on the
        old (now-closed) trajectory after a mid-flight change would produce raycast
        positions on an arc the bullet has already left, yielding physically
        incorrect hit detections.

        All input vectors are validated before any state is mutated. NaN or infinity
        in a velocity or position vector would propagate silently through all
        subsequent PositionAtTime and VelocityAtTime calls, producing positions at
        (nan, nan, nan) that never satisfy any termination condition. The cast would
        simulate forever, leaking an entry in _ActiveCasts, with no useful
        diagnostic. Aborting early here prevents that failure mode and surfaces the
        error at the earliest possible point.

    Parameters:
        Cast: VetraCast
            The cast whose trajectory is being modified. ModifyTrajectory reads and
            writes Cast.Runtime fields only; it never touches the solver registry,
            signals, or context maps.

        Velocity: Vector3?
            New initial velocity for the resulting segment, or nil to use the
            analytically computed velocity at the moment of the change.

        Acceleration: Vector3?
            New constant acceleration for the resulting segment, or nil to inherit
            the current trajectory's acceleration unchanged.

        Position: Vector3?
            New world-space origin for the resulting segment, or nil to use the
            analytically computed position at the moment of the change.

    Returns:
        nil — modifies Cast.Runtime in place.

    Notes:
        Passing nil for all three parameters is technically valid but produces
        a new trajectory segment that is kinematically identical to the current one.
        This wastes a table allocation and a table.insert call with no observable
        effect. Callers should always supply at least one non-nil parameter.
]=]

local function ModifyTrajectory(Cast: VetraCast, Velocity: Vector3?, Acceleration: Vector3?, Position: Vector3?)
	-- Validate all input vectors before touching any state. A NaN velocity
	-- would silently corrupt every subsequent PositionAtTime call, producing
	-- (nan, nan, nan) positions that never trigger any termination condition and
	-- cause the cast to simulate indefinitely. Aborting here surfaces the error
	-- at the API boundary rather than letting it propagate into physics math.
	if Velocity and not t.Vector3(Velocity) then
		Logger:Warn("ModifyTrajectory: Velocity contains NaN or inf — ignoring")
		return
	end
	if Acceleration and not t.Vector3(Acceleration) then
		Logger:Warn("ModifyTrajectory: Acceleration contains NaN or inf — ignoring")
		return
	end
	if Position and not t.Vector3(Position) then
		Logger:Warn("ModifyTrajectory: Position contains NaN or inf — ignoring")
		return
	end

	local Runtime = Cast.Runtime
	local Last    = Runtime.ActiveTrajectory

	if Last.StartTime == Runtime.TotalRuntime then
		-- Case 1: The modification occurs at the exact moment this segment began.
		-- No simulation time has elapsed on it, so there is no historical arc to
		-- preserve. Mutate the segment fields directly — this avoids allocating a
		-- new table and keeps the Trajectories array compact.
		Last.Origin          = Position     or Last.Origin
		Last.InitialVelocity = Velocity     or Last.InitialVelocity
		Last.Acceleration    = Acceleration or Last.Acceleration
	else
		-- Case 2: The current segment has non-zero elapsed time, meaning it has
		-- been partially simulated and its arc is part of the bullet's recorded
		-- history. Close the current segment by stamping its EndTime, then derive
		-- the handoff point analytically so the seam between the old and new arcs
		-- is mathematically exact rather than approximated by the last frame's
		-- cached position (which could be up to one full frame stale).
		Last.EndTime = Runtime.TotalRuntime

		-- Analytically compute the exact position and velocity at the current
		-- moment in the active segment's arc. These become the new segment's origin
		-- and initial velocity if the caller did not supply explicit overrides.
		-- Using the analytic values (rather than cached per-frame values) prevents
		-- a visible position discontinuity at the segment seam.
		local Elapsed  = Runtime.TotalRuntime - Last.StartTime
		local EndPos   = PositionAtTime(Elapsed, Last.Origin, Last.InitialVelocity, Last.Acceleration)
		local EndVel   = VelocityAtTime(Elapsed, Last.InitialVelocity, Last.Acceleration)
		local NewAccel = Acceleration or Last.Acceleration

		-- Open a new trajectory segment starting at the current moment. The new
		-- segment's StartTime anchors all subsequent ElapsedTime computations
		-- (TotalRuntime - StartTime) to this transition point.
		local NewTrajectory: Type.CastTrajectory = {
			StartTime       = Runtime.TotalRuntime,
			EndTime         = -1,
			Origin          = Position or EndPos,
			InitialVelocity = Velocity or EndVel,
			Acceleration    = NewAccel,
		}

		table.insert(Runtime.Trajectories, NewTrajectory)
		Runtime.ActiveTrajectory   = NewTrajectory
		-- Notify ResimulateHighFidelity to abandon the current sub-segment loop.
		-- Continuing to advance sub-segments on the old trajectory after a mid-flight
		-- change would produce raycast positions on an arc the bullet has already
		-- left, resulting in phantom hit detections and incorrect distance accumulation.
		Runtime.CancelResimulation = true
	end
end

-- ─── Cast State Methods ───────────────────────────────────────────────────────

--[[
    CAST_STATE_METHODS defines the public instance-method surface exposed on
    every VetraCast via its metatable __index. These methods are surfaced through
    the BulletContext API, allowing weapon scripts to read or modify a bullet's
    kinematic state mid-flight without direct access to the solver's internal tables.

    Design decision — all mutation methods delegate to ModifyTrajectory:
        The "mutate in place vs. open a new segment" decision is complex enough
        (and critical enough to get right) that it lives in exactly one function.
        Having six separate setter methods each duplicate that logic would be
        fragile and prone to divergence over time. Delegating to ModifyTrajectory
        means every setter inherits correct segment-sealing, CancelResimulation
        signalling, and input validation automatically.

    Design decision — Add* methods perform a single ModifyTrajectory call:
        The Add* variants (AddPosition, AddVelocity, AddAcceleration) read the
        current analytic value and immediately pass the result to ModifyTrajectory
        as the new override. They do NOT call ModifyTrajectory twice (once to read,
        once to write) — the Get* call is a pure read with no side effects, so
        combining both into a single ModifyTrajectory call is both cheaper and
        effectively atomic: no intermediate partially-modified state is ever written.

    These methods only read and write Cast-level state. They never require a
    Solver argument because ModifyTrajectory (which they delegate to) also has
    no Solver dependency.
]]

local CAST_STATE_METHODS = {

	-- Returns the bullet's current world-space position by evaluating the analytic
	-- kinematic formula at the elapsed time within the active trajectory segment.
	-- Using the analytic value guarantees accuracy regardless of when in the frame
	-- this method is called — it is not tied to any cached per-frame snapshot.
	GetPosition = function(self: VetraCast)
		local Traj    = self.Runtime.ActiveTrajectory
		local Elapsed = self.Runtime.TotalRuntime - Traj.StartTime
		return PositionAtTime(Elapsed, Traj.Origin, Traj.InitialVelocity, Traj.Acceleration)
	end,

	-- Resets the three corner-trap sentinel fields on Runtime to their Fire()-time
	-- initial values. This is necessary after any programmatic mid-flight velocity
	-- change that deliberately reverses or sharply redirects the bullet (e.g.
	-- SetVelocity, AddVelocity).
	--
	-- Why this matters:
	--     IsCornerTrap compares the current bounce against the most recent stored
	--     bounce normal and contact position. A sharp velocity reversal applied via
	--     SetVelocity will not register in the bounce tracking fields, but the next
	--     genuine surface contact will compare against the stale previous-bounce data.
	--     If the new trajectory happens to hit a surface whose normal is nearly
	--     opposite the previously stored LastBounceNormal (Guard 2), or if the first
	--     contact after the velocity change is close to the last recorded bounce
	--     position (Guard 3), IsCornerTrap will fire a false positive and terminate
	--     the cast prematurely — even though no actual degenerate geometry is involved.
	--
	-- After this call, IsCornerTrap's guards behave as follows:
	--     LastBounceTime = -math.huge:
	--         Guard 1 (temporal proximity) cannot fire on the next bounce, because
	--         the time since the last recorded bounce appears infinite.
	--     LastBounceNormal = ZERO_VECTOR:
	--         Guard 2 (normal opposition) is skipped entirely. The HasPreviousBounceNormal
	--         check treats ZERO_VECTOR as "no previous data" and short-circuits the guard.
	--     LastBouncePosition = ZERO_VECTOR:
	--         Guard 3 (spatial proximity) is skipped. HasPreviousBouncePosition treats
	--         ZERO_VECTOR as "no previous data" and short-circuits the guard.
	--
	-- This does NOT reset BounceCount or BouncesThisFrame. Those counters track
	-- lifetime and per-frame bounce budgets respectively and are independent of the
	-- corner-trap detection state.
	ResetBounceState = function(self: VetraCast)
		self.Runtime.LastBounceNormal   = Vector3.zero
		self.Runtime.LastBouncePosition = Vector3.zero
		self.Runtime.LastBounceTime     = -math.huge
	end,
	-- Resets the pierce tracking state on Runtime to its Fire()-time initial values.
	-- This is the pierce-side counterpart to ResetBounceState and exists for the same
	-- reason: a programmatic mid-flight event (most commonly a bounce that redirects
	-- the trajectory) can leave stale pierce data that produces incorrect behaviour on
	-- the new arc.
	ResetPierceState = function(self: VetraCast)
		local Behavior = self.Behavior
		self.Runtime.PiercedInstances = {}
		self.Runtime.PierceCount = 0
		Behavior.RaycastParams.FilterDescendantsInstances =
			table.clone(Behavior.OriginalFilter)
	end,
	-- Returns the bullet's current velocity vector by evaluating the analytic
	-- derivative formula at the elapsed time within the active trajectory segment.
	-- The magnitude of the returned vector is the current speed in studs/second.
	-- Not normalised — callers that need a unit direction should call .Unit on the
	-- result themselves.
	GetVelocity = function(self: VetraCast)
		local Traj    = self.Runtime.ActiveTrajectory
		local Elapsed = self.Runtime.TotalRuntime - Traj.StartTime
		return VelocityAtTime(Elapsed, Traj.InitialVelocity, Traj.Acceleration)
	end,

	-- Returns the constant acceleration vector for the active segment. This is the
	-- combined (gravity + extra Acceleration) value stored on the trajectory at
	-- segment creation time — not workspace.Gravity directly. Consumers reading
	-- this can retrieve the effective gravity field for a given projectile type
	-- (e.g. for low-gravity areas or zero-gravity scenarios).
	GetAcceleration = function(self: VetraCast)
		return self.Runtime.ActiveTrajectory.Acceleration
	end,

	-- Teleports the bullet to a new world-space position without changing its
	-- velocity or acceleration. If simulation time has already elapsed on the
	-- current segment, ModifyTrajectory opens a new segment from the specified
	-- position, preserving the recorded arc history up to this point.
	SetPosition = function(self: VetraCast, Position: Vector3)
		ModifyTrajectory(self, nil, nil, Position)
	end,

	-- Overrides the bullet's current velocity with the supplied vector. The new
	-- velocity becomes InitialVelocity of either the current segment (if it just
	-- started) or a new segment opened at the analytically current position.
	-- Acceleration is inherited from the current segment unchanged.
	SetVelocity = function(self: VetraCast, Velocity: Vector3)
		ModifyTrajectory(self, Velocity, nil, nil)
	end,

	-- Replaces the constant acceleration for future simulation. Because acceleration
	-- is invariant within a segment, applying a new value always requires either
	-- mutating the current segment in place (zero elapsed time) or opening a new
	-- segment (positive elapsed time). Both cases are handled by ModifyTrajectory.
	SetAcceleration = function(self: VetraCast, Acceleration: Vector3)
		ModifyTrajectory(self, nil, Acceleration, nil)
	end,

	-- Translates the bullet by Offset in world space. Reads the current analytic
	-- position and adds the offset before delegating to ModifyTrajectory. The
	-- read-then-write is effectively atomic — no frame tick can occur between the
	-- GetPosition call and the ModifyTrajectory call because both run on the
	-- simulation thread without yielding.
	AddPosition = function(self: VetraCast, Offset: Vector3)
		ModifyTrajectory(self, nil, nil, self:GetPosition() + Offset)
	end,

	-- Applies an impulse by adding Delta to the bullet's current velocity. Useful
	-- for mid-flight effects like explosion knockback or wind gusts. The current
	-- velocity is read analytically, ensuring the delta is applied to the precise
	-- instantaneous velocity rather than a frame-start approximation.
	AddVelocity = function(self: VetraCast, Delta: Vector3)
		ModifyTrajectory(self, self:GetVelocity() + Delta, nil, nil)
	end,

	-- Adds a delta to the bullet's constant acceleration for the new segment.
	-- Useful for incrementally building up a non-constant force (e.g. a sustained
	-- thruster that fires AddAcceleration every frame) without needing to track
	-- the running total externally.
	AddAcceleration = function(self: VetraCast, Delta: Vector3)
		ModifyTrajectory(self, nil, self:GetAcceleration() + Delta, nil)
	end,
}

-- ─── Registry Helpers ────────────────────────────────────────────────────────
--[[
    Register and Remove accept the Solver instance as their first argument so
    they operate on the per-instance Solver._ActiveCasts array rather than any
    module-level state. This is the key structural change that isolates each
    solver instance's cast population — casts registered on instance A can never
    appear in instance B's iteration.

    The backing data structure is a flat integer-indexed array. This choice over
    a dictionary (keyed by cast ID or the cast table itself) is motivated by:

        1. Cache locality:
            Iterating indices 1..N over a contiguous array is substantially more
            cache-friendly than dictionary enumeration, which follows hash chain
            pointers into scattered heap memory. At high cast counts the cache
            pressure difference is measurable.

        2. O(1) swap-remove:
            Removing an arbitrary element from a dense array normally costs O(n)
            because all elements after the removed one must shift left by one slot.
            Swap-remove avoids this by replacing the removed element with the last
            element and shrinking the array length by one. This is O(1) regardless
            of array size. The tradeoff is that iteration order is not preserved
            after a removal — but _StepProjectile does not depend on order.

    Each cast stores its current array index in _registryIndex. This field is
    what makes O(1) swap-remove possible in Remove(): instead of scanning
    _ActiveCasts to find the cast to remove (O(n)), we read its index directly
    and jump straight to that slot. _registryIndex must be kept current whenever
    the swap moves a cast to a new position.
]]

--[=[
    Register

    Description:
        Inserts a VetraCast into the solver instance's _ActiveCasts array and
        records the cast's current array index in its own _registryIndex field.

        The index is stored on the cast itself (rather than in a separate parallel
        lookup table) because the cast is already a mutable record. Embedding the
        index avoids the overhead of a separate hash-table lookup and keeps the
        registry metadata co-located with the object it describes.

        The stored _registryIndex is the critical invariant that enables O(1)
        removal in Remove(). Without it, Remove() would need to linearly scan
        _ActiveCasts to find the element, making batch terminations (e.g. a
        shotgun blast with many simultaneous terminal hits) quadratic in cost.

    Parameters:
        Solver: Vetra
            The solver instance whose _ActiveCasts array receives the cast.

        CastToRegister: {}
            The VetraCast table to register. After this call, _registryIndex
            will be set on the table. Callers must not rely on the table being
            unmodified after registration.

    Returns:
        boolean
            True if registration succeeded. False if the input is not a table
            or if the cast already has a _registryIndex field set, indicating it
            was previously registered without being properly removed. Double-
            registration is treated as a caller error rather than a recoverable
            state — silently overwriting the existing index would corrupt the
            registry by creating an orphaned entry at the old index slot that
            the solver would never be able to remove.
]=]
local function Register(Solver: Vetra, CastToRegister: {_registryIndex: number?} | any): boolean
	if not t.table(CastToRegister) then
		Logger:Warn("Register: CastToRegister must be a table")
		return false
	end
	-- A cast that already has _registryIndex set was previously registered and
	-- never properly removed before re-registration was attempted. This is a
	-- logic error in the caller. Silently overwriting the existing index would
	-- produce an orphaned slot in _ActiveCasts at the old index — that slot would
	-- point to the cast but the cast's _registryIndex would point elsewhere,
	-- making it impossible to remove via the normal O(1) swap-remove path.
	if CastToRegister._registryIndex then
		Logger:Warn("Register: cast already registered")
		return false
	end

	-- Append to the end of the array. The new index is (#ActiveCasts + 1) because
	-- the cast has not been inserted yet at this point — the count reflects the
	-- current length before insertion. Storing this index on the cast now is what
	-- makes Remove()'s O(1) jump-to-slot approach work.
	local ActiveCasts   = Solver._ActiveCasts
	local RegistryIndex = #ActiveCasts + 1
	CastToRegister._registryIndex    = RegistryIndex
	ActiveCasts[RegistryIndex]       = CastToRegister
	return true
end

--[=[
    Remove

    Description:
        Removes a VetraCast from the solver instance's _ActiveCasts array using
        the O(1) swap-remove pattern. The element at the removal slot is
        overwritten with the last element in the array, then the array is shortened
        by one. This maintains array density (no holes) without shifting any
        elements, regardless of the array's current length.

        After the swap, the moved element's _registryIndex is immediately updated
        to reflect its new position. If this update were skipped, the moved element
        would carry a stale index pointing to its old slot. The next Remove() call
        on that element would then read the stale index, attempt to access a slot
        that may now contain a different cast, and corrupt the registry.

        The removed cast's _registryIndex is set to nil after removal to mark it
        as unregistered. This prevents accidental re-use of a stale index and
        makes re-registration attempts detectable by Register().

    Parameters:
        Solver: Vetra
            The solver instance whose _ActiveCasts array the cast is removed from.

        CastToRemove: { _registryIndex: number? }
            The VetraCast to remove. Must have been registered via Register().
            A missing _registryIndex means the cast was never registered or was
            already removed — both indicate a caller logic error.

    Returns:
        boolean
            True on success. False if any precondition fails: non-table input,
            empty registry, or missing _registryIndex.

    Notes:
        Interaction with _StepProjectile's iteration order:

        _StepProjectile iterates _ActiveCasts from index 1 to ActiveCount
        (snapshotted before the loop) in ascending order. When a cast at index I
        is removed and replaced by the cast from the last occupied index N:
            • The moved cast now occupies index I, which is less than N.
            • The iteration cursor advances from I toward N.
            • Index I will NOT be revisited — the cursor has already passed it.
            • Therefore the moved cast (now at I) WILL be processed later in the
              same iteration, at the position it was moved to.
            • No cast is ever skipped (the moved cast is visited at its new index).
            • No cast is ever processed twice (no previously-visited index is revisited).

        The edge case where the cast to remove is already at the last index
        is handled explicitly. In that case, the "last element" is the element
        being removed itself. Performing the swap would write it back to its own
        slot, then the array shrink (setting ActiveCasts[LastIndex] = nil) would
        delete it — correctly removing it. However, the index update step
        (LastRegisteredCast._registryIndex = RemoveIndex) would be a no-op writing
        the same value back. The explicit short-circuit below is equivalent but
        avoids the redundant write.
]=]
local function Remove(Solver: Vetra, CastToRemove: {_registryIndex: number?} | any): boolean
	if not t.table(CastToRemove) then
		Logger:Warn("Remove: CastToRemove must be a table")
		return false
	end

	local ActiveCasts = Solver._ActiveCasts
	if #ActiveCasts == 0 then
		Logger:Warn("Remove: no active casts to remove from")
		return false
	end
	if not CastToRemove._registryIndex then
		Logger:Warn("Remove: cast has no _registryIndex — was it registered?")
		return false
	end

	--[[
	    Swap-remove invariant: after this operation completes, the array must
	    satisfy all of the following:
	        a) Dense — no nil holes between index 1 and the new last index.
	        b) Correct — every remaining element's _registryIndex equals its
	           current array position.
	        c) Compact — the array length decreases by exactly one.

	    These properties are maintained by the four-step operation below:
	        1. Write the last element into the removal slot.
	        2. Update the moved element's _registryIndex to the new slot index.
	        3. Nil the last slot to shrink the array.
	        4. Nil the removed cast's _registryIndex to mark it as unregistered.
	]]
	local RemoveIndex        = CastToRemove._registryIndex
	local LastIndex          = #ActiveCasts
	local LastRegisteredCast = ActiveCasts[LastIndex]

	-- Short-circuit: the element to remove is already the last in the array.
	-- No swap is needed — just shrink the array by setting the last slot to nil
	-- and clear the removed cast's index. Skipping the swap avoids a redundant
	-- self-write to _registryIndex before it is immediately cleared.
	if RemoveIndex == LastIndex then
		ActiveCasts[LastIndex]       = nil
		CastToRemove._registryIndex  = nil
		return true
	end

	-- General case: overwrite the removal slot with the last element, then
	-- update the moved element's _registryIndex to reflect its new position,
	-- shrink the array by one, and clear the removed cast's index.
	ActiveCasts[RemoveIndex]              = LastRegisteredCast
	LastRegisteredCast._registryIndex     = RemoveIndex
	ActiveCasts[LastIndex]                = nil
	CastToRemove._registryIndex           = nil
	return true
end

-- ─── Termination ─────────────────────────────────────────────────────────────

--[=[
    Terminate

    Description:
        Fully shuts down a cast by executing a sequence of cleanup operations:
        marking the cast dead, releasing pooled resources, destroying cosmetic
        objects, severing the bidirectional context map, and removing the cast
        from the active registry.

        The order of these steps is not arbitrary — each step creates preconditions
        for the steps that follow, and executing them out of order would produce
        resource leaks or use-after-free bugs.

        Step 1 — Mark Cast.Alive = false FIRST:
            Any subsequent step in this function may invoke code that has a
            reference to this cast (e.g. a signal handler that calls
            context:Terminate(), or a coroutine that resumes inside a signal
            emission). If those paths see Alive = true, they would attempt to
            terminate the cast again, starting a second concurrent termination
            sequence. Marking Alive = false at the top of the function makes
            termination idempotent: any re-entrant call checks this flag
            immediately and returns without action.

        Step 2 — Reset and release RaycastParams:
            The pierce system appends instances to the pooled RaycastParams
            filter list as the bullet travels. Before returning the params
            object to the pool, the filter list must be reset to the original
            snapshot (OriginalFilter, frozen in Fire()) so the next cast that
            acquires these params receives a clean filter state. Without this
            reset, the next bullet to use these params would inherit the previous
            cast's accumulated pierce-exclusion list and fail to collide with
            those instances.

        Step 3 — Destroy the cosmetic bullet:
            The cosmetic Instance is destroyed before the BulletContext is
            invalidated. This ordering allows any OnTerminated signal handler
            to safely read the context's last position and velocity for terminal
            VFX placement (e.g. a hit spark at the impact point). If the context
            were invalidated first, an OnTerminated handler would be working with
            stale data.

        Step 4 — Sever the bidirectional context map:
            Both directions of the cast↔context map must be cleared simultaneously.
            Clearing only one direction would leave a dangling reference: the
            surviving direction would hold a strong reference to a dead object,
            preventing the GC from reclaiming it and creating a potential
            use-after-free if any code later resolves that reference. Both
            directions use the solver instance's own maps (not module-level tables)
            so this step only affects this solver's mappings.

        Step 5 — Remove from Solver._ActiveCasts:
            The cast is removed from the active iteration array last. At this
            point _registryIndex is still valid (nothing above has mutated it),
            so Remove() can perform its O(1) swap-remove correctly. If Remove()
            were called earlier, the vacated slot might be immediately overwritten
            by a new Register() call before the context cleanup in step 4 is
            complete, creating a window where two casts share the same array slot.

    Parameters:
        Solver: Vetra
            The solver instance that owns this cast. Required to access the
            per-instance context maps (_CastToBulletContext, _BulletContextToCast)
            and the active registry.

        Cast: VetraCast
            The cast to terminate. If Cast.Alive is already false, this function
            returns immediately. Termination is idempotent by design so all callers
            (SimulateCast, context:Terminate(), corner-trap detection) can call this
            without guarding against double-invocation themselves.
]=]
local function Terminate(Solver: Vetra, Cast: VetraCast)
	-- Idempotency guard. If a signal handler or coroutine calls context:Terminate()
	-- while the solver is already in the process of terminating this cast (e.g. a
	-- terminal hit fires OnHit, the handler calls Terminate, then SimulateCast's
	-- own post-hit Terminate call runs), the second invocation is silently ignored.
	-- Without this guard, the second call would attempt to release already-released
	-- params and remove a cast that is no longer in the registry.
	if not Cast.Alive then return end

	-- Mark dead FIRST. Any code path below that can trigger re-entrant execution
	-- (signal handlers, coroutine.resume inside a signal) will see Alive = false
	-- and return immediately. This invariant makes all subsequent cleanup steps
	-- safe to execute without additional re-entrancy guards.
	Cast.Alive = false

	-- Reset the pooled RaycastParams filter to the snapshot taken at Fire() time.
	-- The pierce system appends instances to this filter as the bullet travels.
	-- Without resetting, the next cast that acquires these params from the pool
	-- would receive a filter contaminated with the previous cast's pierce exclusions,
	-- causing bullets to pass through objects they should collide with.
	Cast.Behavior.RaycastParams.FilterDescendantsInstances =
		table.clone(Cast.Behavior.OriginalFilter)

	-- Return the params to the pool. If Release() is not called here, the pool
	-- gradually depletes and Fire() falls back to non-pooled params, increasing
	-- per-fire allocation and GC pressure. At high fire rates this fallback
	-- compounds into measurable frame time spikes.
	ParamsPooler.Release(Cast.Behavior.RaycastParams)

	-- Destroy the cosmetic bullet Instance. Nilling the reference after destruction
	-- releases the table's strong reference to the Instance, allowing the GC to
	-- collect it immediately rather than at the next cycle.
	if Cast.Runtime.CosmeticBulletObject then
		Cast.Runtime.CosmeticBulletObject:Destroy()
		Cast.Runtime.CosmeticBulletObject = nil
	end

	-- Sever both directions of the bidirectional context map atomically.
	-- Clearing only one direction would leave a dangling half-reference:
	-- the surviving direction would hold a strong pointer to a dead object and
	-- prevent GC collection, potentially causing use-after-free if code later
	-- resolves that surviving reference.
	local LinkedContext = Solver._CastToBulletContext[Cast]
	if LinkedContext then
		-- Notify the BulletContext that its underlying cast has ended. The context
		-- marks itself dead and clears the injected Terminate closure in its
		-- __solverData, so future calls to context:Terminate() become no-ops
		-- rather than invoking this function on an already-gone cast.
		if LinkedContext.Alive then
			LinkedContext:Terminate()
		end
		Solver._BulletContextToCast[LinkedContext] = nil
		Solver._CastToBulletContext[Cast]          = nil
	end

	-- Remove from _ActiveCasts last. _registryIndex is still valid at this point;
	-- none of the steps above have modified it. After this call, the slot is either
	-- nilled (last element) or occupied by the cast swapped in from the end.
	Remove(Solver, Cast)
end

-- ─── Signal Emission Helpers ─────────────────────────────────────────────────

--[[
    Each of these helpers centralises two concerns shared by every signal
    emission site in the module:

    1. BulletContext lookup:
        Every signal passes the BulletContext as its first argument so consumers
        can identify the cast and access its UserData and current position/velocity.
        Performing the Solver._CastToBulletContext[Cast] lookup inline at each of
        the dozen call sites would scatter the "is this context still live?" nil
        guard everywhere. Centralising here means that guard exists in one place.

    2. Context state synchronisation (_UpdateState):
        Consumers that poll context.Position or context.Velocity inside a signal
        handler expect values that reflect the bullet's state at the moment the
        event fired. Without an explicit _UpdateState call before the signal fires,
        those fields would hold values from the previous frame. Updating here
        ensures the context is always current at signal emission time, regardless
        of which call site triggered it.

    Every helper takes Solver as its first argument because both the signal
    objects and the _CastToBulletContext map are per-instance fields. The
    nil-context early return in each helper handles the edge case where
    Terminate() has already severed _CastToBulletContext before a second signal
    attempt fires in the same frame (e.g. a corner-trap termination followed
    immediately by an OnTerminated emission).

    ── Signal contracts ─────────────────────────────────────────────────────────

        OnHit (Context, Result: RaycastResult?, Velocity: Vector3):
            Fired when the bullet reaches a terminal state. Result is the
            RaycastResult at the impact surface, or nil if the bullet expired
            by distance or minimum speed. Consumers distinguish physical impact
            from silent expiry by testing `Result ~= nil`.

        OnTravel (Context, Position: Vector3, Velocity: Vector3):
            Fired every frame as the bullet advances its position. Used for trail
            particle effects, sound attenuation curves, or any system that needs
            continuous per-frame position data. OnTravel uses Fire (not FireSafe)
            because it fires on every active bullet every frame — FireSafe's
            deep-copy overhead is unacceptable on this hot path. Signal handler
            errors inside OnTravel will be unhandled; consumers must not throw.

        OnPierce (Context, Result: RaycastResult, Velocity: Vector3, PierceCount: number):
            Fired each time the bullet successfully pierces an instance. PierceCount
            is the cumulative total including the current pierce, incremented before
            the signal fires so handlers see the already-updated count.

        OnBounce (Context, Result: RaycastResult, Velocity: Vector3, BounceCount: number):
            Fired each time the bullet bounces off a surface. BounceCount is
            cumulative and incremented before firing, consistent with OnPierce.

        OnTerminated (Context):
            Fired unconditionally just before the cast is removed from the registry,
            regardless of the termination reason (impact, distance expiry, speed
            expiry, corner trap). This is the reliable one-time cleanup hook —
            consumers should use it for impact sounds, returning bullet visuals
            to an object pool, or resolving pending hit confirmations.
]]

local function FireOnHit(Solver: Vetra, Cast: VetraCast, HitResult: RaycastResult?, HitVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	-- Snap the context position to the hit point before firing. Consumers reading
	-- context.Position inside their OnHit handler will get the surface contact
	-- position, not the bullet's interpolated position from the previous frame.
	-- This ensures that impact VFX spawned at context.Position appear exactly
	-- on the surface rather than slightly behind it.
	if HitResult then
		Context:_UpdateState(HitResult.Position, HitVelocity, Cast.Runtime.DistanceCovered)
	end
	Solver.Signals.OnHit:FireSafe(Context, HitResult, HitVelocity)
end
local function FireOnPreBounce(Solver, Cast, HitResult, Velocity)
    local Context = Solver._CastToBulletContext[Cast]
    if not Context then return {} end
    local MutableData = {
        Normal           = HitResult.Normal,
        IncomingVelocity = Velocity,
    }
    Solver.Signals.OnPreBounce:FireSafe(Context, HitResult, Velocity, MutableData)
    return MutableData
end

local function FireOnMidBounce(Solver, Cast, HitResult, PostBounceVelocity)
    local Context = Solver._CastToBulletContext[Cast]
    if not Context then return {} end
    local MutableData = {
        PostBounceVelocity = PostBounceVelocity,
        Restitution        = Cast.Behavior.Restitution,
        NormalPerturbation = Cast.Behavior.NormalPerturbation,
    }
    Solver.Signals.OnMidBounce:FireSafe(Context, HitResult, PostBounceVelocity, MutableData)
    return MutableData
end

local function FireOnPrePenetration(Solver, Cast, HitResult, Velocity)
    local Context = Solver._CastToBulletContext[Cast]
    if not Context then return {} end
    local MutableData = {
        EntryVelocity     = nil, -- nil means use current velocity unchanged
        MaxPierceOverride = nil, -- nil means use Behavior.MaxPierceCount
    }
    Solver.Signals.OnPrePenetration:FireSafe(Context, HitResult, Velocity, MutableData)
    return MutableData
end

local function FireOnMidPenetration(Solver, Cast, HitResult, Velocity)
    local Context = Solver._CastToBulletContext[Cast]
    if not Context then return {} end
    local MutableData = {
        SpeedRetention = Cast.Behavior.PenetrationSpeedRetention,
        ExitVelocity   = nil, -- nil means let Vetra compute it
    }
    Solver.Signals.OnMidPenetration:FireSafe(Context, HitResult, Velocity, MutableData)
    return MutableData
end
local function FireOnTravel(Solver: Vetra, Cast: VetraCast, TravelPosition: Vector3, TravelVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	-- Update the context every frame. External code polling context.Position
	-- between signal connections (e.g. a distance-based audio system that reads
	-- bullet position from a stored context reference) always sees the current
	-- frame's position without requiring an explicit OnTravel subscription.
	Context:_UpdateState(TravelPosition, TravelVelocity, Cast.Runtime.DistanceCovered)
	-- Use Fire rather than FireSafe. OnTravel fires for every active bullet every
	-- frame. FireSafe performs deep copies to isolate handler errors, which adds
	-- non-trivial overhead at high bullet counts. OnTravel consumers are expected
	-- not to throw; if they do, the error will be unhandled rather than isolated.
	Solver.Signals.OnTravel:Fire(Context, TravelPosition, TravelVelocity)
end

local function FireOnPierce(Solver: Vetra, Cast: VetraCast, PierceResult: RaycastResult, PierceVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	-- Increment PierceCount BEFORE firing the signal. The count argument on the
	-- signal represents the total including the current pierce, so a handler
	-- checking "is this the third pierce?" can compare directly against 3 without
	-- adding one. This convention matches OnBounce and ensures consistent semantics
	-- across both counter-carrying signals.
	Cast.Runtime.PierceCount += 1
	Context:_UpdateState(PierceResult.Position, PierceVelocity, Cast.Runtime.DistanceCovered)
	Solver.Signals.OnPierce:FireSafe(Context, PierceResult, PierceVelocity, Cast.Runtime.PierceCount)
end

local function FireOnBounce(Solver: Vetra, Cast: VetraCast, BounceResult: RaycastResult, PostBounceVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	-- Increment BounceCount BEFORE firing the signal for the same reason as
	-- FireOnPierce — consumers receive the updated count so they do not need to
	-- add one themselves when checking lifetime bounce budgets.
	Cast.Runtime.BounceCount += 1
	Context:_UpdateState(BounceResult.Position, PostBounceVelocity, Cast.Runtime.DistanceCovered)
	Solver.Signals.OnBounce:FireSafe(Context, BounceResult, PostBounceVelocity, Cast.Runtime.BounceCount)
end

local function FireOnTerminated(Solver: Vetra, Cast: VetraCast)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTerminated:FireSafe(Context)
end

-- ─── Corner Trap Detection ───────────────────────────────────────────────────

--[=[
    IsCornerTrap

    Description:
        Detects whether a bullet has entered a geometric configuration that would
        cause it to bounce indefinitely between two or more surfaces without making
        meaningful forward progress. This degenerate condition arises in concave
        geometry — V-grooves, inside corners, narrow slots, procedurally generated
        micro-cracks — where each reflection from one surface directs the bullet
        straight at the opposing surface.

        Without this detection, such geometry would trigger a bounce chain that
        consumes the entire MaxBounces budget in a single frame, producing a
        visible freeze (the bullet stalls inside the corner geometry) and wasting
        the frame's simulation budget on a bullet that will never escape. In the
        worst case with MaxBouncesPerFrame = 10 and CornerTimeThreshold = 0, a
        bullet could perform hundreds of tight reflections in one simulation tick.

        Three independent heuristic guards are evaluated in order from cheapest
        (scalar comparison) to most expensive (vector distance). Any single guard
        firing is sufficient to declare a corner trap; all three need not be
        satisfied simultaneously. The threshold values in DEFAULT_BEHAVIOR are
        chosen to be permissive enough to avoid false positives on intentional
        tight-bounce geometry while still catching all practical degenerate cases.

        Guard 1 — Temporal proximity (cheapest: single scalar comparison):
            If the interval between the current bounce and the most recent previous
            bounce is shorter than CornerTimeThreshold (default 0.002 seconds),
            the bullet is bouncing faster than any physically plausible surface
            separation would allow. At 60Hz, 0.002 seconds is one-eighth of a frame
            — no legitimate game geometry produces valid bounces this close together
            in time. A false positive here would require two genuine collisions to
            occur within 2ms of each other, which is impossible in a real 60Hz
            simulation step.

        Guard 2 — Normal opposition (medium cost: dot product):
            If the current surface normal and the previously stored bounce normal
            point nearly opposite each other (dot product < CornerNormalDotThreshold,
            default -0.85, corresponding to ~148° between the normals), the two
            surfaces are nearly face-to-face. A bullet bouncing between the left and
            right walls of a square groove would produce normals with a dot product
            approaching -1.0. The -0.85 threshold accommodates non-axis-aligned
            surfaces while rejecting geometry where the opposing angle is too narrow
            for any trajectory to escape. This guard is only evaluated if a previous
            bounce normal has been recorded (LastBounceNormal ~= ZERO_VECTOR),
            because comparing against the zero-vector sentinel would produce a dot
            of 0.0 that never triggers the guard regardless of the current normal.

        Guard 3 — Spatial proximity (most expensive: distance computation):
            If the two most recent bounce contact points are less than
            CornerDisplacementThreshold studs apart (default 0.5), the bullet is
            making negligible forward progress between bounces. This catches small
            pits and procedurally generated terrain irregularities where the surface
            normals may not be perfectly opposing (Guard 2 would miss them) but the
            bullet is clearly oscillating within a tiny spatial region. This guard is
            only evaluated if a previous bounce position has been recorded.

        This function reads only Cast and Behavior state. It has no side effects
        and requires no Solver argument.

    Parameters:
        Cast: VetraCast
            The cast being evaluated. LastBounceTime, LastBounceNormal, and
            LastBouncePosition are read from Cast.Runtime.

        SurfaceNormal: Vector3
            The outward-facing unit normal of the surface just contacted. Used for
            Guard 2's dot product against the previously stored bounce normal.

        ContactPosition: Vector3
            World-space contact point of the current bounce. Used for Guard 3's
            displacement measurement against the previously stored bounce position.

    Returns:
        boolean
            True if any guard fires, indicating the bullet is trapped. The caller
            (SimulateCast) should terminate the cast rather than reflecting the
            velocity and continuing simulation.

    Notes:
        This is a heuristic and will occasionally produce false positives in
        intentionally tight geometry (e.g. a pinball machine, a narrow pipe
        interior). This is an accepted engineering tradeoff: an infinite bounce
        loop consuming all frame budget is a far worse outcome than a single
        premature termination in edge-case geometry. If your game deliberately
        requires bullets to navigate tight concave spaces, reduce the thresholds
        or increase MaxBounces to push the guard windows outside your geometry's
        operating range.
]=]
local function IsCornerTrap(Cast: VetraCast, SurfaceNormal: Vector3, ContactPosition: Vector3): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	-- Guard 1: Temporal proximity. OsClock is cached as a module-level upvalue
	-- to avoid a global hash lookup on this frequently-called check. If the
	-- interval since the last bounce is below CornerTimeThreshold, the two bounces
	-- occurred so close in time that no real physical geometry could have produced
	-- both of them legitimately within a single simulation step.
	local TimeSinceLastBounce      = OsClock() - Runtime.LastBounceTime
	local IsBounceIntervalTooShort = TimeSinceLastBounce < Behavior.CornerTimeThreshold
	if IsBounceIntervalTooShort then return true end

	-- Guard 2: Normal opposition. The dot product of two unit vectors equals
	-- cos(angle_between_them). A value of -1.0 means the normals are exactly
	-- anti-parallel (surfaces are face-to-face, 180° apart). The threshold of
	-- -0.85 corresponds to normals that are at least ~148° apart — permissive
	-- enough to tolerate non-axis-aligned corners while reliably catching all
	-- practical concave trap geometries. The guard is skipped on the first bounce
	-- (when LastBounceNormal is still ZERO_VECTOR) to avoid a false-positive from
	-- comparing a real normal against the zero-vector sentinel.
	local HasPreviousBounceNormal = Runtime.LastBounceNormal ~= ZERO_VECTOR
	if HasPreviousBounceNormal then
		local NormalDotProduct   = SurfaceNormal:Dot(Runtime.LastBounceNormal)
		local NormalsAreOpposing = NormalDotProduct < Behavior.CornerNormalDotThreshold
		if NormalsAreOpposing then return true end
	end

	-- Guard 3: Spatial proximity. A bullet making genuine forward progress through
	-- geometry will have non-trivial displacement between successive contact points.
	-- A displacement below CornerDisplacementThreshold (default 0.5 studs) indicates
	-- the bullet is oscillating in a very confined region — it is not escaping the
	-- corner geometry. Like Guard 2, this check is skipped on the first bounce to
	-- avoid comparing a real contact point against the ZERO_VECTOR sentinel, which
	-- represents the world origin and would produce a meaningless distance.
	local HasPreviousBouncePosition = Runtime.LastBouncePosition ~= ZERO_VECTOR
	if HasPreviousBouncePosition then
		local BounceDisplacement     = (ContactPosition - Runtime.LastBouncePosition).Magnitude
		local IsDisplacementTooSmall = BounceDisplacement < Behavior.CornerDisplacementThreshold
		if IsDisplacementTooSmall then return true end
	end

	return false
end

-- ─── Bounce Resolution ───────────────────────────────────────────────────────

--[=[
    ResolveBounce

    Description:
        Computes the post-bounce velocity vector from the bullet's incoming
        velocity and the surface normal at the contact point.

        ── Core Reflection Mathematics ──────────────────────────────────────────

        The reflection formula used is the standard geometric mirror reflection:

            V_reflected = V - 2 * (V · N) * N

        Derivation:
            (V · N) is the scalar projection of V onto the surface normal N — the
            signed component of the velocity directed into (or away from) the surface.
            Multiplying by N converts it back to a vector along the normal direction.
            Subtracting twice this normal component from V cancels the inward velocity
            and replaces it with an equal outward component, while leaving the tangential
            (surface-parallel) component of V entirely unchanged. The result is a perfect
            mirror reflection of V about the surface plane, which is the physically
            correct behaviour for elastic reflection from a flat surface.

        ── Energy Dissipation ────────────────────────────────────────────────────

        The reflected velocity is scaled by (Restitution × MaterialRestitutionMultiplier).
        Restitution < 1.0 models an inelastic collision where kinetic energy is lost to
        material deformation, heat, and sound on each bounce. This scaling is applied
        uniformly to all velocity components — energy is lost proportionally in all
        directions, not selectively. The practical effect is that bullets with
        Restitution < 1.0 will naturally converge toward zero speed after a finite
        number of bounces, eventually triggering the MinSpeed termination condition.

        Per-material restitution (the MaterialRestitution lookup table on Behavior)
        provides a per-surface energy-absorption multiplier. This allows a rubber floor
        and a concrete wall to coexist in the same scene with different bounce energy
        profiles, without requiring separate Behavior tables for each surface type.
        Any material not in the table uses a multiplier of 1.0 (no modification to
        the base Restitution coefficient).

        ── Normal Perturbation ───────────────────────────────────────────────────

        When NormalPerturbation > 0, the reflection is computed against a randomly
        perturbed surface normal rather than the clean geometric normal. A uniform
        random direction vector is scaled by NormalPerturbation and added to the
        surface normal; the result is re-normalised. This perturbed normal is then
        used for the full reflection + restitution computation. The perturbed result
        entirely replaces the clean reflection — both are never combined, because
        applying a clean reflection and then a perturbed reflection would produce a
        double-reflection with no physical interpretation. The perturbation path and
        the clean path are mutually exclusive.

        ResolveBounce reads only Cast and HitResult. It has no side effects beyond
        computing its return value and requires no Solver argument.

    Parameters:
        Cast: VetraCast
            The cast whose bounce is being resolved. Reads Behavior.Restitution,
            Behavior.MaterialRestitution, and Behavior.NormalPerturbation.

        HitResult: RaycastResult
            The raycast result at the contact point. Provides the geometric surface
            normal for the reflection formula and the material enum for the per-
            material restitution lookup.

        IncomingVelocity: Vector3
            The bullet's velocity at the exact moment of contact. This should be
            the analytically computed velocity at the hit time (VelocityAtTime at
            ElapsedAfterAdvance), not the frame-start velocity, to ensure the
            reflection angle is computed from the bullet's true impact direction
            rather than an approximation that may lag by up to one full frame delta.

    Returns:
        Vector3
            The post-bounce velocity vector with energy dissipation already applied.
            This becomes InitialVelocity for the new trajectory segment opened in
            SimulateCast. The caller does not need to scale it further.

    Notes:
        If Restitution = 0.0, the returned vector has zero magnitude. SimulateCast
        does not special-case this here — the IsBelowMinSpeed check at the start
        of the next frame will terminate the cast cleanly. Handling this case inside
        ResolveBounce would require either duplicating termination logic or returning
        a sentinel, both of which are worse than letting the normal termination path
        handle it one frame later.
]=]
local function ResolveBounce(Cast: VetraCast, HitResult: RaycastResult, IncomingVelocity: Vector3, OverrideNormal: Vector3?): Vector3
	local Behavior      = Cast.Behavior
	local SurfaceNormal = OverrideNormal or HitResult.Normal

	-- ── Mirror Reflection ─────────────────────────────────────────────────────
	-- Standard geometric reflection about the surface plane:
	--
	--     V_reflected = V - 2 * (V · N) * N
	--
	-- (V · N) is the scalar projection of the incoming velocity onto the normal —
	-- the signed magnitude of the velocity component directed into the surface.
	-- Multiplying by N converts it back into a vector along the normal direction.
	-- Subtracting twice this component from V cancels the inward velocity and
	-- replaces it with an equal outward velocity, while leaving the tangential
	-- (surface-parallel) component completely unchanged. The result is a perfect
	-- elastic reflection for a flat surface and a point-mass projectile.
	--
	-- Note: this function returns the PURE reflection with no energy scaling.
	-- Restitution is intentionally NOT applied here. It is applied in SimulateCast
	-- after OnMidBounce fires, so consumers can override the restitution coefficient
	-- per-bounce via MidBounceData.Restitution without needing to reconstruct the
	-- reflection themselves. Applying restitution here and again in SimulateCast
	-- would double-scale the velocity, causing every bounce to lose far more energy
	-- than intended and making the Restitution value non-intuitive to configure.
	--
	-- MaterialRestitution is also NOT applied here for the same reason — all energy
	-- scaling is owned by SimulateCast in a single location so the math is auditable
	-- in one place and cannot diverge between the two functions.
	return IncomingVelocity - 2 * IncomingVelocity:Dot(EffectiveNormal) * EffectiveNormal
end

-- ─── Pierce Resolution ───────────────────────────────────────────────────────

--[=[
    ResolvePierce

    Description:
        Handles a pierce chain initiated by the first confirmed pierceable hit.
        By the time this function is called, SimulateCast has already determined
        that the first surface qualifies for piercing (speed threshold, angle bias,
        pierce count limit, and CanPierceFunction callback all confirmed). This
        function takes over to advance the chain: it casts successive rays along
        the same direction through the geometry, asking CanPierceFunction about
        each new hit, until the chain ends either at a non-pierceable (solid) surface
        or in open space with no further hits.

        ── Filter Mutation Strategy ──────────────────────────────────────────────

        Once an instance is pierced, the active RaycastParams filter must be
        modified to prevent the next ray in the chain from immediately re-detecting
        the same instance at near-zero distance. The mutation approach depends on
        the filter mode:

            Exclude mode (FilterType = Exclude):
                The pierced instance is appended to the filter list. The Roblox
                raycast API skips any instance present in an Exclude filter list,
                so adding it here tells the next cast to pass through it.

            Include mode (FilterType = Include):
                The pierced instance is removed from the filter list using a
                swap-remove. The Roblox raycast API only tests instances present
                in an Include filter list, so removing it excludes it from all
                future detection. Swap-remove (O(1)) is used rather than
                table.remove (O(n)) because filter lists on heavily-piercing
                bullets can be large.

        These filter mutations are intentionally permanent for the cast's lifetime.
        An instance pierced once by a given cast will never be re-detected by that
        cast, even if the trajectory curves back toward it under gravity. This is a
        deliberate game-design constraint: allowing a curved trajectory to re-pierce
        the same instance would produce duplicate damage events that are surprising
        to players and difficult for weapon code to deduplicate correctly.

        ── Speed Attenuation ─────────────────────────────────────────────────────

        Each pierce in the chain reduces the bullet's speed by multiplying the
        velocity magnitude by PenetrationSpeedRetention. The direction unit vector
        is preserved unchanged — we model penetration as a straight-line deceleration
        (the bullet slows but does not deflect). The attenuated velocity is passed
        to the subsequent CanPierceFunction call, allowing that callback to make
        speed-aware decisions (e.g. stopping the chain when speed drops below a
        threshold that represents insufficient energy to pierce further).

    Parameters:
        Solver: Vetra
            The solver instance, required for FireOnPierce and
            _CastToBulletContext access.

        Cast: VetraCast
            The cast performing the pierce. Behavior is read for configuration;
            Runtime.PiercedInstances and Runtime.PierceCount are mutated.

        InitialPierceResult: RaycastResult
            The hit result that initiated the chain — the first surface that
            CanPierceFunction approved in SimulateCast.

        PierceOrigin: Vector3
            World-space origin of the triggering raycast. Not used directly
            inside the chain loop but included for completeness in case
            chain-start logic is added in the future.

        RayDirection: Vector3
            Direction vector of the original raycast. All subsequent pierce raycasts
            in the chain use this same direction, maintaining the bullet's straight
            path through the geometry.

        CurrentVelocity: Vector3
            Bullet velocity at the first pierce contact. Mutated locally per pierce
            (speed attenuated) without affecting the caller's variable.

    Returns:
        (boolean, RaycastResult?, Vector3?)
            [1]: true if the chain ended at a solid (non-pierceable) surface.
            [2]: The solid hit RaycastResult if [1] is true, else nil.
            [3]: Final attenuated velocity after all pierces in the chain.

    Notes:
        A hard iteration cap of 100 guards against degenerate geometry (e.g. two
        zero-thickness overlapping meshes where each reports the other as a new hit)
        that would otherwise produce an infinite loop. In practice, MaxPierceCount
        is checked inside the loop and terminates the chain far before 100 iterations.

        RayDirection is validated to be non-degenerate before the loop begins.
        A near-zero direction vector would cause workspace:Raycast to either throw
        or return erratic results; catching it before the loop gives a clear
        diagnostic and avoids corrupting the chain state.
]=]
local function ResolvePierce(
	Solver: Vetra,
	Cast: VetraCast,
	InitialPierceResult: RaycastResult,
	PierceOrigin: Vector3,
	RayDirection: Vector3,
	CurrentVelocity: Vector3
): (boolean, RaycastResult?, Vector3?)

	-- Validate the ray direction before entering the loop. A near-zero direction
	-- vector would cause workspace:Raycast to behave unpredictably or throw.
	-- Checking once before the loop is cheaper than checking inside each iteration
	-- and gives a clear failure point for debugging.
	if RayDirection.Magnitude < 1e-6 then
		Logger:Warn("ResolvePierce: RayDirection is zero — skipping")
		return false, nil, nil
	end

	local Runtime           = Cast.Runtime
	local Behavior          = Cast.Behavior
	local RayParams         = Behavior.RaycastParams
	local CanPierceCallback = Behavior.CanPierceFunction


	--[[
		OnPrePenetration fires once before the chain begins. The consumer receives
		a mutable table with two fields:

			EntryVelocity: Vector3?
				If provided and valid, replaces CurrentVelocity at the start of the
				chain. Every pierce in the chain — including the first
				OnMidPenetration call — inherits this velocity as its starting speed.
				Nil means the chain runs on the velocity that reached this surface
				unchanged.

			MaxPierceOverride: number?
				If provided, caps the pierce budget for this chain to a value in
				[1, Behavior.MaxPierceCount]. Values outside that range are rejected
				with a warning and Behavior.MaxPierceCount is used instead. Nil means
				the chain uses Behavior.MaxPierceCount as normal.

		The signal fires before any filter mutation or instance recording occurs,
		so a chain that does nothing in OnPrePenetration leaves all state unmodified.
	]]
	local PrePierceData = FireOnPrePenetration(Solver, Cast, InitialPierceResult, CurrentVelocity)

	-- Apply EntryVelocity override. Pre owns the inputs to the chain, so this
	-- velocity is what every subsequent pierce in the chain inherits as its
	-- starting speed — including the first OnMidPenetration call. An invalid
	-- (NaN/inf) value is silently ignored so the chain still runs on the
	-- original velocity rather than producing corrupted kinematic state.
	if PrePierceData.EntryVelocity and t.Vector3(PrePierceData.EntryVelocity) then
		CurrentVelocity = PrePierceData.EntryVelocity
	end

	-- Resolve the effective pierce budget for this chain. A numeric override
	-- in [1, Behavior.MaxPierceCount] is accepted; anything outside that range
	-- is rejected with a warning and the Behavior default is used instead.
	-- Allowing a value above MaxPierceCount would silently exceed the configured
	-- budget; allowing zero or negative would make the loop condition
	-- (PierceCount >= EffectiveMaxPierceCount) true before the first iteration
	-- and produce a degenerate empty chain.
	local EffectiveMaxPierceCount = Behavior.MaxPierceCount
	if PrePierceData.MaxPierceOverride ~= nil then
		local Override = PrePierceData.MaxPierceOverride
		if type(Override) == "number" and Override >= 1 and Override <= Behavior.MaxPierceCount then
			EffectiveMaxPierceCount = math.floor(Override)
		else
			Logger:Warn(string.format(
				"ResolvePierce: MaxPierceOverride must be an integer in [1, %d] — using Behavior.MaxPierceCount",
				Behavior.MaxPierceCount
			))
		end
	end

	--[[
	    The filter mutations performed inside this loop are permanent side effects
	    on the cast's pooled RaycastParams for the duration of the cast's lifetime.
	    A bullet that pierced a wall earlier in its trajectory will never re-detect
	    that wall, even if gravity curves the path back toward it. If re-detection
	    of previously pierced instances is needed (e.g. a boomerang projectile),
	    the filter state would need to be snapshot and restored around specific
	    trajectory segments — this is not currently supported by the module.
	]]

	-- Cache the filter mode outside the loop. FilterType does not change during
	-- a cast's lifetime, so reading it once and branching on a local boolean is
	-- more efficient than re-reading the Enum property from the Roblox object on
	-- every iteration of a potentially long pierce chain.
	local IsExcludeFilter = RayParams.FilterType == Enum.RaycastFilterType.Exclude

	local PierceIterationCount = 0
	local CurrentPierceResult  = InitialPierceResult
	local FoundSolidHit        = false

	while true do
		local PiercedInstance = CurrentPierceResult.Instance

		-- Record the pierced instance in PiercedInstances. SimulateCast consults
		-- this list when processing subsequent raycasts in the same frame to detect
		-- re-encounters via different high-fidelity sub-segment paths. Without this
		-- record, the same instance could be reported as a fresh hit by a later
		-- sub-segment, causing duplicate damage events.
		local PiercedList = Runtime.PiercedInstances
		PiercedList[#PiercedList + 1] = PiercedInstance

		-- Mutate the active filter to exclude this instance from all future raycasts.
		-- For Exclude filters, we append the instance (O(1)). For Include filters,
		-- we swap-remove it (O(n) search, but O(1) removal once found) rather than
		-- using table.remove (O(n) search + O(n) shift) to keep the operation
		-- as fast as possible on large filter lists.
		local CurrentFilterList = RayParams.FilterDescendantsInstances
		if IsExcludeFilter then
			-- Exclude mode: add the just-pierced instance to the list so the next
			-- raycast will skip it entirely. This is a simple O(1) append.
			CurrentFilterList[#CurrentFilterList + 1] = PiercedInstance
		else
			-- Include mode: remove the just-pierced instance from the list so the
			-- next raycast will no longer test it. Swap-remove avoids shifting all
			-- elements after the removed index, which matters for large filter lists.
			local InstanceIndex = table.find(CurrentFilterList, PiercedInstance)
			if InstanceIndex then
				CurrentFilterList[InstanceIndex] = CurrentFilterList[#CurrentFilterList]
				CurrentFilterList[#CurrentFilterList] = nil
			end
		end
		RayParams.FilterDescendantsInstances = CurrentFilterList

		--[[
		    OnMidPenetration fires after filter mutation but before speed retention
		    is applied for this specific pierce. The consumer receives a mutable
		    table with two fields:

		        SpeedRetention: number?
		            Overrides Behavior.PenetrationSpeedRetention for this pierce only.
		            Must be in the range [0, 1]. Values outside this range are rejected
		            and Behavior.PenetrationSpeedRetention is used as a fallback with a
		            warning. This allows per-surface energy absorption without requiring
		            separate Behavior tables — a concrete wall and a wooden door can
		            drain different amounts of kinetic energy within the same cast.

		        ExitVelocity: Vector3?
		            If provided and valid, entirely replaces the computed post-pierce
		            velocity. The direction and magnitude are both taken from this value
		            verbatim — no retention scaling is applied. This is the escape hatch
		            for advanced cases like deflecting penetration, explosive fragmentation
		            direction overrides, or scripted velocity manipulation that retention
		            scaling alone cannot express.

		    Priority: ExitVelocity takes precedence over SpeedRetention. If both are
		    provided, ExitVelocity is used and SpeedRetention is ignored. If neither
		    is provided (both nil), Behavior.PenetrationSpeedRetention is applied as
		    normal — existing casts that do not connect OnMidPenetration are completely
		    unaffected.
		]]
		local MidPierceData = FireOnMidPenetration(Solver, Cast, CurrentPierceResult, CurrentVelocity)

		if MidPierceData.ExitVelocity and t.Vector3(MidPierceData.ExitVelocity) then
			-- Consumer supplied a full velocity override. Use it verbatim — direction
			-- and magnitude are both taken as-is. No retention scaling is applied.
			CurrentVelocity = MidPierceData.ExitVelocity
		else
			local Retention = MidPierceData.SpeedRetention
			if type(Retention) == "number" and Retention >= 0 and Retention <= 1 then
				-- Valid consumer override. Scale speed by the provided retention
				-- coefficient while preserving the direction unit vector unchanged.
				CurrentVelocity = CurrentVelocity.Unit * (CurrentVelocity.Magnitude * Retention)
			elseif Retention ~= nil then
				-- Consumer supplied a retention value but it is outside [0, 1].
				-- A negative retention would reverse the bullet's direction, and a
				-- value above 1 would accelerate it — both are physically incoherent.
				-- Warn and fall back to the Behavior default rather than silently
				-- applying a degenerate value that would corrupt subsequent physics.
				Logger:Warn("OnMidPenetration: SpeedRetention must be in [0, 1] — using Behavior.PenetrationSpeedRetention as fallback")
				local FallbackSpeed = CurrentVelocity.Magnitude * Behavior.PenetrationSpeedRetention
				CurrentVelocity = CurrentVelocity.Unit * FallbackSpeed
			else
				-- Consumer did not touch SpeedRetention. Apply Behavior default normally.
				-- The direction (unit vector) is preserved because we model penetration
				-- as linear deceleration with no deflection. The attenuated velocity is
				-- both passed to the next CanPierceFunction call and carried through to
				-- the OnPierce signal so consumers see the already-reduced speed at
				-- each pierce event.
				local PostPierceSpeed = CurrentVelocity.Magnitude * Behavior.PenetrationSpeedRetention
				CurrentVelocity = CurrentVelocity.Unit * PostPierceSpeed
			end
		end

		-- Fire OnPierce. This also increments PierceCount (inside FireOnPierce),
		-- so the count check on the next line sees the up-to-date value.
		FireOnPierce(Solver, Cast, CurrentPierceResult, CurrentVelocity)

		if Behavior.VisualizeCasts then
			Visualizer.Hit(CFrameNew(CurrentPierceResult.Position), "pierce")
			Visualizer.Normal(CurrentPierceResult.Position, CurrentPierceResult.Normal)
		end

		if Runtime.PierceCount >= EffectiveMaxPierceCount then
			-- Pierce budget exhausted. Stop the chain here — the next surface, if
			-- any, becomes a candidate for terminal impact processing in SimulateCast.
			break
		end

		-- Advance the ray origin past the just-pierced surface by NUDGE along the
		-- travel direction. Without this offset, the next workspace:Raycast() call
		-- would start on the surface plane and could re-detect the same instance
		-- (even though it was just added to the Exclude filter) due to floating-point
		-- imprecision at the exact surface contact point.
		local NextRayOrigin    = CurrentPierceResult.Position + RayDirection.Unit * NUDGE
		local NextPierceResult = workspace:Raycast(NextRayOrigin, RayDirection, RayParams)

		-- No further geometry hit: the chain ends in open space. The bullet continues
		-- flying on its normal trajectory. No terminal event is generated here.
		if NextPierceResult == nil then break end

		PierceIterationCount += 1

		-- Hard iteration safety cap. MaxPierceCount should terminate the chain well
		-- before this limit is reached. This exists as a last resort against degenerate
		-- geometry (e.g. two zero-thickness stacked meshes alternating as new hits in
		-- each iteration) that would otherwise cause the loop to run indefinitely.
		if PierceIterationCount >= 100 then
			Logger:Warn("ResolvePierce: exceeded 100 iterations — possible degenerate geometry")
			break
		end

		-- Query CanPierceFunction for the next hit instance. We pass the attenuated
		-- CurrentVelocity so the callback can gate on speed — e.g. stopping the chain
		-- once the bullet's energy is too low to pierce another surface. The
		-- LinkedContext is passed instead of the raw cast so the callback receives
		-- the public BulletContext API, consistent with how it was set up in Fire().
		local LinkedContext    = Solver._CastToBulletContext[Cast]
		local NextCanBePierced = CanPierceCallback and CanPierceCallback(LinkedContext, NextPierceResult, CurrentVelocity)

		if not NextCanBePierced then
			-- This instance cannot be pierced. The chain ends here and this surface
			-- becomes the solid terminal hit that SimulateCast must resolve as a
			-- definitive impact.
			FoundSolidHit       = true
			CurrentPierceResult = NextPierceResult
			break
		end

		CurrentPierceResult = NextPierceResult
	end

	return FoundSolidHit, CurrentPierceResult, CurrentVelocity
end

-- ─── Core Simulation ─────────────────────────────────────────────────────────

--[=[
    SimulateCast

    Description:
        The core per-step simulation function. Advances a single cast forward by
        Delta seconds using the analytic kinematic equations, performs a raycast
        between the analytically computed previous and current positions, and
        resolves any surface contact with the appropriate response: pierce, bounce,
        or terminal impact.

        ── Two Callers ───────────────────────────────────────────────────────────

        SimulateCast is called from two contexts:

            _StepProjectile (top-level, IsSubSegment = false):
                Called once per cast per frame in standard mode (no sub-segmentation).
                Delta is the full frame time. The yield-detection guards for
                CanPierceFunction and CanBounceFunction are active.

            ResimulateHighFidelity (sub-segment, IsSubSegment = true):
                Called repeatedly with a small Delta (FrameDelta / SubSegmentCount).
                Each call advances the cast by one sub-segment. The IsSubSegment flag
                suppresses the yield-detection guards, which would otherwise fire false
                positives because the callback thread fields being set between
                sub-segments is expected normal behaviour in this context — not
                evidence of a yield from a previous frame.

        ── Hit Resolution Priority Order ─────────────────────────────────────────

        Surface contacts are resolved in strict priority order:
            1. Pierce — evaluated first. A bullet capable of piercing a surface should
               never simultaneously bounce off it. Treating these as mutually exclusive
               prevents physically inconsistent outcomes where a single contact generates
               both a pierce event and a bounce trajectory change.
            2. Bounce — evaluated only if pierce was not resolved on this contact.
            3. Terminal impact — reached if neither pierce nor bounce resolved the hit,
               or if a valid bounce was blocked by corner trap detection.

        ── Distance and Speed Termination ────────────────────────────────────────

        After hit processing, distance and speed checks are performed against the
        current position and velocity. Both fire OnHit with a nil RaycastResult to
        allow consumers to distinguish silent expiry from a physical surface impact.
        Without the nil-result convention, consumers would need a separate boolean
        flag or a different signal to differentiate the two termination reasons.

        ── CancelResimulation Flag ───────────────────────────────────────────────

        A bounce inside this function sets Runtime.CancelResimulation = true. This
        flag is read by ResimulateHighFidelity's inner loop as a signal to stop
        processing remaining sub-segments. Sub-segments after a bounce would be
        computing positions on the now-closed pre-bounce trajectory, producing
        incorrect hit detections on an arc the bullet has already left.

    Parameters:
        Solver: Vetra
            The solver instance that owns this cast. Required for all FireOn*
            helpers, ResolvePierce, _CastToBulletContext lookups, and Terminate.

        Cast: VetraCast
            The cast to advance by Delta seconds.

        Delta: number
            Time in seconds to advance the simulation. In top-level calls this
            is the full frame delta; in sub-segment calls this is
            FrameDelta / SubSegmentCount.

        IsSubSegment: boolean
            True when this call originates from ResimulateHighFidelity. Controls
            whether the callback yield-detection guards are active.
]=]

local function SimulateCast(Solver: Vetra, Cast: VetraCast, Delta: number, IsSubSegment: boolean)
	local Runtime          = Cast.Runtime
	local Behavior         = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory

	-- ─── Analytic Position Computation ───────────────────────────────────────

	-- Compute the elapsed time within the CURRENT trajectory segment only, not
	-- the total cast lifetime. This distinction is critical: after a bounce,
	-- TotalRuntime keeps accumulating but ActiveTrajectory.StartTime was set to
	-- the bounce time, so ElapsedBeforeAdvance correctly measures how far into
	-- the new arc we are — not the entire time the bullet has been alive.
	local ElapsedBeforeAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	-- The raycast's starting point is the bullet's position at the END of the
	-- previous frame (or the start of this sub-segment). Computing it analytically
	-- rather than reading a cached value ensures the start position is always
	-- consistent with the trajectory parameters, even if ModifyTrajectory changed
	-- the arc mid-flight between the previous step and this one.
	local LastPosition = PositionAtTime(
		ElapsedBeforeAdvance,
		ActiveTrajectory.Origin,
		ActiveTrajectory.InitialVelocity,
		ActiveTrajectory.Acceleration
	)

	-- Advance TotalRuntime by Delta. All subsequent position and velocity evaluations
	-- use ElapsedAfterAdvance so they reflect the bullet's state at the END of this
	-- step, which is where the raycast terminates and where hit detection is performed.
	Runtime.TotalRuntime += Delta
	local ElapsedAfterAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	-- The candidate end position is where the bullet would be at the end of this
	-- step if no surface is hit. CurrentVelocity at this same moment is used for
	-- speed threshold checks, cosmetic orientation, and signal payloads.
	local CurrentTargetPosition = PositionAtTime(
		ElapsedAfterAdvance,
		ActiveTrajectory.Origin,
		ActiveTrajectory.InitialVelocity,
		ActiveTrajectory.Acceleration
	)
	local CurrentVelocity = VelocityAtTime(
		ElapsedAfterAdvance,
		ActiveTrajectory.InitialVelocity,
		ActiveTrajectory.Acceleration
	)

	-- The displacement vector from the frame start to the frame end position.
	-- This vector serves as both the raycast direction and the raycast length in
	-- a single value. Using the full displacement vector (not a unit direction +
	-- separate length) ensures the raycast covers exactly the region traversed
	-- this step — no more, no less. A surface beyond the frame-end position
	-- cannot be detected; a surface within the step range cannot be missed.
	local FrameDisplacement = CurrentTargetPosition - LastPosition

	-- ─── Raycast ─────────────────────────────────────────────────────────────

	local RayDirection = FrameDisplacement

	-- Skip this step if the displacement is negligible. A zero-length raycast is
	-- undefined and would waste a Roblox API call. This can legitimately occur
	-- when Delta approaches zero (e.g. a sub-segment at the very end of a frame
	-- with extreme subdivision) or when the bullet is near-stationary. The
	-- IsBelowMinSpeed check later in this function will handle near-zero speed
	-- termination at the next step rather than requiring special handling here.
	if FrameDisplacement.Magnitude < 1e-6 then return end

	local RaycastResult = workspace:Raycast(LastPosition, RayDirection, Behavior.RaycastParams)

	-- If the ray hit something, use the actual hit position. Otherwise use the
	-- analytically computed frame-end position. BulletHitPoint drives travel
	-- distance accumulation, cosmetic bullet placement, and visual segment drawing
	-- regardless of whether a hit occurred, so both paths produce a valid position.
	local BulletHitPoint       = RaycastResult and RaycastResult.Position or CurrentTargetPosition
	local FrameRayDisplacement = (BulletHitPoint - LastPosition).Magnitude

	-- ─── Travel Update ───────────────────────────────────────────────────────

	-- Fire OnTravel BEFORE any hit processing. If the hit causes termination,
	-- OnTravel must still fire for this step to give trail and position consumers
	-- a complete per-frame record up to and including the terminal frame. If
	-- OnTravel fired after hit processing and the hit terminated the cast, the
	-- final frame's position would never reach trail effect or audio consumers —
	-- leaving a one-frame gap at the terminal position.
	FireOnTravel(Solver, Cast, BulletHitPoint, CurrentVelocity)
	Runtime.DistanceCovered += FrameRayDisplacement

	-- ─── Cosmetic Bullet Update ──────────────────────────────────────────────

	--[[
	    Orient the cosmetic bullet Instance to face the direction of travel.
	    CFrame.new(position, lookAt) constructs a CFrame at `position` looking
	    toward `lookAt`, aligning the Instance's positive Z axis (front face)
	    with the direction from `position` to `lookAt`. Adding velocity.Unit
	    to the current position provides a look-at point exactly one unit ahead
	    in the bullet's travel direction — the minimal offset required to define
	    a non-degenerate look-at direction.

	    The fallback direction (0, 0, 1) handles the degenerate case where the
	    bullet's speed is near zero (typically at the apex of its arc under gravity).
	    At near-zero speed, velocity.Unit is NaN (division by near-zero magnitude),
	    which would produce a degenerate CFrame. The dot-product self-check
	    (Velocity · Velocity > 1e-6) detects this cheaply without a square root call.
	]]
	if Runtime.CosmeticBulletObject then
		local LookAt = BulletHitPoint + (
			CurrentVelocity:Dot(CurrentVelocity) > 1e-6
				and CurrentVelocity.Unit
				or Vector3.new(0, 0, 1)
		)
		Runtime.CosmeticBulletObject.CFrame = CFrameNew(BulletHitPoint, LookAt)
	end

	-- ─── Debug Visualisation ─────────────────────────────────────────────────

	-- Gate visualisation on both VisualizeCasts and Delta > 0. The Delta guard
	-- prevents zero-length line segments from appearing in the debug view during
	-- time-zero initialisation passes or when a paused cast is released and
	-- immediately receives a zero-delta first step.
	if Behavior.VisualizeCasts and Delta > 0 then
		Visualizer.Segment(CFrameNew(LastPosition, LastPosition + RayDirection), FrameRayDisplacement)
	end

	-- ─── Hit Detection ───────────────────────────────────────────────────────

	--[[
	    Guard against the cosmetic bullet Instance being detected as a hit target.
	    Without this, the raycast would immediately detect the visible bullet part
	    at near-zero distance on the first frame (since it starts at the muzzle
	    position, exactly where the bullet is), firing a false terminal OnHit before
	    the bullet has moved at all. Instance reference equality is used rather than
	    name or class comparison to ensure exactly and only the cosmetic part for
	    THIS cast is filtered — nearby parts that happen to have the same class are
	    unaffected.
	]]
	local IsHitOnCosmeticBullet = RaycastResult and RaycastResult.Instance == Runtime.CosmeticBulletObject
	local IsValidHit            = RaycastResult ~= nil and not IsHitOnCosmeticBullet

	if IsValidHit then
		local LinkedContext     = Solver._CastToBulletContext[Cast]
		local CanPierceCallback = Behavior.CanPierceFunction

		-- ─── Yield Detection Guard (Pierce) ──────────────────────────────────

		--[[
		    CanPierceFunction must execute and return synchronously. It is called
		    while the frame simulation loop is running; any yield inside it would
		    suspend the entire _StepProjectile execution (blocking all other casts
		    in the same frame) until the coroutine resumed.

		    Detection mechanism:
		        Before calling CanPierceFunction, the current coroutine is stored in
		        Runtime.PierceCallbackThread. After the function returns (synchronously),
		        the field is cleared. If — on the NEXT top-level frame (IsSubSegment =
		        false) — PierceCallbackThread is still non-nil and belongs to a different
		        coroutine than the current one, it means the callback from the previous
		        frame yielded and never returned, leaving the field set. This indicates a
		        programming error in consumer code and the cast is terminated with an error.

		    The IsSubSegment check suppresses this guard for sub-segment calls.
		    In a high-fidelity resimulation loop, each sub-segment sets the field,
		    calls the callback (which returns immediately), and clears the field.
		    If this check ran inside sub-segment calls, the field set by one sub-
		    segment would be seen as a "hanging" thread by the next sub-segment,
		    producing false-positive terminations on every bullet in high-fidelity mode.
		]]
		local HasHangingPierceCallback = Runtime.PierceCallbackThread ~= nil
			and Runtime.PierceCallbackThread ~= coroutine.running()
		if not IsSubSegment and CanPierceCallback and HasHangingPierceCallback then
			Terminate(Solver, Cast)
			Logger:Error("SimulateCast: CanPierceFunction appears to have yielded")
			return
		end

		-- Record the current coroutine before calling CanPierceFunction. If the
		-- callback is synchronous (as required), this field will be cleared by the
		-- next line immediately after the function returns. If it yields, this field
		-- persists and will trigger the guard on the next top-level frame step.
		Runtime.PierceCallbackThread = coroutine.running()
		local CanPierce = CanPierceCallback and CanPierceCallback(LinkedContext, RaycastResult, CurrentVelocity)
		Runtime.PierceCallbackThread = nil

		-- ─── Pierce Branch ───────────────────────────────────────────────────

		-- ImpactDot measures how head-on the bullet is striking the surface.
		-- The absolute value of (RayDirection.Unit · Normal) equals cos(impact angle):
		--     1.0 = perfectly perpendicular strike (straight into the surface face).
		--     0.0 = perfectly parallel (bullet grazes the surface at 90°).
		-- PierceNormalBias of 1.0 allows all angles (ImpactDot >= 0.0). Lower values
		-- require increasingly head-on impacts to qualify for piercing, preventing
		-- a bullet skimming a surface at a near-tangent from tunnelling through.
		local IsAbovePierceSpeedThreshold = CurrentVelocity.Magnitude >= Behavior.PierceSpeedThreshold
		local IsBelowMaxPierceCount       = Runtime.PierceCount < Behavior.MaxPierceCount
		local ImpactDot                   = math.abs(RayDirection.Unit:Dot(RaycastResult.Normal))
		local MeetsNormalBias             = ImpactDot >= (1.0 - Behavior.PierceNormalBias)

		-- All four conditions must be true simultaneously. The evaluation order
		-- is chosen so the cheapest comparisons (magnitude vs constant, integer
		-- vs integer) are evaluated before the more expensive dot product.
		-- Any single false condition short-circuits the pierce path and falls
		-- through to the bounce or terminal hit evaluation below.
		local PierceConditionsMet = CanPierce and IsAbovePierceSpeedThreshold and IsBelowMaxPierceCount and MeetsNormalBias

		local PierceWasResolved = false

		if PierceConditionsMet then
			local FoundSolidHit, SolidHitResult, PostPierceVelocity = ResolvePierce(
				Solver,
				Cast,
				RaycastResult,
				LastPosition,
				RayDirection,
				CurrentVelocity
			)

			if FoundSolidHit and SolidHitResult then
				-- The pierce chain terminated at a surface the bullet cannot penetrate.
				-- This solid surface is the true terminal hit. We emit OnHit for the
				-- solid surface — not for the first pierceable surface — because the
				-- stopping point is where impact VFX and damage should originate. The
				-- consumer receives the contact position and normal of the actual blocker.
				if Behavior.VisualizeCasts then
					Visualizer.Hit(CFrameNew(RaycastResult.Position), "pierce")
					Visualizer.Hit(CFrameNew(SolidHitResult.Position), "terminal")
				end

				FireOnHit(Solver, Cast, SolidHitResult, PostPierceVelocity)
				FireOnTerminated(Solver, Cast)
				Terminate(Solver, Cast)
				return
			end
			-- The pierce chain ended in open space (no solid blocker found). The
			-- bullet continues flying — no terminal event is generated. Setting
			-- PierceWasResolved prevents the bounce and terminal hit branches from
			-- re-evaluating this same surface contact as if pierce had not occurred.
			PierceWasResolved = true
		end

		-- ─── Bounce Branch ───────────────────────────────────────────────────

		-- Bounce is only evaluated when pierce did NOT resolve this contact. A
		-- surface cannot simultaneously be pierced through and bounced off — these
		-- are physically and logically mutually exclusive. Enforcing the exclusion
		-- here prevents both outcomes from being generated for a single contact
		-- when both CanPierceFunction and CanBounceFunction are non-nil.
		if not PierceWasResolved then
			local CanBounceCallback = Behavior.CanBounceFunction

			-- Yield-detection guard for CanBounceFunction, symmetric to the pierce
			-- guard above. The same constraints apply: CanBounceFunction must not
			-- yield, and the IsSubSegment flag suppresses the guard during high-
			-- fidelity sub-segment calls where the callback thread field being set
			-- between sub-segments is expected and not a sign of a yield.
			local PreviousThread           = Runtime.BounceCallbackThread
			local HasHangingBounceCallback = PreviousThread ~= nil
				and PreviousThread ~= coroutine.running()
			if not IsSubSegment and CanBounceCallback and HasHangingBounceCallback then
				Terminate(Solver, Cast)
				Logger:Error("SimulateCast: CanBounceFunction appears to have yielded — this is not allowed")
				return
			end

			Runtime.BounceCallbackThread = coroutine.running()
			local CanBounce = CanBounceCallback and CanBounceCallback(LinkedContext, RaycastResult, CurrentVelocity)
			Runtime.BounceCallbackThread = nil

			-- All four bounce conditions must be satisfied simultaneously.
			-- BouncesThisFrame is a per-real-frame counter reset at the top of
			-- _StepProjectile, not per sub-segment. MaxBouncesPerFrame therefore
			-- caps the total bounces across all sub-segments for a given frame step.
			-- Without this cap, a bullet entering a tight corner could process its
			-- entire MaxBounces budget in a single high-fidelity frame via rapid
			-- sub-segment bounces, visually appearing to freeze instantly rather
			-- than bouncing over several frames.
			local IsAboveBounceSpeedThreshold = CurrentVelocity.Magnitude >= Behavior.BounceSpeedThreshold
			local IsBelowMaxBounceCount       = Runtime.BounceCount < Behavior.MaxBounces
			local IsBelowMaxBouncesThisFrame  = Runtime.BouncesThisFrame < Behavior.MaxBouncesPerFrame
			local BounceConditionsMet         = CanBounce
				and IsAboveBounceSpeedThreshold
				and IsBelowMaxBounceCount
				and IsBelowMaxBouncesThisFrame

			local BounceWasResolved = false

			if BounceConditionsMet then
				-- OnPreBounce fires before reflection is computed. Consumers can override
				-- two fields:
				--   Normal:           replaces the geometric surface normal fed into
				--                     ResolveBounce and IsCornerTrap.
				--   IncomingVelocity: replaces the velocity fed into ResolveBounce.
				--                     Useful for capping entry speed or zeroing spin
				--                     before the reflection formula runs.
				-- An invalid (NaN/inf) IncomingVelocity override is silently ignored
				-- and CurrentVelocity is used as a fallback.
				local PreBounceData = FireOnPreBounce(Solver, Cast, RaycastResult, CurrentVelocity)
				local PreBounceData = FireOnPreBounce(Solver, Cast, RaycastResult, CurrentVelocity)

				-- Use consumer-overridden normal if provided, otherwise fall back to geometric normal.
				-- EffectiveNormal flows through ALL subsequent operations — corner trap, reflection,
				-- origin nudge, visualisation, and bounce metadata storage — so the override is
				-- respected consistently rather than partially.

				local EffectiveNormal = PreBounceData.Normal or RaycastResult.Normal
				
				local IsTrapped = IsCornerTrap(Cast, EffectiveNormal, RaycastResult.Position)

				if not IsTrapped then

					local EffectiveIncoming  = (PreBounceData.IncomingVelocity and t.Vector3(PreBounceData.IncomingVelocity))
						and PreBounceData.IncomingVelocity
						or  CurrentVelocity

					-- Compute the reflected and energy-attenuated velocity for the
					-- post-bounce arc. ResolveBounce applies the reflection formula and
					-- the base + material restitution coefficients in a single call	
					local PostBounceVelocity = ResolveBounce(Cast, RaycastResult, EffectiveIncoming, EffectiveNormal)

					-- OnMidBounce fires after reflection is computed but before restitution
					-- scaling and perturbation are applied. Consumers can override three fields:
					--   PostBounceVelocity: replaces the reflected vector before scaling.
					--   Restitution:        overrides the energy loss scalar for this bounce.
					--   NormalPerturbation: overrides the scatter amount applied to FinalVelocity's
					--                       direction after restitution. Nil falls back to
					--                       Behavior.NormalPerturbation.
					local MidBounceData = FireOnMidBounce(Solver, Cast, RaycastResult, PostBounceVelocity)
					
					local FinalVelocity = MidBounceData.PostBounceVelocity or PostBounceVelocity
					if not t.Vector3(FinalVelocity) then
						Logger:Warn("OnMidBounce: PostBounceVelocity mutation invalid — ignoring")
						FinalVelocity = PostBounceVelocity
					end
					
					local MaterialMultiplier = (Behavior.MaterialRestitution and Behavior.MaterialRestitution[RaycastResult.Material]) or 1.0
					local BaseRestitution = (type(MidBounceData.Restitution) == "number")
					and MidBounceData.Restitution
					or Behavior.Restitution
					FinalVelocity = FinalVelocity * (BaseRestitution * MaterialMultiplier)

					local Perturbation = type(MidBounceData.NormalPerturbation) == "number"
						and MidBounceData.NormalPerturbation
						or Behavior.NormalPerturbation
					if Perturbation > 0 and FinalVelocity:Dot(FinalVelocity) > 1e-6 then
						local Noise = Vector3.new(
							math.random() - 0.5,
							math.random() - 0.5,
							math.random() - 0.5
						).Unit * Perturbation
						FinalVelocity = (FinalVelocity.Unit + Noise).Unit * FinalVelocity.Magnitude
					end

					-- Offset the new trajectory origin along the surface normal by NUDGE.
					-- This ensures the first raycast on the new arc (whether sub-segment
					-- or next frame) does not originate exactly on the surface plane and
					-- re-detect it at distance ~0, which would produce a spurious
					-- immediate re-bounce at the same point.
					local PostBounceOrigin = RaycastResult.Position + EffectiveNormal * NUDGE

					if Behavior.VisualizeCasts then
						Visualizer.Hit(CFrameNew(RaycastResult.Position), "bounce")
						Visualizer.Normal(RaycastResult.Position, EffectiveNormal)
						Visualizer.Velocity(RaycastResult.Position, FinalVelocity)
					end

					-- Open a new trajectory segment for the post-bounce path. The segment
					-- starts at the current TotalRuntime so subsequent ElapsedTime
					-- computations are anchored to this bounce moment, not to the
					-- original fire time. Acceleration is inherited from the pre-bounce
					-- trajectory so gravity continues to act on the new arc unchanged.
					local NewTrajectory = {
						StartTime       = Runtime.TotalRuntime,
						EndTime         = -1,
						Origin          = PostBounceOrigin,
						InitialVelocity = FinalVelocity,
						Acceleration    = ActiveTrajectory.Acceleration,
					}
					table.insert(Runtime.Trajectories, NewTrajectory)
					Runtime.ActiveTrajectory   = NewTrajectory


					-- Signal ResimulateHighFidelity to abandon the sub-segment loop for
					-- the current frame. Any remaining sub-segments would be stepping
					-- positions on the old (now-closed) pre-bounce trajectory, producing
					-- raycasts in the wrong region of space. The next frame will start
					-- from the new post-bounce trajectory.
					Runtime.CancelResimulation = true

					-- Update the bounce metadata that IsCornerTrap reads on the next
					-- bounce. A degenerate surface normal (length near zero, which can
					-- occur with certain Roblox collision meshes) is guarded against
					-- before storing because a zero-length LastBounceNormal would make
					-- Guard 2's dot product always equal 0.0, permanently disabling that
					-- guard for the remainder of the cast's lifetime.
					 if EffectiveNormal:Dot(EffectiveNormal) > 1e-6 then
						Runtime.LastBounceNormal   = EffectiveNormal
						Runtime.LastBouncePosition = RaycastResult.Position
						Runtime.LastBounceTime     = OsClock()
					else
						Logger:Warn("SimulateCast: degenerate surface normal detected — corner trap state not updated")
					end
					Runtime.BouncesThisFrame += 1
					
					-- If configured, reset pierce state so the post-bounce arc starts with a
					-- clean filter and a fresh pierce budget. This runs after the new trajectory
					-- segment is open and before FireOnBounce fires, so any OnBounce handler
					-- that reads PierceCount or immediately calls Fire() for a fragment sees the
					-- already-reset values rather than the previous arc's accumulated state.
					if Behavior.ResetPierceOnBounce then
						Runtime.PiercedInstances = {}
						Runtime.PierceCount = 0
						Behavior.RaycastParams.FilterDescendantsInstances =
							table.clone(Behavior.OriginalFilter)
					end

					FireOnBounce(Solver, Cast, RaycastResult, FinalVelocity)
        			BounceWasResolved = true
					return
				else
					-- Corner trap confirmed. Log and fall through to terminal hit
					-- processing below. Terminating here prevents the bullet from
					-- consuming remaining bounce budget in an infinite reflection loop
					-- inside a pocket of concave geometry.
					if Behavior.VisualizeCasts then
						Visualizer.CornerTrap(RaycastResult.Position)
					end
					Logger:Print("SimulateCast: corner trap detected — terminating cast to prevent infinite bounce")
				end
			end

			-- ─── Terminal Hit ─────────────────────────────────────────────────

			--[[
			    Execution reaches here when the contact qualifies for neither pierce
			    nor bounce:
			      - CanPierceFunction returned false, was nil, or speed/angle
			        thresholds were not met.
			      - CanBounceFunction returned false, was nil, speed/count thresholds
			        were not met, or a corner trap was detected and fell through.
			    This is a definitive, permanent impact. The bullet stops at this surface.
			]]
			if not BounceWasResolved then
				FireOnHit(Solver, Cast, RaycastResult, CurrentVelocity)
				FireOnTerminated(Solver, Cast)
				Terminate(Solver, Cast)
				return
			end
		end
	end

	-- ─── Distance Termination ────────────────────────────────────────────────

	--[[
	    The bullet has accumulated at least MaxDistance studs of travel since it
	    was fired. This path fires OnHit with a nil RaycastResult, which is the
	    module's convention for distinguishing silent range expiry from a physical
	    surface impact. Consumers check `Result ~= nil` to decide whether to
	    spawn impact VFX or simply let the bullet disappear. This check runs
	    after OnTravel for this step, ensuring position consumers always receive
	    a complete per-frame update before the cast is removed.
	]]
	if Runtime.DistanceCovered >= Behavior.MaxDistance then
		if Behavior.VisualizeCasts then
			Visualizer.Hit(CFrameNew(CurrentTargetPosition), "terminal")
		end
		FireOnHit(Solver, Cast, nil, CurrentVelocity)
		FireOnTerminated(Solver, Cast)
		Terminate(Solver, Cast)
		return
	end

	-- ─── Minimum Speed Termination ───────────────────────────────────────────

	--[[
	    The bullet's speed has fallen below MinSpeed. This typically follows many
	    inelastic bounces (Restitution < 1.0 bleeds kinetic energy on each contact)
	    or heavy deceleration from opposing gravity. Like distance expiry, this
	    fires OnHit with a nil RaycastResult. Without this check, a bullet that
	    has decelerated to near-zero speed would simulate indefinitely — it would
	    never travel far enough to reach MaxDistance and would never hit a surface
	    because each frame's raycast would cover only a tiny fraction of a stud.
	    This would produce a permanent leak in the _ActiveCasts array.
	]]

	local IsBelowMinSpeed = CurrentVelocity.Magnitude < Behavior.MinSpeed
	if IsBelowMinSpeed then
		FireOnHit(Solver, Cast, nil, CurrentVelocity)
		FireOnTerminated(Solver, Cast)
		Terminate(Solver, Cast)
		return
	end
end

-- ─── High-Fidelity Resimulation ──────────────────────────────────────────────

--[=[
    ResimulateHighFidelity

    Description:
        Subdivides a single frame's bullet travel into multiple smaller time slices
        and simulates each one individually through SimulateCast. The goal is to
        eliminate thin-surface tunnelling that would occur with a single per-frame
        raycast at high bullet speeds.

        ── Why Sub-Segmentation Is Necessary ────────────────────────────────────

        Without sub-segmentation, each frame produces exactly one raycast spanning
        from the frame-start position to the frame-end position. At 300 studs/second
        and 60Hz, each frame covers 5 studs per raycast. Any surface thinner than
        5 studs (e.g. a plywood wall, a sheet metal door) could be skipped entirely
        if the bullet's frame-start and frame-end positions happen to land on opposite
        sides. Sub-segmentation subdivides the 5-stud step into 10 × 0.5-stud steps,
        each generating its own raycast. A surface only 1 stud thick will be
        intersected by at least two of these raycasts, making tunnelling practically
        impossible without absurdly small segment sizes.

        ── Adaptive Segment Sizing ───────────────────────────────────────────────

        After the sub-segment loop completes, the total elapsed wall-clock time is
        compared against HighFidelityFrameBudget:

            Over budget (elapsed > budget):
                The loop consumed too much time. Increase CurrentSegmentSize by
                AdaptiveScaleFactor so future frames produce fewer sub-segments
                and fewer raycasts. This trades fidelity for performance.

            Under half budget (elapsed < budget * 0.5):
                The loop has significant spare time. Decrease CurrentSegmentSize
                by AdaptiveScaleFactor so future frames produce more sub-segments
                and more raycasts. This trades performance for improved hit detection.

            Within budget (between half and full budget):
                Leave CurrentSegmentSize unchanged. This dead-band prevents the
                adaptive system from oscillating — without it, every frame would
                alternately coarsen and refine due to minor timing noise from other
                work happening on the same thread.

        This self-tuning system gracefully degrades under CPU load by widening
        segments rather than uniformly dropping fidelity for all bullets simultaneously.

        ── Cascade Protection ────────────────────────────────────────────────────

        Runtime.IsActivelyResimulating is set to true at the start of this function
        and cleared on all return paths. If this function is called while it is
        already set (meaning a signal handler inside a SimulateCast call triggered
        another round of resimulation), the cascade is detected and the cast is
        terminated rather than allowing infinite recursion.

        ── Per-Instance Frame Budget ─────────────────────────────────────────────

        Solver._FrameBudget.RemainingMicroseconds is decremented after each
        sub-segment by that sub-segment's measured wall time. Once it reaches zero,
        the loop breaks and remaining sub-segments are skipped for this frame.
        Because the budget is per-instance, two concurrent solver instances each
        receive the full GLOBAL_FRAME_BUDGET_MS independently.

    Parameters:
        Solver: Vetra
            The solver instance. Required for SimulateCast and frame budget access.

        Cast: VetraCast
            The cast to resimulate for this frame.

        ActiveTrajectory: Type.CastTrajectory
            The trajectory segment that was active at the start of this frame.

        ElapsedAtFrameStart: number
            Elapsed time within the active trajectory at the start of this frame,
            before any time was advanced by the tentative TotalRuntime pre-advance
            in _StepProjectile.

        FrameDelta: number
            Total frame time in seconds. All sub-segments share this total:
            SubSegmentDelta = FrameDelta / SubSegmentCount. Their deltas sum
            exactly to FrameDelta, preserving correct total TotalRuntime advance.

        FrameDisplacement: number
            Total displacement magnitude for the frame (frame-end position minus
            frame-start position). Used to compute SubSegmentCount:
            floor(FrameDisplacement / CurrentSegmentSize).

    Returns:
        boolean
            True if the cast was terminated during resimulation. False if the
            cast is still alive after all sub-segments complete.
]=]
local function ResimulateHighFidelity(
	Solver: Vetra,
	Cast: VetraCast,
	ActiveTrajectory: Type.CastTrajectory,
	ElapsedAtFrameStart: number,
	FrameDelta: number,
	FrameDisplacement: number
): boolean

	-- Cascade protection. If IsActivelyResimulating is already true when this
	-- function is entered, it means a signal handler fired from inside a previous
	-- SimulateCast call triggered another _StepProjectile step on the same cast
	-- before the current one completed. This is a programming error in consumer
	-- code (signal handlers must not trigger simulation steps). Terminating the
	-- cast and logging an error is safer than allowing stack overflow via
	-- unbounded recursion.
	if Cast.Runtime.IsActivelyResimulating then
		Terminate(Solver, Cast)
		Logger:Error("ResimulateHighFidelity: cascade resimulation detected — possible signal handler re-entry")
		return false
	end

	Cast.Runtime.IsActivelyResimulating = true
	Cast.Runtime.CancelResimulation     = false

	local Behavior    = Cast.Behavior
	local FrameBudget = Solver._FrameBudget

	-- Compute the number of sub-segments by dividing the total frame displacement
	-- by the current adaptive segment size. MathFloor truncates to an integer
	-- because fractional raycasts are undefined. MathClamp ensures at least 1
	-- sub-segment (so a cast always advances at least once, even if displacement
	-- is smaller than CurrentSegmentSize) and at most MAX_SUBSEGMENTS (so an
	-- extremely fast bullet with a tiny segment size cannot issue thousands of
	-- raycasts in one frame).
	local SubSegmentCount = MathClamp(
		MathFloor(FrameDisplacement / Cast.Runtime.CurrentSegmentSize),
		1,
		MAX_SUBSEGMENTS
	)

	if SubSegmentCount >= MAX_SUBSEGMENTS then
		-- The bullet is moving so fast relative to the current segment size that
		-- it hit the hard cap. Apply an aggressive 2x correction (double the normal
		-- AdaptiveScaleFactor increase) to reach a safe segment size quickly.
		-- Using the normal adaptive correction alone would take multiple frames to
		-- converge, hitting the cap on each intermediate frame and producing repeated
		-- warning spam and wasted raycast budget.
		Cast.Runtime.CurrentSegmentSize = Cast.Runtime.CurrentSegmentSize
			* Behavior.AdaptiveScaleFactor * 2
		Logger:Warn(string.format(
			"ResimulateHighFidelity: SubSegmentCount capped at %d — consider increasing HighFidelitySegmentSize",
			MAX_SUBSEGMENTS
		))
	end

	-- Each sub-segment receives an equal share of the total frame time. This
	-- ensures the cumulative TotalRuntime advance across all sub-segments equals
	-- exactly FrameDelta, maintaining correct absolute timing for the entire cast.
	local SubSegmentDelta = FrameDelta / SubSegmentCount
	local HitOccurred     = false
	local ResimStartTime  = OsClock()

	for SegmentIndex = 1, SubSegmentCount do
		-- CancelResimulation is set by SimulateCast when a bounce creates a new
		-- ActiveTrajectory segment. All remaining sub-segments in this loop would
		-- compute positions on the now-closed pre-bounce trajectory. Stopping here
		-- ensures no raycasts are performed on an arc the bullet has already left.
		-- The next frame will pick up correctly from the new post-bounce trajectory.
		if Cast.Runtime.CancelResimulation then break end

		-- IsSubSegment = true suppresses the yield-detection guards inside
		-- SimulateCast. Within this loop, the callback thread fields being set
		-- from the previous sub-segment is normal expected behaviour, not evidence
		-- of a suspended callback from a previous frame.
		local SegmentStart = OsClock()
		SimulateCast(Solver, Cast, SubSegmentDelta, true)

		-- Deduct this sub-segment's measured wall time from the instance's frame
		-- budget. When the budget reaches zero, all remaining sub-segments for
		-- this cast (and all other casts on this solver) are skipped for the rest
		-- of the frame. This prevents a single complex multi-bounce scenario from
		-- consuming the entire frame's raycast allocation.
		FrameBudget.RemainingMicroseconds -= (OsClock() - SegmentStart) * 1e6

		-- If SimulateCast terminated the cast (hit, distance expiry, speed expiry),
		-- stop immediately. Continuing to step a terminated cast is a use-after-free:
		-- Cast has been removed from _ActiveCasts but we still hold a local reference.
		-- The cast's internal state is no longer valid for simulation use.
		if not Cast.Alive then
			HitOccurred = true
			break
		end

		if FrameBudget.RemainingMicroseconds <= 0 then
			-- Instance frame budget exhausted. Stop processing sub-segments for this
			-- cast this frame. The bullet will resume from its current position on
			-- the next frame with a fresh budget.
			break
		end
	end

	Cast.Runtime.CancelResimulation = false

	-- ─── Adaptive Segment Size Adjustment ────────────────────────────────────

	--[[
	    Compare the total resimulation wall time against HighFidelityFrameBudget
	    to decide whether to coarsen or refine segments for the next frame.

	    Over budget (elapsed > budget):
	        Too expensive. Increase segment size (fewer raycasts next frame).
	        The upper cap of 999 prevents math.min from inadvertently receiving a
	        smaller second argument and shrinking the segment size — it is effectively
	        an uncapped upper bound.

	    Under half budget (elapsed < budget * 0.5):
	        Spare capacity available. Decrease segment size (more raycasts next frame,
	        better thin-surface detection). MinSegmentSize provides a hard floor to
	        prevent the segment size from approaching zero and generating unbounded
	        sub-segment counts.

	    Within budget (between half and full budget):
	        Leave the size unchanged. Without this dead-band, minor per-frame timing
	        variance would cause the system to oscillate — coarsening one frame because
	        elapsed was marginally over budget, refining the next because it was
	        marginally under, coarsening again, and so on. The dead-band stabilises
	        the adaptive system around the target operating point.
	]]
	local ResimElapsedMilliseconds = (OsClock() - ResimStartTime) * 1000
	local IsOverBudget             = ResimElapsedMilliseconds > Behavior.HighFidelityFrameBudget
	local IsUnderHalfBudget        = ResimElapsedMilliseconds < Behavior.HighFidelityFrameBudget * 0.5

	if IsOverBudget then
		-- Too expensive this frame: widen segments to reduce raycast count next frame.
		Cast.Runtime.CurrentSegmentSize = math.min(
			Cast.Runtime.CurrentSegmentSize * Behavior.AdaptiveScaleFactor,
			999
		)
	elseif IsUnderHalfBudget then
		-- Spare budget: narrow segments to improve hit detection resolution next frame.
		Cast.Runtime.CurrentSegmentSize = math.max(
			Cast.Runtime.CurrentSegmentSize / Behavior.AdaptiveScaleFactor,
			Behavior.MinSegmentSize
		)
	end

	-- Clear the flag unconditionally on all return paths — including early breaks
	-- from budget exhaustion. If left set after an early break, the next frame's
	-- call to ResimulateHighFidelity would see IsActivelyResimulating = true and
	-- immediately terminate the cast as a spurious cascade detection.
	Cast.Runtime.IsActivelyResimulating = false
	return HitOccurred
end

-- ─── Frame Loop ──────────────────────────────────────────────────────────────

--[=[
    _StepProjectile

    Description:
        The per-frame driver for all active projectile casts owned by a given
        solver instance. Connected once to the appropriate RunService event
        (Heartbeat on the server, RenderStepped on the client) at Factory.new()
        time. Called every frame with the elapsed frame delta.

        At the start of each call, the instance's per-frame raycast budget is
        reset so that the high-fidelity sub-segment allocation is fresh for every
        frame. Because the budget lives on the instance, two concurrent solver
        instances are each allocated the full GLOBAL_FRAME_BUDGET_MS independently
        rather than sharing a single pool.

        For each active, unpaused cast, the function chooses one of two simulation
        paths:

            Standard mode (HighFidelitySegmentSize = 0 or CurrentSegmentSize = 0):
                Calls SimulateCast directly with the full frame delta. Suitable for
                slow-moving projectiles, distant or cosmetic bullets, or any cast
                where tunnelling through thin surfaces is acceptable or the surfaces
                in the scene are all thicker than the bullet's per-frame travel distance.

            High-fidelity mode (HighFidelitySegmentSize > 0):
                Computes the total frame displacement (tentatively advancing and then
                rewinding TotalRuntime — see below), then calls ResimulateHighFidelity
                to subdivide that displacement into smaller steps, each generating its
                own raycast. This prevents thin-surface tunnelling at high bullet speeds.

        ── Why High-Fidelity Mode Requires a Tentative Pre-advance ──────────────

        ResimulateHighFidelity needs to know the total frame displacement BEFORE
        advancing TotalRuntime so it can compute SubSegmentCount. To get the frame-end
        position analytically, TotalRuntime must be temporarily advanced by FrameDelta.
        After computing the displacement, TotalRuntime is rewound to its original value.
        Without this rewind, TotalRuntime would already be FrameDelta ahead before
        ResimulateHighFidelity begins its sub-segment loop. Each sub-segment then
        advances it further, resulting in a total advance of FrameDelta + N*SubSegmentDelta
        = 2*FrameDelta by the end of the frame — a systematic double-advance that would
        place every subsequent position computation one full frame ahead of reality.

    Parameters:
        Solver: Vetra
            The solver instance whose casts are stepped. Each solver instance has
            its own _StepProjectile connection that captures Solver by upvalue.
            Casts from different instances are never mixed.

        FrameDelta: number
            Duration of the current frame in seconds, provided by the RunService
            event callback.

    Notes:
        ActiveCount is snapshotted before iteration begins. Any cast created during
        this frame (e.g. spawned by an OnHit handler that calls Fire() for a fragment)
        is appended to _ActiveCasts beyond index ActiveCount and will not be processed
        until the next frame. Without this snapshot, a new cast added at index N+1
        during the iteration over indices 1..N would be visited in the same frame it
        was created, receiving a partial first-frame simulation with an inconsistent
        initial delta.

        The `not Cast or not Cast.Alive` guard handles nil and dead entries that can
        appear inside the snapshot range. A Cast can be nil if an earlier iteration's
        swap-remove moved a beyond-range element into a within-range slot that has
        not been visited yet. A cast can be dead if an earlier iteration's signal
        handler called context:Terminate() on a later cast before its index was reached.
]=]
local function _StepProjectile(Solver: Vetra, FrameDelta: number)
	-- Reset this instance's frame budget at the start of each frame. All high-
	-- fidelity sub-segment raycasts across every cast on this solver draw from
	-- this shared pool within the frame. Resetting here ensures the previous
	-- frame's consumed budget does not carry over and prematurely exhaust the
	-- current frame's allocation.
	local FrameBudget = Solver._FrameBudget
	FrameBudget.RemainingMicroseconds = GLOBAL_FRAME_BUDGET_MS * 1000

	local ActiveCasts = Solver._ActiveCasts
	local ActiveCount = #ActiveCasts

	--[[
	    Snapshot ActiveCount before the loop. Casts registered during this frame
	    (appended to _ActiveCasts during signal handler execution in this very
	    iteration) exist at indices > ActiveCount. They will not be reached by
	    this loop and will be processed starting with the next frame. This gives
	    every cast a consistent first-frame delta equal to exactly one full
	    FrameDelta, not a fraction that depends on when during the frame the
	    cast was registered.
	]]
	for CastIndex = 1, ActiveCount do
		local Cast = ActiveCasts[CastIndex]

		-- Guard against nil and dead casts. Nil can appear when an earlier
		-- termination's swap-remove moved a beyond-range cast into a within-range
		-- slot. Dead can appear when a signal handler from an earlier cast in this
		-- iteration called context:Terminate() on a cast further in the array.
		if not Cast or not Cast.Alive then continue end

		-- Paused casts skip all simulation. TotalRuntime does not advance while
		-- a cast is paused, so resuming it later produces seamless continuation
		-- from the exact state it was in when paused — no position discontinuity
		-- or velocity jump.
		if Cast.Paused then continue end

		local Runtime  = Cast.Runtime
		local Behavior = Cast.Behavior

		-- Reset the per-frame bounce counter before simulating this cast. Without
		-- this reset, a cast that bounced in a previous frame would carry over a
		-- non-zero BouncesThisFrame into this frame, effectively reducing its
		-- per-frame bounce budget by however many bounces occurred previously.
		-- BouncesThisFrame must reflect only bounces occurring in the CURRENT
		-- frame step.
		Runtime.BouncesThisFrame = 0

		-- High-fidelity mode is active when HighFidelitySegmentSize is positive
		-- AND CurrentSegmentSize is positive. CurrentSegmentSize should never
		-- reach zero given MinSegmentSize > 0, but the guard prevents a potential
		-- divide-by-zero in ResimulateHighFidelity's sub-segment count calculation
		-- if the adaptive system somehow reduces it to zero.
		local UseHighFidelity = Behavior.HighFidelitySegmentSize > 0
			and Runtime.CurrentSegmentSize > 0

		if UseHighFidelity then
			local CurrentTrajectory   = Runtime.ActiveTrajectory
			local ElapsedAtFrameStart = Runtime.TotalRuntime - CurrentTrajectory.StartTime

			-- Compute the bullet's world-space position at the start of this frame.
			-- This is needed to measure total frame displacement after the tentative
			-- pre-advance below.
			local PositionAtFrameStart = PositionAtTime(
				ElapsedAtFrameStart,
				CurrentTrajectory.Origin,
				CurrentTrajectory.InitialVelocity,
				CurrentTrajectory.Acceleration
			)

			-- Tentatively advance TotalRuntime by the full frame delta. This allows
			-- PositionAtTime to compute the frame-end position analytically, giving us
			-- the total displacement magnitude needed for sub-segment count calculation.
			-- This is NOT a real simulation step — it is a probe to compute a length.
			Runtime.TotalRuntime += FrameDelta
			local ElapsedAtFrameEnd = Runtime.TotalRuntime - CurrentTrajectory.StartTime

			local PositionAtFrameEnd = PositionAtTime(
				ElapsedAtFrameEnd,
				CurrentTrajectory.Origin,
				CurrentTrajectory.InitialVelocity,
				CurrentTrajectory.Acceleration
			)

			local TotalFrameDisplacement = (PositionAtFrameEnd - PositionAtFrameStart).Magnitude

			-- CRITICAL: rewind TotalRuntime to its pre-advance value. If this rewind
			-- were omitted, TotalRuntime would already be FrameDelta ahead before
			-- ResimulateHighFidelity begins. Each sub-segment would then advance it
			-- further, producing a total advance of 2*FrameDelta by the end of the
			-- frame — a systematic error that compounds into incorrect position and
			-- velocity values for the entire cast's remaining lifetime.
			Runtime.TotalRuntime -= FrameDelta

			ResimulateHighFidelity(
				Solver,
				Cast,
				CurrentTrajectory,
				ElapsedAtFrameStart,
				FrameDelta,
				TotalFrameDisplacement
			)

			-- Clear CancelResimulation unconditionally after the high-fidelity pass.
			-- A bounce that occurred inside ResimulateHighFidelity sets this flag
			-- to stop the sub-segment loop. Without this clear, the flag would
			-- persist into the next frame's _StepProjectile call. The first sub-
			-- segment of the next frame would then see CancelResimulation = true,
			-- break immediately, and advance the bullet by zero time — causing it
			-- to stall until the flag was cleared by some other code path.
			Cast.Runtime.CancelResimulation = false
		else
			-- Standard mode: one raycast covering the full frame. No sub-segmentation.
			-- Appropriate for low-speed projectiles or scenes where thin-surface
			-- tunnelling is not a concern and per-frame raycast cost must be minimised.
			SimulateCast(Solver, Cast, FrameDelta, false)
		end
	end
end

-- ─── Vetra Methods ────────────────────────────────────────────────────

local Vetra = {}
Vetra.__index = Vetra
Vetra.__type  = IDENTITY

-- ─── Fire ────────────────────────────────────────────────────────────────────

--[=[
    Vetra:Fire

    Description:
        Creates, configures, and registers a new in-flight projectile cast.
        This is the primary public entry point for all projectile creation.
        After Fire() returns, the cast is live in the solver's _ActiveCasts
        registry and will be advanced every frame by _StepProjectile until it
        hits a surface, exceeds MaxDistance, falls below MinSpeed, or is manually
        terminated via context:Terminate().

        ── Execution Sequence ────────────────────────────────────────────────────

        1. Input validation:
            The BulletContext's Origin, Direction, and Speed fields are checked
            for validity (non-nil, finite, correct type) before any state is
            allocated. Failing fast here with a descriptive warning is far
            preferable to a nil-index error three call frames deep inside
            SimulateCast — the caller receives an actionable message at the point
            of the mistake rather than a confusing runtime crash.

        2. Behavior resolution:
            Each field of FireBehavior is resolved individually against
            DEFAULT_BEHAVIOR using explicit `or` fallbacks. This is deliberately
            verbose rather than using `setmetatable(fb, {__index = DEFAULT_BEHAVIOR})`
            because metatable inheritance would silently accept misspelled field names:
            a typo like `CanPirceFunction` would fall through to nil, causing the cast
            to behave as if piercing were disabled with no diagnostic. Explicit per-field
            resolution makes every field name a visible constant checked at the point
            of use, and any unrecognised key will simply be ignored rather than silently
            overriding a default.

        3. RaycastParams pool acquisition:
            A RaycastParams object is acquired from ParamsPooler. The pool clones
            the caller's params so that filter mutations performed by the pierce
            system (appending or removing instances from the filter list as the
            bullet travels) never affect the caller's original params object. The
            original filter list is also snapshot-frozen on the Behavior table as
            OriginalFilter — this snapshot is used by Terminate() to reset the
            pooled params back to their initial state before returning them to the
            pool, so the next cast that acquires them receives a clean filter.

        4. VetraCast construction:
            The full VetraCast table is built, including the first trajectory
            segment. The segment's Acceleration is the sum of resolved gravity and
            resolved extra Acceleration, combined once here so SimulateCast never
            needs to perform the addition at runtime.

        5. Cosmetic bullet creation:
            If CosmeticBulletProvider is set (a function), it is called to obtain
            a live Instance for the visible bullet. If only CosmeticBulletTemplate
            is set (a BasePart), it is cloned. The provider takes priority; if both
            are provided, Template is silently ignored and a warning is logged. The
            provider is timed against PROVIDER_TIMEOUT — any call exceeding that
            threshold logs a warning because providers must not yield.

        6. Registration and context linking:
            The cast is inserted into self._ActiveCasts via Register(). The
            bidirectional cast↔context map is established on the solver instance's
            weak maps.

        7. Terminate closure injection:
            A Terminate closure is injected into Context.__solverData. This closure
            captures self by upvalue so context:Terminate() always reaches the correct
            solver instance regardless of how many instances exist at call time.

    Parameters:
        self: Vetra
            The solver instance receiving this cast. All registry, map, and signal
            operations use self rather than any module-level state.

        Context: BulletContext
            The public-facing bullet object that weapon code interacts with. Must
            carry non-nil, finite Vector3 Origin and Direction fields and a finite
            number Speed. The context is passed as the first argument to every
            signal emission so consumers can identify which bullet fired each event.

        FireBehavior: VetraBehavior?
            Optional partial behavior configuration. Any field that is nil or absent
            falls back to DEFAULT_BEHAVIOR. Passing nil for the entire argument
            applies all defaults. The caller's table is never mutated — all resolved
            values are stored in a freshly constructed Behavior table on the VetraCast.

    Returns:
        VetraCast | nil
            The newly created VetraCast on success. Nil if input validation failed,
            allowing the caller to detect and handle a failed fire at the call site.

    Notes:
        Gravity handling: if FireBehavior.Gravity is provided with a non-zero magnitude,
        it is used as the gravity term. If Gravity has zero magnitude, the function falls
        back to DEFAULT_GRAVITY (workspace gravity at module load time) and logs an info
        message. This prevents a caller who accidentally passes Vector3.zero for gravity
        from silently disabling arc trajectory on all bullets — they receive a log message
        indicating the fallback occurred and can investigate their setup.

        CosmeticBulletProvider vs CosmeticBulletTemplate priority: if both are supplied,
        Template is ignored and a warning is logged. This is a deliberate priority rule
        rather than an error — it avoids breaking callers who set a default template on
        a shared Behavior table and then pass a provider for specific bullet types.
]=]
function Vetra.Fire(self: Vetra, Context: any, FireBehavior: VetraBehavior): VetraCast
	-- Validate the three required fields on the incoming context. All three are
	-- consumed directly to construct the initial trajectory segment:
	--     Origin → segment.Origin
	--     Direction.Unit * Speed → segment.InitialVelocity
	-- If any field is nil, NaN, or infinity, the trajectory would be initialised
	-- with invalid values that propagate silently through all kinematic math.
	-- Failing here gives the caller a clear error at the API boundary.
	if not t.Vector3(Context.Origin) or not t.Vector3(Context.Direction) or not t.number(Context.Speed) then
		Logger:Warn("Fire: Context must have Origin (Vector3), Direction (Vector3), and Speed (number)")
		return nil
	end

	FireBehavior = FireBehavior or {} :: VetraBehavior

	-- ─── Behavior Resolution ─────────────────────────────────────────────────

	--[[
	    Each field is resolved with an explicit `or DEFAULT_BEHAVIOR.FieldName`
	    fallback. This approach is verbose but safe: any misspelled or unrecognised
	    field in the caller's FireBehavior table is simply ignored — it will never
	    accidentally overwrite a default because misspelled fields produce nil values
	    that fall through to the explicit default. Metatable inheritance would have
	    the opposite problem: it would silently accept typos as intentional keys,
	    masking configuration errors that could be hard to diagnose in live play.

	    CanBounceFunction and CanPierceFunction are intentionally NOT given fallbacks
	    from DEFAULT_BEHAVIOR — their default is nil. A cast with no pierce or bounce
	    callback should never pierce or bounce. Providing a non-nil default would cause
	    all bullets fired without explicit callbacks to start piercing or bouncing
	    unexpectedly, which would be a severe and confusing regression.
	]]

	local ResolvedAcceleration                = FireBehavior.Acceleration or DEFAULT_BEHAVIOR.Acceleration
	local ResolvedMaxDistance                 = FireBehavior.MaxDistance or DEFAULT_BEHAVIOR.MaxDistance
	local ResolvedRaycastParams               = FireBehavior.RaycastParams or DEFAULT_BEHAVIOR.RaycastParams
	local ResolvedMinSpeed                    = FireBehavior.MinSpeed or DEFAULT_BEHAVIOR.MinSpeed
	local ResolvedCanPierceFunction           = FireBehavior.CanPierceFunction
	local ResolvedMaxPierceCount              = FireBehavior.MaxPierceCount or DEFAULT_BEHAVIOR.MaxPierceCount
	local ResolvedPierceSpeedThreshold        = FireBehavior.PierceSpeedThreshold or DEFAULT_BEHAVIOR.PierceSpeedThreshold
	local ResolvedPenetrationSpeedRetention   = FireBehavior.PenetrationSpeedRetention or DEFAULT_BEHAVIOR.PenetrationSpeedRetention
	local ResolvedPierceNormalBias            = FireBehavior.PierceNormalBias or DEFAULT_BEHAVIOR.PierceNormalBias
	local ResolvedResetPierceOnBounce         = if FireBehavior.ResetPierceOnBounce ~= nil
		then FireBehavior.ResetPierceOnBounce
		else DEFAULT_BEHAVIOR.ResetPierceOnBounce
	local ResolvedCanBounceFunction           = FireBehavior.CanBounceFunction
	local ResolvedMaxBounces                  = FireBehavior.MaxBounces or DEFAULT_BEHAVIOR.MaxBounces
	local ResolvedBounceSpeedThreshold        = FireBehavior.BounceSpeedThreshold or DEFAULT_BEHAVIOR.BounceSpeedThreshold
	local ResolvedRestitution                 = FireBehavior.Restitution or DEFAULT_BEHAVIOR.Restitution
	local ResolvedMaterialRestitution         = FireBehavior.MaterialRestitution or DEFAULT_BEHAVIOR.MaterialRestitution
	local ResolvedNormalPerturbation          = FireBehavior.NormalPerturbation or DEFAULT_BEHAVIOR.NormalPerturbation
	local ResolvedHighFidelitySegmentSize     = FireBehavior.HighFidelitySegmentSize or DEFAULT_BEHAVIOR.HighFidelitySegmentSize
	local ResolvedHighFidelityFrameBudget     = FireBehavior.HighFidelityFrameBudget or DEFAULT_BEHAVIOR.HighFidelityFrameBudget
	local ResolvedAdaptiveScaleFactor         = FireBehavior.AdaptiveScaleFactor or DEFAULT_BEHAVIOR.AdaptiveScaleFactor
	local ResolvedMinSegmentSize              = FireBehavior.MinSegmentSize or DEFAULT_BEHAVIOR.MinSegmentSize
	local ResolvedMaxBouncesPerFrame          = FireBehavior.MaxBouncesPerFrame or DEFAULT_BEHAVIOR.MaxBouncesPerFrame
	local ResolvedCornerTimeThreshold         = FireBehavior.CornerTimeThreshold or DEFAULT_BEHAVIOR.CornerTimeThreshold
	local ResolvedCornerNormalDotThreshold    = FireBehavior.CornerNormalDotThreshold or DEFAULT_BEHAVIOR.CornerNormalDotThreshold
	local ResolvedCornerDisplacementThreshold = FireBehavior.CornerDisplacementThreshold or DEFAULT_BEHAVIOR.CornerDisplacementThreshold
	local ResolvedCosmeticBulletTemplate      = FireBehavior.CosmeticBulletTemplate
	local ResolvedCosmeticBulletContainer     = FireBehavior.CosmeticBulletContainer
	local ResolvedCosmeticBulletProvider      = FireBehavior.CosmeticBulletProvider
	local ResolvedVisualizeCasts              = if FireBehavior.VisualizeCasts ~= nil
		then FireBehavior.VisualizeCasts
		else DEFAULT_BEHAVIOR.VisualizeCasts

	-- Gravity is handled with a special fallback: if the caller's gravity vector
	-- has zero magnitude, we fall back to DEFAULT_GRAVITY (workspace gravity) and
	-- log an info message. A zero-magnitude gravity would produce a flat trajectory
	-- with no arc — physically correct for zero-gravity but easily caused by an
	-- accidental `Vector3.new(0, 0, 0)` that the caller did not intend. The log
	-- message surfaces this so the caller can verify their intent.
	local ResolvedGravity = DEFAULT_GRAVITY
	if FireBehavior.Gravity then
		if FireBehavior.Gravity.Magnitude > 0 then
			ResolvedGravity = FireBehavior.Gravity
		else
			Logger:Info("Fire: provided Gravity has zero magnitude — falling back to workspace gravity")
		end
	end

	-- Combine gravity and extra acceleration into a single vector stored on the
	-- trajectory. This pre-computation means SimulateCast never needs to add the
	-- two terms at runtime — each frame avoids one Vector3 addition per active cast.
	local EffectiveAcceleration = ResolvedGravity + ResolvedAcceleration

	-- ─── RaycastParams Pool ───────────────────────────────────────────────────

	-- Acquire a cloned RaycastParams from the pool. The pool clones the caller's
	-- params so pierce filter mutations do not propagate back to the caller's
	-- original object. If the pool is exhausted (returns nil), fall back to the
	-- caller's params directly — this means filter mutations will affect the
	-- original, which is a degraded mode but not a crash.
	local AcquiredParams = ParamsPooler.Acquire(ResolvedRaycastParams)
	if not AcquiredParams then
		Logger:Warn("Fire: RaycastParams pool exhausted — falling back to direct params")
		AcquiredParams = ResolvedRaycastParams
	end

	-- ─── VetraCast Construction ──────────────────────────────────────────────

	local VetraCast: VetraCast = {
		Alive     = true,
		Paused    = false,
		StartTime = OsClock(),

		Runtime = {
			TotalRuntime    = 0,
			DistanceCovered = 0,
			Trajectories    = {
				{
					StartTime       = 0,
					EndTime         = -1,
					Origin          = Context.Origin,
					-- Direction.Unit * Speed produces the initial velocity vector.
					-- Using .Unit ensures the direction is normalised before scaling,
					-- preventing callers from inadvertently encoding speed twice by
					-- passing a non-unit Direction with a non-1.0 Speed.
					InitialVelocity = Context.Direction.Unit * Context.Speed,
					Acceleration    = EffectiveAcceleration,
				}
			},
			ActiveTrajectory     = nil,
			BounceCallbackThread = nil,
			PierceCallbackThread = nil,
			PierceCount          = 0,
			PiercedInstances     = {},
			BounceCount          = 0,
			BouncesThisFrame     = 0,
			-- Initialised to -math.huge so Guard 1 in IsCornerTrap never fires on
			-- the first bounce, regardless of when it occurs relative to module load.
			LastBounceTime       = -math.huge,
			-- Initialised to ZERO_VECTOR so IsCornerTrap's HasPreviousBounceNormal
			-- and HasPreviousBouncePosition checks correctly identify the first
			-- bounce as having no prior context to compare against.
			LastBounceNormal     = ZERO_VECTOR,
			LastBouncePosition   = ZERO_VECTOR,
			IsActivelyResimulating = false,
			CancelResimulation   = false,
			-- CurrentSegmentSize starts at HighFidelitySegmentSize. The adaptive
			-- system will tune it up or down from this baseline over subsequent frames.
			CurrentSegmentSize   = ResolvedHighFidelitySegmentSize,
			CosmeticBulletObject = nil,
		},

		Behavior = {
			ResetPierceOnBounce		  = ResolvedResetPierceOnBounce,
			Acceleration              = EffectiveAcceleration,
			MaxDistance               = ResolvedMaxDistance,
			MinSpeed                  = ResolvedMinSpeed,
			Gravity                   = ResolvedGravity,
			RaycastParams             = AcquiredParams,
			-- Freeze a snapshot of the original filter list at fire time. This
			-- snapshot is used by Terminate() to reset the pooled params before
			-- returning them to the pool, ensuring each acquired params object
			-- starts with a clean filter. table.freeze prevents accidental mutation
			-- of the snapshot through any reference held elsewhere.
			OriginalFilter            = table.freeze(table.clone(
				ResolvedRaycastParams.FilterDescendantsInstances or {}
			)),
			CanPierceFunction         = ResolvedCanPierceFunction,
			MaxPierceCount            = ResolvedMaxPierceCount,
			PierceSpeedThreshold      = ResolvedPierceSpeedThreshold,
			PenetrationSpeedRetention = ResolvedPenetrationSpeedRetention,
			PierceNormalBias          = ResolvedPierceNormalBias,
			CanBounceFunction         = ResolvedCanBounceFunction,
			MaxBounces                = ResolvedMaxBounces,
			BounceSpeedThreshold      = ResolvedBounceSpeedThreshold,
			Restitution               = ResolvedRestitution,
			MaterialRestitution       = ResolvedMaterialRestitution,
			NormalPerturbation        = ResolvedNormalPerturbation,
			HighFidelitySegmentSize   = ResolvedHighFidelitySegmentSize,
			HighFidelityFrameBudget   = ResolvedHighFidelityFrameBudget,
			AdaptiveScaleFactor       = ResolvedAdaptiveScaleFactor,
			MinSegmentSize            = ResolvedMinSegmentSize,
			MaxBouncesPerFrame        = ResolvedMaxBouncesPerFrame,
			CornerTimeThreshold       = ResolvedCornerTimeThreshold,
			CornerNormalDotThreshold  = ResolvedCornerNormalDotThreshold,
			CornerDisplacementThreshold = ResolvedCornerDisplacementThreshold,
			VisualizeCasts            = ResolvedVisualizeCasts,
		},

		UserData = {},
	}

	-- Install CAST_STATE_METHODS as the metatable __index so GetPosition,
	-- SetVelocity, etc. are accessible directly on the VetraCast table without
	-- being stored per-instance. The metatable is a lightweight indirection —
	-- the actual method functions are shared across all cast instances.
	setmetatable(VetraCast, { __index = CAST_STATE_METHODS })
	-- ActiveTrajectory must point to the first element of Trajectories. Setting
	-- this after table construction (rather than inline) avoids a forward reference
	-- problem: the Trajectories array must exist before we can index it.
	VetraCast.Runtime.ActiveTrajectory = VetraCast.Runtime.Trajectories[1]

	-- ─── Cosmetic Bullet Setup ────────────────────────────────────────────────

	if ResolvedCosmeticBulletProvider ~= nil then
		if type(ResolvedCosmeticBulletProvider) ~= "function" then
			Logger:Warn("Fire: CosmeticBulletProvider must be a function — ignoring")
		else
			if ResolvedCosmeticBulletTemplate then
				-- Both provider and template were supplied. Template is ignored;
				-- the provider takes priority. Warn rather than error because this
				-- is a recoverable configuration — the bullet will still be created
				-- correctly via the provider. Callers who set a default template on
				-- a shared Behavior table and override it with a provider for specific
				-- types will hit this warning spuriously; they can silence it by not
				-- setting CosmeticBulletTemplate when they intend to use a provider.
				Logger:Warn("Fire: CosmeticBulletTemplate is ignored when CosmeticBulletProvider is set")
			end

			-- Time the provider call. The provider must be synchronous — it runs
			-- on the main game thread during Fire(), and any yield would suspend
			-- the entire weapon script. A result exceeding PROVIDER_TIMEOUT almost
			-- certainly indicates an accidental yield or a very slow Instance search.
			local ProviderStartTime         = OsClock()
			local ProviderSuccess, ProviderResult = pcall(ResolvedCosmeticBulletProvider)
			local ProviderElapsedSeconds    = OsClock() - ProviderStartTime

			if ProviderElapsedSeconds > PROVIDER_TIMEOUT then
				Logger:Warn(string.format(
					"Fire: CosmeticBulletProvider took %.2fs — avoid yielding inside it",
					ProviderElapsedSeconds
				))
			end

			if not ProviderSuccess then
				Logger:Warn("Fire: CosmeticBulletProvider errored: " .. tostring(ProviderResult))
			elseif not ProviderResult then
				Logger:Warn("Fire: CosmeticBulletProvider returned nil — no cosmetic bullet created")
			else
				ProviderResult.Parent = ResolvedCosmeticBulletContainer
				VetraCast.Runtime.CosmeticBulletObject = ProviderResult
			end
		end
	elseif ResolvedCosmeticBulletTemplate then
		-- Simple clone path: duplicate the template and parent it to the container.
		-- The clone is stored on Runtime so SimulateCast can orient it each frame
		-- and Terminate() can destroy it when the cast ends.
		local ClonedBullet = ResolvedCosmeticBulletTemplate:Clone()
		ClonedBullet.Parent = ResolvedCosmeticBulletContainer
		VetraCast.Runtime.CosmeticBulletObject = ClonedBullet
	end

	-- ─── Registration & Context Linking ──────────────────────────────────────

	-- Register the cast in this solver's _ActiveCasts array. Using self ensures
	-- the cast is placed in this instance's registry, not any other solver's.
	Register(self, VetraCast)

	-- Establish the bidirectional cast↔context weak map entries on this instance.
	-- Both directions are needed: the solver looks up Context from Cast when firing
	-- signals (CastToBulletContext), and Terminate() looks up Cast from Context
	-- when context:Terminate() is called (BulletContextToCast).
	self._CastToBulletContext[VetraCast] = Context
	self._BulletContextToCast[Context]    = VetraCast

	-- Inject the Terminate closure into the BulletContext's __solverData. This
	-- gives context:Terminate() a direct path back to this solver's Terminate()
	-- function without exposing the internal VetraCast table or the solver
	-- instance to weapon code. The closure captures self and VetraCast by
	-- upvalue — they are bound correctly even if multiple solver instances exist.
	if Context.__solverData and type(Context.__solverData) == "table" then
		Context.__solverData.Terminate = function()
			Terminate(self, VetraCast)
		end
	end

	return VetraCast
end

-- ─── GetSignals ───────────────────────────────────────────────────────────────

--[[
    Returns this solver instance's Signals table. Because signals are per-instance,
    a handler connected to self.Signals.OnHit will only receive events from casts
    registered on this specific solver — never from casts on a different solver
    instance. Consumers should call GetSignals() once at setup time and cache the
    returned table rather than calling it on every signal connection.
]]

function Vetra.GetSignals(self: Vetra)
	return self.Signals
end

-- ─── Destroy ───────────────────────────────────────────────────────────────

--[=[
    Vetra:Destroy

    Description:
        Tears down this solver instance completely. After this call the instance
        is inert — its frame loop is disconnected, all live casts are terminated,
        all signals are destroyed, and all internal state tables are cleared to
        release their references for garbage collection.

        The shutdown sequence is ordered deliberately. Each step creates a
        precondition for the steps that follow:

        Step 1 — Disconnect the frame loop:
            _StepProjectile must stop firing before any casts are terminated.
            If the frame event were left connected, a Heartbeat or RenderStepped
            that fires concurrently with the termination pass (possible in deferred
            signal contexts) could attempt to step a cast whose registry entry is
            mid-removal, producing a use-after-free on the _ActiveCasts array.
            Disconnecting first closes that window entirely.

        Step 2 — Terminate all live casts in reverse index order:
            Each Terminate() call delegates to Remove(), which performs a swap-
            remove on _ActiveCasts. Iterating forwards over the array while
            swap-remove is reshuffling it would cause the cursor to skip the
            element moved into a just-vacated slot. Iterating backwards avoids
            this: the swap always moves an element from a higher index into a
            lower one, so every element at or below the current cursor has already
            been visited and will not be revisited. Every live cast is therefore
            terminated exactly once regardless of how the array reshuffles beneath
            the loop.

            Terminating casts here also fires FireOnTerminated for each one,
            giving consumers a final cleanup callback consistent with normal
            cast expiry. Consumers should not assume that Destroy() will be called
            before the instance goes out of scope — they should handle OnTerminated
            for all cleanup work.

        Step 3 — Destroy all signals:
            Signal destruction disconnects every handler connected to OnHit,
            OnTravel, OnPierce, OnBounce, and OnTerminated. Without this step,
            handlers that close over game objects (e.g. a particle emitter
            referenced inside an OnTravel closure) would remain reachable via
            the signal's connection list and prevent GC collection of those objects.

        Step 4 — Nil all state tables:
            Clearing _ActiveCasts, _CastToBulletContext, _BulletContextToCast,
            Signals, and _FrameBudget releases the solver's strong references to
            all remaining objects. After this step, the solver instance itself
            holds no root references that could prevent the GC from reclaiming
            the full object graph.

    Parameters:
        self: Vetra
            The solver instance to destroy. Calling any method on self after
            Destroy() returns is undefined behaviour — the internal tables have
            been nilled and method calls will error.

    Returns:
        nil

    Notes:
        Destroy() is idempotent with respect to the frame event disconnect: if
        _FrameEvent is already nil (e.g. the connection was never established due
        to an error in Factory.new), the disconnect step is safely skipped.

        Destroy() does NOT protect against being called twice. The second call
        will attempt to iterate a nil _ActiveCasts table and error. If double-
        destruction is possible in your call sites, guard with a tombstone flag
        on the instance before calling Destroy().
]=]
function Vetra.Destroy(self: Vetra)
	if self._Destroyed then Logger:Error("Destroy : Vetra already destroyed") return end
	self._Destroyed = true
	
	-- Disconnect the frame loop so _StepProjectile stops firing
	if self._FrameEvent and typeof(self._FrameEvent) == "RBXScriptConnection" then
		self._FrameEvent:Disconnect()
		self._FrameEvent = nil
	end
	
	
	-- Terminate all live casts. Iterate backwards because Terminate calls
	-- Remove() which does a swap-remove — iterating forwards would cause
	-- the loop to skip elements as indices shift under it.
	local ActiveCasts = self._ActiveCasts
	for i = #ActiveCasts, 1, -1 do
		local Cast = ActiveCasts[i]
		if Cast and Cast.Alive then
			local ok, err = pcall(Terminate, self, Cast)
			if not ok then
				Logger:Warn("Destroy: Terminate failed — " .. tostring(err))
			end
		end
	end

	
	-- Destroy all signals so any lingering connections are cleaned up
	for _, Signal in self.Signals do
		Signal:Destroy()
	end

	-- Clear state to release references for GC
	self._ActiveCasts        = nil
	self._CastToBulletContext = nil
	self._BulletContextToCast = nil
	self.Signals             = nil
	self._FrameBudget        = nil
	
		
	-- Strip the metatable before freezing. Removing it severs the __index chain
	-- to Vetra's method table, so any post-destruction method call (e.g. a stale
	-- reference calling self:Fire() after Destroy()) errors immediately at the
	-- index site rather than reaching a method body that operates on nilled fields
	-- and producing a cryptic nil-index panic several call frames deeper.
	--
	-- table.freeze() is applied after the metatable is removed because Luau does
	-- not permit setmetatable() on a frozen table — attempting it would throw.
	-- Freezing the shell that remains makes all further writes to self an
	-- immediate error, preventing any code path from partially re-animating the
	-- instance by writing new fields onto the cleared table. Together the two
	-- calls convert the dead instance into a loud, fail-fast tombstone: reads
	-- error (no metatable), writes error (frozen), and both fail at the exact
	-- call site rather than propagating silent corruption into live simulation state.
	setmetatable(self, nil)
	table.freeze(self)
	return 
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

local Factory = {}
Factory.__type        = IDENTITY
Factory.BehaviorBuilder = BehaviorBuilder

--[=[
    Factory.new

    Description:
        Creates and returns a fully isolated Vetra instance. All mutable
        simulation state is stored on the returned instance table rather than at
        module scope, making each instance completely independent:

            _ActiveCasts:
                Flat integer array of all live VetraCast objects for this solver.
                Used by _StepProjectile for per-frame iteration and by Register/Remove
                for O(1) cast lifecycle management.

            _CastToBulletContext:
                Weak-key map from VetraCast → BulletContext. Used by every FireOn*
                helper to retrieve the context to pass to signal consumers. Weak keys
                allow GC to reclaim terminated cast objects without explicit cleanup.

            _BulletContextToCast:
                Weak-key map from BulletContext → VetraCast. Used by the Terminate
                closure injected into context.__solverData so context:Terminate()
                can reach the internal cast without exposing it publicly.

            _FrameBudget:
                Per-instance high-fidelity raycast time allocation. Reset at the
                start of each _StepProjectile call and consumed by sub-segment
                raycasts in ResimulateHighFidelity. Each instance receives the full
                GLOBAL_FRAME_BUDGET_MS independently.

            Signals:
                Per-instance set of Signal objects (OnHit, OnTravel, OnPierce,
                OnBounce, OnTerminated). Connections made on one instance's signals
                never receive events from another instance's casts.

        A RunService frame event connection is established for this instance
        at creation time. The connection lambda captures SolverInstance by upvalue
        so _StepProjectile always receives the correct instance. Multiple calls to
        Factory.new() produce multiple independent connections — this is correct
        and expected because each instance owns its own cast population.

    Returns:
        Vetra
            A new, fully isolated solver instance ready to accept Fire() calls.
            Multiple instances can exist concurrently without any shared state.
]=]

function Factory.new(): Vetra
	local SolverInstance = setmetatable({
		_ActiveCasts = {},

		-- Both maps use weak keys (__mode = "k") so that terminated cast objects
		-- and invalidated BulletContext objects can be garbage collected without
		-- requiring an explicit removal step. The GC will collect them automatically
		-- once all strong references are gone, even if these weak-key entries remain.
		_CastToBulletContext = setmetatable({}, { __mode = "k" }),
		_BulletContextToCast = setmetatable({}, { __mode = "k" }),

		-- Per-instance frame budget. Starts at zero; reset to the full allocation
		-- at the start of each _StepProjectile call. Two concurrent solvers each
		-- receive GLOBAL_FRAME_BUDGET_MS independently because they maintain
		-- separate _FrameBudget tables.
		_FrameBudget = { RemainingMicroseconds = 0 },

		-- Fresh Signal objects for this instance. Every signal consumer connects
		-- to these and receives only events from casts on this solver.
		Signals = {
			OnHit        = VeSignal.new(),
			OnTravel     = VeSignal.new(),
			OnPierce     = VeSignal.new(),
			OnBounce     = VeSignal.new(),
			OnTerminated = VeSignal.new(),
			OnPreBounce       = VeSignal.new(),
			OnMidBounce       = VeSignal.new(),
			OnPrePenetration  = VeSignal.new(),
			OnMidPenetration  = VeSignal.new(),
		},
		_FrameEvent = nil,
	}, { __index = Vetra })

	-- Determine the correct RunService event for this environment and connect
	-- the per-frame simulation loop. The lambda captures SolverInstance by
	-- upvalue — it is the only solver this connection will ever step.
	-- Server uses Heartbeat (post-physics, authoritative positions).
	-- Client uses RenderStepped (pre-render, correct cosmetic timing).
	local FrameEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	local Connection = FrameEvent:Connect(function(FrameDelta: number)
		_StepProjectile(SolverInstance, FrameDelta)
	end)

	SolverInstance._FrameEvent = Connection 
	return SolverInstance
end

-- ─── Type Exports ────────────────────────────────────────────────────────────

export type VetraCast = Type.VetraCast & typeof(CAST_STATE_METHODS)

export type VetraBehavior = {
	Acceleration                 : Vector3?,
	MaxDistance                  : number?,
	RaycastParams                : RaycastParams?,
	Gravity                      : Vector3?,
	MinSpeed                     : number?,
	CanPierceFunction            : ((Context: BulletContext.BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean)?,
	MaxPierceCount               : number?,
	PierceSpeedThreshold         : number?,
	PenetrationSpeedRetention    : number?,
	PierceNormalBias             : number?,
	CanBounceFunction            : ((Context: BulletContext.BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean)?,
	MaxBounces                   : number?,
	BounceSpeedThreshold         : number?,
	Restitution                  : number?,
	MaterialRestitution          : { [Enum.Material]: number }?,
	NormalPerturbation           : number?,
	HighFidelitySegmentSize      : number?,
	HighFidelityFrameBudget      : number?,
	AdaptiveScaleFactor          : number?,
	MinSegmentSize               : number?,
	MaxBouncesPerFrame           : number?,
	ResetPierceOnBounce          : boolean?,
	CornerTimeThreshold          : number?,
	CornerNormalDotThreshold     : number?,
	CornerDisplacementThreshold  : number?,
	CosmeticBulletTemplate       : BasePart?,
	CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : (() -> Instance?)?,
	VisualizeCasts               : boolean?,
}

export type Vetra = typeof(setmetatable({}, { __index = Vetra }))

-- ─── Module Return ───────────────────────────────────────────────────────────

--[[
    The module returns Factory rather than Vetra directly. Consumers call
    Factory.new() to obtain solver instances and access Factory.BehaviorBuilder
    for the fluent configuration builder. The protective metatable prevents
    accidental reads from nil keys (which would silently return nil and produce
    a confusing error later) and writes to the Factory table (which would corrupt
    the module's public interface). Both violations are logged immediately at the
    point of occurrence.
]]
return setmetatable(Factory, {
	__index = function(_, Key)
		Logger:Warn(string.format("Vetra: attempt to index nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Vetra: attempt to write '%s' to protected key '%s'",
			tostring(Value), tostring(Key)
		))
	end
})