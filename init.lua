--!native
--!optimize 2
--!strict
-- ─── HybridSolver ────────────────────────────────────────────────────────────
--[[
    HybridSolver — Analytic-trajectory projectile simulation module for Roblox.

    Architecture Overview:
        This module manages a flat array of active HybridCast objects, each
        representing one in-flight projectile. Every frame, _StepProjectile
        iterates the array and advances each projectile by the frame delta.

        Trajectory math is done analytically (not Euler integration), meaning
        the projectile position at any time T is computed directly from the
        kinematic formula:  P(t) = Origin + V0*t + 0.5*A*t²

        The analytic approach is deliberately chosen over Euler integration
        (P += V*dt; V += A*dt each frame) because Euler methods accumulate
        floating-point error at every step. Over long flight times or many
        bounces, this drift causes the simulated path to visibly diverge from
        the intended parabolic arc. With the analytic form, each position is
        computed directly from the segment's fixed parameters, so there is zero
        accumulated error regardless of frame count or flight duration.

        Raycasting is then performed between the analytically computed positions
        of the previous frame and the current frame. If a hit is detected, the
        module evaluates whether it qualifies for piercing, bouncing, or
        terminal termination — in that priority order. Pierce is checked first
        because a bullet that can pierce should never simultaneously bounce on
        the same surface; treating them as mutually exclusive prevents physically
        inconsistent outcomes.

    Context Integration:
        Every cast is paired with a BulletContext via a bidirectional weak map.
        The BulletContext is the public-facing object consumers interact with.
        This separation exists to enforce a hard boundary between internal solver
        state and the API surface exposed to weapon code. The solver drives the
        context's state each frame (_UpdateState) and reads context metadata
        (UserData, Id, etc.) when firing signals, so consumers always receive a
        fully-populated context alongside raw physics data.

    Signal Model:
        Signals are module-level (not per-cast). Consumers connect once and
        receive events from all active casts. Centralising signals this way
        avoids the connection/disconnection overhead of per-cast signals and
        eliminates a class of connection-leak bugs where consumers forget to
        disconnect when a cast ends. The context argument on every signal
        emission allows consumers to identify which cast fired it and dispatch
        accordingly.

    Performance Notes:
        - Swap-remove (O(1)) is used for the active cast registry so terminating
          a cast mid-array does not shift subsequent elements.
        - Weak maps allow GC to reclaim terminated cast objects without explicit
          cleanup calls.
        - RaycastParams are pooled to avoid per-fire allocation pressure on the
          GC, which matters when many bullets fire per second.
        - Analytic position avoids per-frame sqrt calls and accumulated error
          that Euler integration would introduce.
]]

-- ─── Services ────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ─── Module References ───────────────────────────────────────────────────────

--[[
    Utilities is a shared folder containing cross-cutting concerns (logging,
    signals, type checking). These are required from ReplicatedStorage so they
    are accessible on both server and client without duplication. Placing shared
    infrastructure here avoids maintaining separate server/client copies that
    could drift out of sync.
]]
local Utilities = ReplicatedStorage.Shared.Modules.Utilities

-- ─── Sub-Module Requires ─────────────────────────────────────────────────────
--[[
    ParamsPooler: Manages a pool of RaycastParams objects. Creating a new
    RaycastParams on every Fire() call would generate GC pressure when many
    bullets fire per second. The pool reuses existing params objects, mutating
    only the fields that differ per cast. Crucially, the pool clones the
    caller's params rather than using them directly — this ensures that the
    pierce system's filter list mutations (which add/remove instances to skip)
    never corrupt the caller's original RaycastParams.

    Visualizer: Optional debug renderer for cast segments, normals, bounces,
    and corner traps. All Visualizer calls are gated on Behavior.VisualizeCasts
    so there is zero runtime cost in production builds.

    Type: Luau type definitions for HybridCast, CastTrajectory, etc.
    Imported here purely for type annotations — no runtime cost. Keeping type
    definitions in a separate module avoids circular dependencies and lets
    other modules share the same types without requiring HybridSolver itself.

    BehaviorBuilder: Fluent typed configuration builder for HybridBehavior tables.
    Consumers chain namespace methods (:Physics(), :Bounce(), :Pierce(), etc.)
    and call :Build() to produce a validated, frozen HybridBehavior. HybridSolver
    does not depend on BehaviorBuilder internally — Fire() accepts any table
    matching HybridBehavior regardless of how it was constructed. BehaviorBuilder
    is re-exported on the Factory table so consumers require only HybridSolver
    and access the builder via HybridSolver.BehaviorBuilder.

    Signal: Lightweight event emitter. Used for module-level signals so
    consumers subscribe once rather than per-cast. This avoids the overhead
    of creating and connecting new signal objects for every fired bullet.

    LogService: Structured logger. Accepts an identity string (used as a prefix
    on all messages) and a boolean for whether to print in production builds.
    Structured logging makes it easy to filter solver messages in the output
    window independently of other systems.

    t: Runtime type checking utility. Used in Fire() to validate caller input
    before creating any state. Failing fast with a descriptive warning at the
    boundary is preferable to an obscure nil-index error deep inside SimulateCast.
]]
local ParamsPooler    = require(script.RaycastParamsPooler)
local Visualizer      = require(script.TrajectoryVisualizer)
local Type            = require(script.TypeDefinition)
local BehaviorBuilder = require(script.BehaviorBuilder)  

local BulletContext = require(script.BulletContext)

local Signal     = require(Utilities.Signal)
local LogService = require(Utilities.Logger)
local t          = require(Utilities.TypeCheck)

-- ─── Logger ──────────────────────────────────────────────────────────────────

--[[
    Module-level logger. The identity string "HybridSolver" is prefixed to
    every log message, making it easy to filter solver output in the console
    without sifting through messages from unrelated systems. The second argument
    (true) enables printing even in non-Studio builds, which is intentional:
    physics bugs that only manifest in live servers need to be observable without
    a Studio repro.
]]
local IDENTITY = "HybridSolver"
local Logger = LogService.new(IDENTITY, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

--[[
    Caching frequently called globals into upvalue locals is a standard Luau
    micro-optimisation. The Luau VM resolves upvalues via direct slot indices
    in the closure, whereas global lookups require a hash-table probe of the
    environment table on every access. For functions called hundreds of times
    per second across all active casts — such as os.clock() in corner-trap
    timing, math.max/clamp in adaptive segment sizing, and CFrame.new for
    cosmetic bullet orientation — this difference compounds into measurable
    savings at scale.

    Each global below is used on a hot path:
        OsClock      — called every bounce to record LastBounceTime, and in
                       ResimulateHighFidelity to measure per-frame wall time.
        CFrameNew    — called every frame per bullet to orient the cosmetic part.
        MathMax      — used in sub-segment count clamping.
        MathClamp    — used in sub-segment count clamping.
        MathFloor    — used to compute integer sub-segment counts from floats.
]]
local OsClock = os.clock
local CFrameNew = CFrame.new
local MathMax = math.max
local MathClamp = math.clamp

local MathFloor = math.floor

-- ─── Runtime Environment Detection ───────────────────────────────────────────

--[[
    Detecting server vs client at module load time determines which RunService
    event the simulation loop connects to. This decision is made once and stored
    rather than re-checked each frame.

    The server uses Heartbeat because it fires after Roblox's physics step has
    settled, giving authoritative positions for hit validation. The client uses
    RenderStepped because it fires before the frame is composited, ensuring that
    cosmetic bullet visuals are always positioned correctly when the GPU draws
    the frame. Using Heartbeat on the client would cause bullets to lag one frame
    behind their visual position, producing a subtle but noticeable trail offset.
]]
local IS_SERVER = RunService:IsServer()

-- ─── Constants ───────────────────────────────────────────────────────────────

--[[
    GLOBAL_FRAME_BUDGET_MS:
        The maximum total wall-clock time in milliseconds that HybridSolver is
        permitted to spend on high-fidelity sub-segment raycasts across all
        active casts in a single frame. Once FrameBudget.RemainingMicroseconds
        reaches zero, ResimulateHighFidelity stops processing further sub-segments
        for any cast in that frame. This prevents runaway simulation from starving
        rendering or other game logic. 4ms is chosen because it leaves roughly
        half a typical 60Hz frame (~8.3ms of script budget) for game logic.

    FrameBudget:
        A table (rather than a plain number) so it can be passed by reference to
        nested call sites without re-reading a module-level scalar. RemainingMicroseconds
        is reset to the full budget at the start of each _StepProjectile call and
        decremented by each sub-segment's measured cost.

    MAX_SUBSEGMENTS:
        Hard upper bound on sub-segments per cast per frame. Even with an
        extremely small CurrentSegmentSize and a very fast bullet, a single cast
        cannot consume more than 500 raycasts per frame. Without this cap, a bullet
        travelling at extreme speed with a tiny segment size could monopolise the
        entire frame budget and cause a visible hitch.

    PROVIDER_TIMEOUT:
        If CosmeticBulletProvider takes longer than this many seconds to return,
        a warning is logged. The provider runs synchronously during Fire() and
        must never yield — yielding here would stall the thread that called Fire(),
        which is typically a weapon script running on the game loop. Any provider
        call exceeding a few milliseconds is almost certainly doing something wrong
        (e.g. an accidental task.wait() or a slow Instance search).

    DEFAULT_GRAVITY:
        Cached at module load from workspace.Gravity and stored as a downward
        Vector3. We store the negated form (negative Y) directly so it can be
        added as an acceleration term without sign inversion at every call site.
        Reading workspace.Gravity at load time rather than each frame avoids
        repeated property lookups and ensures consistent gravity across a cast's
        lifetime even if workspace.Gravity changes mid-session.

    NUDGE:
        After a pierce or bounce, the new raycast origin must be displaced slightly
        past the contact surface along the ray or normal direction. Without this
        offset, the very next workspace:Raycast() call would originate on the surface
        itself and, due to floating-point imprecision, would immediately re-detect
        the same surface at near-zero distance. This would produce spurious double-hits
        or, in the bounce case, an instant re-bounce that sends the bullet backward.
        0.01 studs is small enough to be imperceptible but large enough to reliably
        clear floating-point surface-contact ambiguity.

    ZERO_VECTOR:
        Cached to avoid constructing Vector3.zero at every comparison site. This
        is also used as a sentinel value for "no previous bounce normal/position"
        in the Runtime table — checking `~= ZERO_VECTOR` is more readable than
        checking a separate boolean flag, and avoids an extra field in HybridCast.
]]
local GLOBAL_FRAME_BUDGET_MS = 4
local FrameBudget = {
	RemainingMicroseconds = 0,
}
local MAX_SUBSEGMENTS = 500
local PROVIDER_TIMEOUT = 3
local DEFAULT_GRAVITY = Vector3.new(0, -workspace.Gravity, 0)
local NUDGE = 0.01
local ZERO_VECTOR = Vector3.zero

-- ─── Default Behavior ────────────────────────────────────────────────────────

--[[
    DEFAULT_BEHAVIOR is the canonical fallback for every field in HybridBehavior.
    When Fire() is called without a full behavior table, any missing fields are
    resolved against this table. Its values are chosen to be safe and physically
    reasonable out of the box so that a caller can fire a bullet with minimal
    configuration and get sensible results.

    Design rationale for each default:

        Acceleration = zero:
            Extra non-gravity acceleration (e.g. rocket thrust) defaults to
            none. Gravity is handled separately via the Gravity field and added
            on top of Acceleration inside Fire(), keeping the two concerns distinct.

        MaxDistance = 500:
            Prevents bullets from flying indefinitely in open worlds. 500 studs
            covers most combat scenarios without letting stray bullets simulate
            forever in empty space.

        MinSpeed = 1:
            Bullets that have nearly stopped (e.g. after many energy-absorbing
            bounces) are culled cleanly. A threshold of 1 stud/second is
            imperceptibly slow and safe to cull without visual artifacts.

        HighFidelitySegmentSize = 0.5:
            Sub-segments are ~0.5 studs long. This means even a wall that is
            only 1 stud thick will be detected by at least one raycast, preventing
            tunnelling through thin surfaces for bullets moving at typical speeds.

        Restitution = 0.7:
            Retains 70% of kinetic energy per bounce. This gives a moderately
            bouncy feel similar to a rubber ball — energetic enough to look
            intentional but lossy enough that infinite bouncing is impossible.

        PenetrationSpeedRetention = 0.8:
            Each pierce absorbs 20% of the bullet's kinetic energy, simulating
            the mechanical work done in deforming the material. This makes
            deeper pierce chains progressively less dangerous, which is
            important for game balance.

        PierceNormalBias = 1.0:
            Requires the bullet to be travelling at least somewhat head-on
            into the surface (ImpactDot >= 0.0), meaning all approach angles
            are accepted. Lower values (closer to 0) restrict piercing to
            near-normal impacts, preventing a bullet skimming a surface at
            5 degrees from tunnelling through it.
]]
local DEFAULT_BEHAVIOR: HybridBehavior = {
	Acceleration 		      = Vector3.new(0, 0, 0),
	MaxDistance		 		  = 500,
	RaycastParams 		      = RaycastParams.new(),
	MinSpeed 		   		  = 1,
	CanPierceFunction 		  = nil,
	MaxPierceCount 			  = 3,
	PierceSpeedThreshold 	  = 50,
	Gravity 			 	  = Vector3.new(0,workspace.Gravity,0),
	PenetrationSpeedRetention = 0.8,
	PierceNormalBias          = 1.0,
	CanBounceFunction         = nil,
	MaxBounces                = 5,
	BounceSpeedThreshold      = 20,
	Restitution               = 0.7,
	MaterialRestitution       = {},
	NormalPerturbation        = 0.0,
	HighFidelitySegmentSize   = 0.5,
	HighFidelityFrameBudget   = 4,
	AdaptiveScaleFactor       = 1.5,
	MinSegmentSize            = 0.1,
	MaxBouncesPerFrame        = 10,
	CornerTimeThreshold       = 0.002,
	CornerNormalDotThreshold  = -0.85,
	CornerDisplacementThreshold = 0.5,
	CosmeticBulletTemplate    = nil,
	CosmeticBulletContainer   = nil,
	VisualizeCasts            = false,
}

-- ─── Physics Helpers ─────────────────────────────────────────────────────────

--[=[
    PositionAtTime

    Description:
        Computes the world-space position of a projectile at a given time T
        using the standard kinematic equation for constant acceleration:
            P(t) = Origin + V0*t + (1/2)*A*t²

        This is the analytic form — it calculates the exact answer for time T
        directly from the segment's fixed parameters (Origin, V0, A), without
        iterating through intermediate steps. This is deliberately preferred
        over Euler integration (P += V*dt; V += A*dt each frame) for two reasons:

        1. Euler accumulates floating-point error on every frame. Over long flight
           times or many frames, the simulated position drifts away from the true
           parabola. For a sniper bullet travelling 500 studs, even a small
           per-frame error multiplies into a visible arc distortion. The analytic
           form produces bit-identical results regardless of how many frames have
           elapsed, because each position is computed independently.

        2. Euler requires both position AND velocity to be tracked and updated
           together. The analytic form only requires the segment's immutable
           parameters (Origin, V0, A, StartTime), making trajectory state simpler
           and cheaper to store.

    Parameters:
        ElapsedTime: number
            Seconds elapsed since this trajectory segment started. This is always
            (Runtime.TotalRuntime - ActiveTrajectory.StartTime), not wall-clock
            time. After a bounce, a new trajectory segment starts with its own
            StartTime, so ElapsedTime correctly resets to zero for the new arc.

        TrajectoryOrigin: Vector3
            The world-space origin of this trajectory segment. For the initial
            fire, this is the muzzle position. After a bounce, it is the contact
            point offset by NUDGE along the surface normal to clear floating-point
            surface ambiguity.

        InitialVelocity: Vector3
            The velocity vector at the start of this trajectory segment, in
            studs/second. After a bounce, this is the reflected+scaled velocity
            produced by ResolveBounce.

        Acceleration: Vector3
            The constant acceleration acting on the bullet throughout this segment.
            Typically gravity (0, -workspace.Gravity, 0) combined with any extra
            Acceleration from the Behavior table. The combined value is computed
            once in Fire() and stored on the trajectory so this function never
            needs to perform the addition at the call site.

    Returns:
        Vector3
            The exact world-space position at ElapsedTime seconds into
            this trajectory segment.

    Notes:
        The t² / 2 form is mathematically identical to 0.5 * t^2. Luau's
        compiler optimises both forms the same way; the exponent notation is
        used here for readability.
]=]
local function PositionAtTime(
	ElapsedTime: number,
	TrajectoryOrigin: Vector3,
	InitialVelocity: Vector3,
	Acceleration: Vector3
): Vector3
	-- Standard constant-acceleration kinematic position formula.
	-- Each term is independent: the origin term is constant, the velocity term
	-- grows linearly, and the acceleration term grows quadratically. Luau
	-- evaluates Vector3 arithmetic left-to-right with operator precedence, so
	-- no additional parentheses are needed to get the correct result.
	return TrajectoryOrigin + InitialVelocity * ElapsedTime + Acceleration * (ElapsedTime ^ 2 / 2)
end

--[=[
    VelocityAtTime

    Description:
        Computes the velocity vector of a projectile at time T using the
        analytic first derivative of the kinematic position equation:
            V(t) = V0 + A*t

        Like PositionAtTime, this is analytic and produces exact results without
        iterative error. It is evaluated every frame because the current velocity
        is needed for multiple purposes:
            - Threshold comparisons: pierce speed, bounce speed, and MinSpeed
              culling all compare against CurrentVelocity.Magnitude.
            - Cosmetic orientation: CFrame.new(pos, pos + velocity.Unit) aligns
              the visible bullet part with its direction of travel.
            - Signal arguments: OnHit, OnBounce, and OnPierce all receive the
              velocity at the moment of the event so consumers can compute
              impact force or penetration depth.

    Parameters:
        ElapsedTime: number
            Seconds elapsed since this trajectory segment started. Same semantics
            as PositionAtTime.

        InitialVelocity: Vector3
            Velocity at the beginning of the trajectory segment.

        Acceleration: Vector3
            The constant acceleration (gravity + extra) for this segment.

    Returns:
        Vector3
            The exact velocity vector at ElapsedTime seconds into this segment.

    Notes:
        The returned vector is not normalised. Callers that need a unit direction
        should call .Unit themselves. Normalising here would discard the magnitude,
        which most callers need for speed threshold checks.
]=]
local function VelocityAtTime(
	ElapsedTime: number,
	InitialVelocity: Vector3,
	Acceleration: Vector3
): Vector3
	-- First derivative of the kinematic position equation. Under constant
	-- acceleration, velocity changes linearly with time. V0 is the velocity
	-- at the segment's start; A*t is the cumulative velocity change due to
	-- acceleration over elapsed time.
	return InitialVelocity + Acceleration * ElapsedTime
end

-- ─── Trajectory Modifier ─────────────────────────────────────────────────────

--[=[
    ModifyTrajectory

    Description:
        Applies a mid-flight change to one or more of a cast's kinematic
        parameters (position, velocity, or acceleration). This is the shared
        implementation used by all of the CAST_STATE_METHODS setters
        (SetPosition, SetVelocity, SetAcceleration, AddPosition, etc.).

        There are two cases:
            1. The change is being applied in the same simulation tick that
               started the current trajectory segment (StartTime == TotalRuntime).
               In this case, we mutate the active trajectory in place. No new
               segment is created because the segment hasn't been simulated yet,
               so there is no history to preserve.

            2. The change is being applied after the current segment has already
               been partially simulated (StartTime < TotalRuntime). In this case,
               we close the current segment by recording its EndTime, compute the
               analytically exact position and velocity at the current moment as
               the handoff point, and open a new trajectory segment starting from
               those values. This preserves the recorded history of the bullet's
               full flight path while correctly redirecting it from this point
               forward.

        CancelResimulation is set to true when a new segment is created. This
        signal tells ResimulateHighFidelity's sub-segment loop to stop processing
        sub-segments on the old trajectory, because continuing to simulate an
        outdated arc after a mid-flight change would produce physically incorrect
        raycast positions.

        Input validation is performed before any state is mutated. If any supplied
        vector contains NaN or infinity (which would propagate silently through
        all subsequent kinematic computations and produce nonsensical positions),
        the modification is aborted with a warning and the cast continues on its
        previous trajectory unchanged.

    Parameters:
        Cast: HybridCast
            The cast whose trajectory is being modified.

        Velocity: Vector3?
            New initial velocity for the (possibly new) segment, or nil to keep
            the current velocity at the moment of the change.

        Acceleration: Vector3?
            New constant acceleration for the (possibly new) segment, or nil to
            inherit the current trajectory's acceleration.

        Position: Vector3?
            New origin for the (possibly new) segment, or nil to use the
            analytically computed position at the current time.

    Notes:
        Passing nil for all three parameters is a no-op: ModifyTrajectory will
        create a new segment that is kinematically identical to the current one,
        wasting a table allocation. Callers should always supply at least one
        non-nil parameter.
]=]
local function ModifyTrajectory(Cast: HybridCast, Velocity: Vector3?, Acceleration: Vector3?, Position: Vector3?)
	-- Guard against NaN and infinity in all input vectors before touching any
	-- state. A NaN velocity would silently corrupt every subsequent PositionAtTime
	-- call for this cast, producing positions at (nan, nan, nan) and preventing
	-- the cast from ever terminating normally. Aborting here avoids that failure
	-- mode entirely and gives the caller a clear diagnostic.
	if Velocity and not t.Vector3(Velocity)     then
		Logger:Warn("ModifyTrajectory: Velocity contains NaN or inf — ignoring")
		return
	end
	if Acceleration and not t.Vector3(Acceleration) then
		Logger:Warn("ModifyTrajectory: Acceleration contains NaN or inf — ignoring")
		return
	end
	if Position and not t.Vector3(Position)     then
		Logger:Warn("ModifyTrajectory: Position contains NaN or inf — ignoring")
		return
	end

	local Runtime = Cast.Runtime
	local Last = Runtime.ActiveTrajectory

	if Last.StartTime == Runtime.TotalRuntime then
		-- Case 1: The modification is happening at the very start of the current
		-- segment (no simulation time has elapsed on it yet). Mutate in place
		-- rather than creating a new segment, since there is no recorded history
		-- to preserve for this segment. This is the zero-cost fast path.
		Last.Origin          = Position     or Last.Origin
		Last.InitialVelocity = Velocity     or Last.InitialVelocity
		local NewAccel       = Acceleration or Last.Acceleration
		Last.Acceleration    = NewAccel
	else
		-- Case 2: The current segment has been partially simulated. We must
		-- close it by recording its end time, then open a new segment from the
		-- current analytically exact position and velocity. This ensures the
		-- Trajectories history remains accurate for any consumer that replays it.
		Last.EndTime = Runtime.TotalRuntime

		-- Compute the handoff point analytically to avoid Euler drift at the seam.
		-- These are the exact position and velocity the bullet had at the moment
		-- the caller requested the change.
		local Elapsed = Runtime.TotalRuntime - Last.StartTime
		local EndPos  = PositionAtTime(Elapsed, Last.Origin, Last.InitialVelocity, Last.Acceleration)
		local EndVel  = VelocityAtTime(Elapsed, Last.InitialVelocity, Last.Acceleration)
		local NewAccel = Acceleration or Last.Acceleration

		-- The new segment starts from the current moment in time, with the
		-- caller-supplied overrides (or the computed handoff values if nil).
		local NewTrajectory: Type.CastTrajectory = {
			StartTime       = Runtime.TotalRuntime,
			EndTime         = -1,
			Origin          = Position or EndPos,
			InitialVelocity = Velocity or EndVel,
			Acceleration    = NewAccel,
		}

		table.insert(Runtime.Trajectories, NewTrajectory)
		Runtime.ActiveTrajectory   = NewTrajectory
		-- Signal ResimulateHighFidelity to abandon the current sub-segment loop,
		-- because the trajectory the sub-segments were stepping no longer exists.
		Runtime.CancelResimulation = true
	end
end


--[[
    CAST_STATE_METHODS defines the instance methods available on a HybridCast
    table via its metatable __index. These are exposed to consumers through the
    BulletContext API, allowing weapon scripts to read or modify a bullet's
    current kinematic state mid-flight.

    All mutation methods delegate to ModifyTrajectory, which handles the
    open/close segment logic in one place. This avoids duplicating the
    "mutate in place vs. create new segment" decision across six separate
    setters, each of which would need to get it right independently.

    The Add* variants read the current analytic value and pass it as the new
    value plus a delta. They do not call ModifyTrajectory twice — the Get*
    call is a pure read with no side effects, so combining the result into a
    single ModifyTrajectory call is both cheaper and atomic (no intermediate
    state is ever written).
]]
local CAST_STATE_METHODS = {

	-- Returns the bullet's current world-space position by evaluating the
	-- analytic position formula at the current elapsed time within the active
	-- segment. This is always accurate to the current simulation time regardless
	-- of when in the frame it is called.
	GetPosition = function(self : HybridCast)
		local Traj    = self.Runtime.ActiveTrajectory
		local Elapsed = self.Runtime.TotalRuntime - Traj.StartTime
		return PositionAtTime(Elapsed, Traj.Origin, Traj.InitialVelocity, Traj.Acceleration)
	end,
	
	-- Resets the three corner-trap sentinel fields on Runtime back to their
	-- Fire()-time values. This is necessary after any programmatic mid-flight
	-- velocity change (e.g. SetVelocity, AddVelocity) that deliberately reverses
	-- or sharply redirects the bullet, because the corner trap detector in
	-- IsCornerTrap compares the new travel direction against the most recent
	-- bounce normal and position. A sharp reversal will almost always satisfy
	-- Guard 2 (opposing normals) or Guard 3 (spatial proximity) even though no
	-- actual degenerate geometry is involved, causing the cast to terminate
	-- immediately after the velocity change.
	--
	-- Resetting here tells IsCornerTrap that this is effectively a fresh start:
	--   LastBounceTime     = -math.huge  →  Guard 1 (temporal) never fires on
	--                                       the next bounce regardless of timing.
	--   LastBounceNormal   = ZERO_VECTOR →  Guard 2 (normal opposition) is skipped
	--                                       because HasPreviousBounceNormal is false.
	--   LastBouncePosition = ZERO_VECTOR →  Guard 3 (spatial proximity) is skipped
	--                                       because HasPreviousBouncePosition is false.
	--
	-- Note: this does NOT reset BounceCount or BouncesThisFrame. Those counters
	-- track lifetime and per-frame bounce budgets respectively and should not be
	-- affected by a velocity change — the bullet has still bounced that many times.
	ResetBounceState = function(self: HybridCast)
		self.Runtime.LastBounceNormal   = Vector3.zero
		self.Runtime.LastBouncePosition = Vector3.zero
		self.Runtime.LastBounceTime     = -math.huge
	end,
	
	-- Returns the bullet's current velocity vector by evaluating the analytic
	-- derivative formula. The magnitude of this vector is the current speed in
	-- studs/second. This is used by consumers who need to compute impact force
	-- or determine whether to apply a damage falloff at range.
	GetVelocity = function(self : HybridCast)
		local Traj    = self.Runtime.ActiveTrajectory
		local Elapsed = self.Runtime.TotalRuntime - Traj.StartTime
		return VelocityAtTime(Elapsed, Traj.InitialVelocity, Traj.Acceleration)
	end,

	-- Returns the constant acceleration vector for the active segment. This is
	-- the combined gravity + extra acceleration value stored on the trajectory,
	-- not workspace.Gravity. Consumers can use this to display the effective
	-- gravity field for a given projectile type.
	GetAcceleration = function(self : HybridCast)
		return self.Runtime.ActiveTrajectory.Acceleration
	end,

	-- Teleports the bullet to a new world-space position without changing its
	-- velocity or acceleration. Opens a new trajectory segment from that position
	-- if simulation time has already elapsed on the current segment.
	SetPosition = function(self : HybridCast, Position: Vector3)
		ModifyTrajectory(self, nil, nil, Position)
	end,

	-- Changes the bullet's velocity to the given vector. The new velocity becomes
	-- the InitialVelocity of either the current segment (if it just started) or
	-- a new segment opened at the current position. Acceleration is inherited.
	SetVelocity = function(self : HybridCast, Velocity: Vector3)
		ModifyTrajectory(self, Velocity, nil, nil)
	end,

	-- Replaces the bullet's constant acceleration for future simulation. Because
	-- acceleration is constant within a segment, changing it requires starting
	-- a new segment unless the current one has zero elapsed time.
	SetAcceleration = function(self, Acceleration: Vector3)
		ModifyTrajectory(self, nil, Acceleration, nil)
	end,

	-- Translates the bullet by an offset vector in world space. Internally this
	-- reads the current analytic position and adds the offset, then calls
	-- ModifyTrajectory with the result. The read-then-write is atomic in the
	-- sense that no frame tick occurs between the two operations (we are on the
	-- simulation thread), so the computed position is always consistent.
	AddPosition = function(self, Offset: Vector3)
		ModifyTrajectory(self, nil, nil, self:GetPosition() + Offset)
	end,

	-- Adds a delta to the bullet's current velocity. Useful for impulse effects
	-- such as an explosion knockback applied mid-flight. The current velocity is
	-- read analytically before the delta is applied.
	AddVelocity = function(self, Delta: Vector3)
		ModifyTrajectory(self, self:GetVelocity() + Delta, nil, nil)
	end,

	-- Adds a delta to the bullet's constant acceleration. Useful for variable
	-- wind or thrust that builds up over time by making repeated AddAcceleration
	-- calls each frame.
	AddAcceleration = function(self, Delta: Vector3)
		ModifyTrajectory(self, nil, self:GetAcceleration() + Delta, nil)
	end,

}
-- ─── Active Cast Registry ────────────────────────────────────────────────────

--[[
    CastToBulletContext and BulletContextToCast form a bidirectional weak map
    between internal HybridCast objects and public-facing BulletContext objects.

    Why bidirectional?
        - CastToBulletContext lets the frame loop look up the context from a
          cast, so signals can be fired with the context as the first argument.
          Without it, every signal call site would need to crawl the BulletContext
          API to find the matching context, which is O(n) without a reverse map.
        - BulletContextToCast lets external callers (e.g. a weapon that holds a
          BulletContext reference) reach the cast state if they need to pause,
          introspect, or terminate it directly. This avoids forcing consumers to
          store both the context and the cast separately.

    Why weak keys (__mode = "k")?
        When a cast terminates, its HybridCast table is removed from _ActiveCasts
        and all other strong references are cleared. If these maps used strong
        references as keys, the HybridCast would be kept alive by the map itself
        even after termination — a memory leak that grows with every fired bullet.
        Weak keys allow the GC to collect the HybridCast naturally once no other
        code holds a strong reference. The BulletContext side uses weak values
        for the same reason: once the context is no longer held by weapon code,
        the mapping entry should not prevent its collection.
]]
local CastToBulletContext : {[HybridCast] : BulletContext.BulletContext} = setmetatable({}, { __mode = "k" })
local BulletContextToCast : {[BulletContext.BulletContext] : HybridCast} = setmetatable({}, { __mode = "k" })

--[[
    _ActiveCasts: The flat array of all currently simulated HybridCast objects.
    Iteration over this array happens every frame in _StepProjectile.

    A flat array is chosen over a dictionary for two reasons:
        1. Cache locality: iterating indices 1..N over a contiguous array is
           friendlier to the CPU cache than dictionary key enumeration, which
           follows hash chain pointers into scattered memory.
        2. O(1) swap-remove: removing an element from the middle of an array
           by swapping it with the last element and shrinking the length by one
           avoids the O(n) element-shifting cost of table.remove. This pattern
           requires storing each cast's current index on itself (_registryIndex),
           which is maintained by Register() and Remove().
]]
local _ActiveCasts = {}


--[[
    _FrameEvent: The RunService event the simulation loop connects to.

    Server uses Heartbeat (fires after Roblox physics, before replication)
    for authoritative hit detection — positions are settled and consistent.

    Client uses RenderStepped (fires before rendering) so that cosmetic bullet
    visuals are always updated to their new positions before the frame is drawn.
    If we used Heartbeat on the client, the cosmetic part would visually lag one
    frame behind the computed position, producing a subtle but persistent trail
    offset on fast-moving bullets.
]]
local _FrameEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped

-- ─── Registry Helpers ────────────────────────────────────────────────────────

--[=[
    Register

    Description:
        Inserts a HybridCast into the _ActiveCasts array and records its current
        array index on the cast itself via the _registryIndex field.

        The stored index is what makes O(1) swap-remove possible in Remove():
        instead of linearly searching _ActiveCasts for the cast to remove (O(n)),
        we read its pre-stored index directly and jump to that slot. This is
        critical when many casts terminate in the same frame — e.g. a shotgun
        blast where all pellets hit simultaneously — because O(n) removal would
        compound to O(n²) across a batch of terminations.

    Parameters:
        CastToRegister: {}
            The HybridCast table to register. The _registryIndex field will be
            written onto this table, so the caller must not rely on the table
            being unmodified after this call. Only tables are accepted; any other
            type is silently rejected with a warning.

    Returns:
        boolean
            True if registration succeeded. False if the input was not a table,
            or if the cast was already registered (detected by the presence of
            a _registryIndex field). Double-registration is treated as a bug in
            the caller, not a recoverable condition.

    Notes:
        The _registryIndex is written directly onto the HybridCast table rather
        than stored in a separate map. This is idiomatic Luau for simulation
        objects — the table is a mutable record, and embedding metadata directly
        avoids the hash-table overhead of a parallel lookup structure.
]=]
local function Register(CastToRegister: {_registryIndex : number?} | any): boolean
	if not t.table(CastToRegister) then
		Logger:Warn("Register: CastToRegister must be a table")
		return false
	end

	-- A cast that already has _registryIndex set was previously registered and
	-- not properly removed before re-registration was attempted. This indicates
	-- a logic error in the caller (e.g. calling Fire() on an already-live cast).
	-- Reject rather than silently overwrite the index, which would corrupt the
	-- registry and cause the old entry at that index to become unreachable.
	if CastToRegister._registryIndex then
		Logger:Warn("Register: cast already registered")
		return false
	end
	-- Append to the end of the array. The index is #_ActiveCasts + 1 rather than
	-- #_ActiveCasts because the cast has not been inserted yet at this point.
	-- Storing this index on the cast is what makes O(1) removal possible —
	-- Remove() reads _registryIndex to find the cast's position without searching.
	local RegistryIndex = #_ActiveCasts + 1
	CastToRegister._registryIndex = RegistryIndex
	_ActiveCasts[RegistryIndex] = CastToRegister

	return true
end

--[=[
    Remove

    Description:
        Removes a HybridCast from _ActiveCasts using the O(1) swap-remove pattern:
        the element to remove is overwritten with the last element in the array,
        then the array is shortened by one. This preserves contiguity without
        shifting elements, making it O(1) regardless of array size.

        The swapped element's _registryIndex is updated immediately to reflect
        its new position. If this update were omitted, the next Remove() call on
        that element would read a stale index pointing to the wrong slot and
        corrupt the registry.

    Parameters:
        CastToRemove: { _registryIndex: number? }
            The HybridCast to remove. Must have been registered via Register().
            A missing _registryIndex indicates the cast was never registered or
            was already removed — both are treated as errors.

    Returns:
        boolean
            True on success. False if preconditions fail (not a table, empty
            registry, or missing index).

    Notes:
        The frame loop in _StepProjectile iterates from index 1 to ActiveCount
        (snapshotted before the loop begins) in ascending order. When a cast at
        index I is removed and replaced by the cast from index N (the last one),
        the moved cast occupies index I — a position that will be visited later
        in the same iteration (since I < N for any non-last element). This means
        the moved cast is guaranteed to be processed in the same frame it was
        moved, with no skipped frames. Casts that have already been processed
        (indices < I) can never be moved into a position that will be re-visited,
        so no cast is ever simulated twice in a single frame as a result of a swap.

        The edge case where the element to remove is the last element in the array
        is handled explicitly. In that case, the "swap" would move the element
        onto itself and then nil it out — which would lose it from the registry.
        Detecting this case and skipping the swap avoids that bug.
]=]
local function Remove(CastToRemove: { _registryIndex: number? } | any): boolean
	if not t.table(CastToRemove) then
		Logger:Warn("Remove: CastToRemove must be a table")
		return false
	end
	if #_ActiveCasts == 0 then
		Logger:Warn("Remove: no active casts to remove from")
		return false
	end
	if not CastToRemove._registryIndex then
		Logger:Warn("Remove: cast has no _registryIndex — was it registered?")
		return false
	end
	--[[
		Swap-remove invariant: after the operation, the array remains densely
		packed (no holes) and every element's _registryIndex correctly reflects
		its current position. This is maintained by:
		    a) Writing the last element into the removed slot.
		    b) Updating the moved element's _registryIndex to the new slot index.
		    c) Nilling the last slot (now vacated by the move).
		    d) Clearing the removed cast's _registryIndex to nil (it is no longer
		       in the registry and should not be used as an array index).

		If _StepProjectile is currently iterating and terminates a cast at index I:
		- The cast from index N moves to index I.
		- The iteration cursor is at I and will advance to I+1 next.
		- The moved cast (now at I) was previously at N, which has not been
		  visited yet (since N > I for any non-last removal).
		- Therefore the moved cast WILL be visited at index I in this same frame.
		- No cast is skipped or double-processed.
	]]
	local RemoveIndex = CastToRemove._registryIndex
	local LastIndex = #_ActiveCasts
	local LastRegisteredCast = _ActiveCasts[LastIndex]

	-- Edge case: the cast being removed is already the last element.
	-- Swapping it with itself would work mathematically but would then nil out
	-- the moved element at LastIndex, which is the same slot — losing the entry.
	-- Detect and short-circuit this case.
	if RemoveIndex == LastIndex then
		_ActiveCasts[LastIndex] = nil
		CastToRemove._registryIndex = nil
		return true
	end

	-- General case: overwrite the removed slot with the last element, update
	-- its index to reflect the new position, then shrink the array by one.
	_ActiveCasts[RemoveIndex] = LastRegisteredCast
	LastRegisteredCast._registryIndex = RemoveIndex
	_ActiveCasts[LastIndex] = nil
	CastToRemove._registryIndex = nil

	return true
end

-- ─── Termination ─────────────────────────────────────────────────────────────

--[=[
    Terminate

    Description:
        Fully shuts down a cast: marks it dead, releases pooled resources,
        destroys cosmetic objects, severs the bidirectional context map entries,
        and removes it from the active registry.

        The order of operations here is deliberate and important:

        1. Set Alive = false FIRST. If any step below triggers a re-entrant call
           to Terminate (e.g. a signal handler that calls context:Terminate(), or
           a coroutine that resumes inside a signal), the re-entrant call will see
           Alive = false and return immediately. Without this guard, double
           termination could release pooled RaycastParams twice, double-destroy the
           cosmetic object, or attempt to Remove() a cast that is no longer in the
           registry — all of which are unsafe.

        2. Reset and release RaycastParams. The pierce system mutates the filter
           list on the pooled params during its lifetime. Before returning params
           to the pool, the filter is reset to the original snapshot (OriginalFilter)
           so the next cast that acquires these params receives a clean slate.

        3. Destroy the cosmetic bullet. This must happen before the context is
           terminated so that any signal handler connected to OnTerminated can
           still access the context's state (position, velocity) for final VFX
           positioning without the cosmetic object already being gone.

        4. Sever the bidirectional map. Both directions must be cleared together:
           leaving one direction populated would hold a dangling reference to a
           dead object, preventing GC from collecting it and potentially causing
           use-after-free if code later looks up the surviving reference.

        5. Remove from _ActiveCasts last. Remove() reads _registryIndex, which is
           still valid at this point. If Remove() were called earlier (e.g. before
           the context is cleaned up), the slot might be immediately overwritten
           by the next Register() call, creating a race condition.

    Parameters:
        Cast: HybridCast
            The cast to terminate. If Alive is already false, this function
            returns immediately — termination is idempotent by design so
            callers do not need to guard against double-termination themselves.

    Notes:
        Termination is always initiated by the solver internally (distance expiry,
        speed expiry, terminal hit, corner trap). External code terminates a cast
        by calling context:Terminate(), which delegates to the Terminate function
        stored in Context.__solverData — ultimately calling this function.
]=]
local function Terminate(Cast: HybridCast)
	-- Idempotency guard. This can be hit if a signal handler calls
	-- context:Terminate() after the solver has already decided to terminate
	-- the cast in the same frame (e.g. a terminal hit fires OnHit, the handler
	-- calls Terminate, and then SimulateCast's own Terminate call runs).
	-- The second call is silently ignored rather than erroring.
	if not Cast.Alive then return end

	-- Mark dead FIRST so any re-entrant path (signal handlers, coroutine resumes)
	-- sees a dead cast and takes no action. This is the critical invariant that
	-- makes all subsequent steps safe to perform without re-entrancy guards.
	Cast.Alive = false

	-- Reset the filter list on the pooled RaycastParams to the original snapshot
	-- before returning them to the pool. The pierce system accumulates excluded
	-- instances in this list over the cast's lifetime. Without this reset, the
	-- next cast that acquires these params would inherit a contaminated filter
	-- that ignores instances from a previous bullet's pierce chain — causing
	-- bullets to pass through objects they should collide with.
	Cast.Behavior.RaycastParams.FilterDescendantsInstances = 
		table.clone(Cast.Behavior.OriginalFilter)

	-- Return params to the pool. Failing to release here would gradually exhaust
	-- the pool, causing Fire() to fall back to direct (non-pooled) params and
	-- increasing per-frame GC pressure.
	ParamsPooler.Release(Cast.Behavior.RaycastParams)

	-- Destroy the cosmetic bullet. Nilling the reference after destruction allows
	-- the GC to collect the Instance object immediately rather than waiting for
	-- the next GC cycle while the table slot still holds a reference.
	if Cast.Runtime.CosmeticBulletObject then
		Cast.Runtime.CosmeticBulletObject:Destroy()
		Cast.Runtime.CosmeticBulletObject = nil
	end

	-- Sever both directions of the bidirectional weak map simultaneously.
	-- Severing only one direction would leave a dangling half-reference that
	-- prevents GC from collecting the surviving object and could cause incorrect
	-- lookups if code checks the map after termination.
	local LinkedContext = CastToBulletContext[Cast]
	if LinkedContext then
		-- Notify the BulletContext that its underlying cast has ended. The context
		-- marks itself dead and clears its __solverData.Terminate reference,
		-- preventing future calls to context:Terminate() from invoking this
		-- function on a cast that is already gone.
		if LinkedContext.Alive then
			LinkedContext:Terminate()
		end
		BulletContextToCast[LinkedContext] = nil
		CastToBulletContext[Cast] = nil
	end

	-- Remove from the active array last. _registryIndex is still valid here
	-- because nothing above has modified it. After this call, the cast's slot
	-- in _ActiveCasts is either nilled (if it was the last element) or occupied
	-- by a different cast (swapped from the end).
	Remove(Cast)
end

-- ─── Module-Level Signals ────────────────────────────────────────────────────

--[[
    All signals are declared at module scope rather than per-cast. This is an
    intentional architectural decision driven by two goals:

    1. Connection lifecycle simplicity: per-cast signals would require weapon
       code to connect on every Fire() call and disconnect on every termination.
       Forgetting to disconnect on termination would accumulate dead connections
       that are never garbage-collected (Signal objects typically hold strong
       references to connected functions). Module-level signals are connected
       once during weapon initialisation and never need to be disconnected.

    2. Unified dispatch point: having a single signal for all casts lets a weapon
       script handle events from all of its bullets in one handler, dispatching
       by context identity rather than managing N separate signal objects. This
       mirrors how Roblox's built-in RemoteEvent model works.

    Signal contracts — every signal passes the BulletContext as its first argument
    so consumers can identify the bullet and access its UserData and current state:

        OnHit (Context, Result: RaycastResult?, Velocity: Vector3)
            Fired when the bullet reaches a terminal state. Result is the
            RaycastResult at the hit surface, or nil if the bullet expired by
            distance or minimum speed (non-collision terminations). Consumers
            can distinguish impact from expiry by checking `Result ~= nil`.

        OnTravel (Context, Position: Vector3, Velocity: Vector3)
            Fired every frame as the bullet advances. Used for trail effects,
            sound attenuation curves, hit-detection preview, or mid-flight state
            polling. OnTravel uses Fire (not FireSafe) because it fires on every
            active bullet every frame — FireSafe's deep-copy overhead is
            unacceptable on this hot path. Consumers must not throw inside
            OnTravel handlers.

        OnPierce (Context, Result: RaycastResult, Velocity: Vector3, PierceCount: number)
            Fired each time the bullet successfully pierces an instance.
            PierceCount is the cumulative total including this pierce, incremented
            before the signal fires so handlers always see the updated count.

        OnBounce (Context, Result: RaycastResult, Velocity: Vector3, BounceCount: number)
            Fired each time the bullet bounces off a surface. BounceCount is
            cumulative and incremented before firing, consistent with OnPierce.

        OnTerminated (Context)
            Fired unconditionally just before the cast is terminated, regardless
            of the termination reason (impact, expiry, corner trap). This is the
            reliable cleanup hook — consumers can use it to play impact sounds,
            return bullet visuals to a pool, or mark a pending hit as resolved.
]]


--[[
    OnTravel uses Fire (not FireSafe) intentionally — it fires every frame
    and FireSafe's deep-copy overhead is unacceptable on this hot path.
    Consumers must ensure their OnTravel handlers do not throw.
]]
local Signals = {
	OnHit = Signal.new(),
	OnTravel = Signal.new(),
	OnPierce = Signal.new(),
	OnBounce = Signal.new(),
	OnTerminated = Signal.new(),
}

-- ─── Signal Emission Helpers ─────────────────────────────────────────────────

--[[
    These helpers centralise two concerns that every signal emission site shares:

    1. The CastToBulletContext lookup — every signal must pass the BulletContext
       as its first argument, which requires looking it up from the cast. Doing
       this lookup inline at every call site would be verbose and would scatter
       the "is the context still live?" guard across the codebase.

    2. The context state update (_UpdateState) — consumers polling
       context.Position or context.Velocity between frames expect them to reflect
       the bullet's state at the time of the event, not the previous frame.
       Updating here ensures the context is always current when the signal fires,
       regardless of which call site triggered the emission.

    The nil-context early return handles the edge case where Terminate() has
    already severed the CastToBulletContext mapping (e.g. if a signal handler
    called context:Terminate(), which ran Terminate(), which cleared the map)
    before another signal tries to fire in the same frame. Silently dropping
    the signal is correct here — the cast is already dead from the consumer's
    perspective.
]]

local function FireOnHit(Cast: HybridCast, HitResult: RaycastResult?, HitVelocity: Vector3)
	local Context = CastToBulletContext[Cast]
	if not Context then return end
	-- Snap the context position to the hit point so consumers reading
	-- context.Position in their OnHit handler get the surface contact point,
	-- not the bullet's position from the previous frame.
	if HitResult then
		Context:_UpdateState(HitResult.Position, HitVelocity, Cast.Runtime.DistanceCovered)
	end
	Signals.OnHit:FireSafe(Context, HitResult, HitVelocity)
end

local function FireOnTravel(Cast: HybridCast, TravelPosition: Vector3, TravelVelocity: Vector3)
	local Context = CastToBulletContext[Cast]
	if not Context then return end
	-- Update the context every frame so external code polling context.Position
	-- between signal connections always sees the current bullet position without
	-- needing to subscribe to OnTravel explicitly.
	Context:_UpdateState(TravelPosition, TravelVelocity, Cast.Runtime.DistanceCovered)
	Signals.OnTravel:Fire(Context, TravelPosition, TravelVelocity)
end

local function FireOnPierce(Cast: HybridCast, PierceResult: RaycastResult, PierceVelocity: Vector3)
	local Context = CastToBulletContext[Cast]
	if not Context then return end
	-- Increment BEFORE firing. The PierceCount on the signal represents the
	-- count INCLUDING the current pierce, so consumers can check
	-- "is this the third pierce?" without adding one themselves.
	Cast.Runtime.PierceCount += 1
	Context:_UpdateState(PierceResult.Position, PierceVelocity, Cast.Runtime.DistanceCovered)
	Signals.OnPierce:FireSafe(Context, PierceResult, PierceVelocity, Cast.Runtime.PierceCount)
end

local function FireOnBounce(Cast: HybridCast, BounceResult: RaycastResult, PostBounceVelocity: Vector3)
	local Context = CastToBulletContext[Cast]
	if not Context then return end
	-- Increment BEFORE firing for the same reason as FireOnPierce — consumers
	-- receive the updated count so they don't need to add one.
	Cast.Runtime.BounceCount += 1
	Context:_UpdateState(BounceResult.Position, PostBounceVelocity, Cast.Runtime.DistanceCovered)
	Signals.OnBounce:FireSafe(Context, BounceResult, PostBounceVelocity, Cast.Runtime.BounceCount)
end

local function FireOnTerminated(Cast: HybridCast)
	local Context = CastToBulletContext[Cast]
	if not Context then return end
	Signals.OnTerminated:FireSafe(Context)
end

-- ─── Corner Trap Detection ───────────────────────────────────────────────────

--[=[
    IsCornerTrap

    Description:
        Detects whether the bullet has entered a geometric configuration where
        it would bounce infinitely between two surfaces without making meaningful
        forward progress. This situation arises in concave geometry — V-grooves,
        inside corners, narrow slots, micro-cracks — where each bounce reflects
        the bullet directly toward the opposing surface.

        Without this detection, such geometry would trigger a bounce loop that
        consumes all of MaxBounces in a single frame, producing a visible
        stutter (the bullet freezes in the corner) and wasting simulation budget.
        In degenerate cases it could also trigger MaxBouncesPerFrame and produce
        incorrect final positions.

        Three independent guards are evaluated; any single guard firing is
        sufficient to declare a trap and terminate the cast. The guards are
        ordered from cheapest to most expensive:

        Guard 1 — Temporal proximity (scalar comparison, fastest):
            Two bounces occurring within CornerTimeThreshold seconds of each
            other (default 0.002s) indicate the bullet is bouncing faster than
            any physically meaningful surface separation allows. At 60Hz, 0.002s
            is roughly one-eighth of a frame — no real surface geometry produces
            legitimate bounces this close together in time.

        Guard 2 — Normal opposition (dot product):
            If the current surface normal and the previous bounce normal point
            nearly opposite each other (dot product < CornerNormalDotThreshold,
            default -0.85, corresponding to ~148°), the two surfaces are nearly
            face-to-face. A ball in a square groove bouncing between left and
            right walls would produce normals with dot ≈ -1.0. The threshold
            gives a generous tolerance margin to avoid false positives on slightly
            angled surfaces.

        Guard 3 — Spatial proximity (distance check):
            If the two most recent bounce contact points are less than
            CornerDisplacementThreshold studs apart (default 0.5), the bullet
            is making negligible forward progress. This catches small pits, micro
            geometry, and procedurally generated terrain irregularities where
            normals might not be perfectly opposing but the bullet is clearly stuck.

    Parameters:
        Cast: HybridCast
            The cast being evaluated. Reads LastBounceTime, LastBounceNormal,
            and LastBouncePosition from Runtime to compare against the new bounce.

        SurfaceNormal: Vector3
            The outward-facing normal of the surface just hit. Must be a unit vector.

        ContactPosition: Vector3
            World-space position where the bullet just made contact.

    Returns:
        boolean
            True if a corner trap is detected. The caller should terminate the
            cast immediately rather than reflecting the velocity.

    Notes:
        This is a heuristic and will occasionally produce false positives —
        legitimate tight-angle bounces in intentionally narrow geometry may be
        incorrectly identified as traps. This is an accepted tradeoff: an
        infinite bounce loop is a far worse outcome than a premature termination.
        If your game requires bullets to navigate tight geometry, reduce the
        thresholds or disable corner trap detection via MaxBounces = 0.
]=]
local function IsCornerTrap(Cast: HybridCast, SurfaceNormal: Vector3, ContactPosition: Vector3): boolean
	local Runtime = Cast.Runtime
	local Behavior = Cast.Behavior

	-- Guard 1: Temporal proximity. OsClock is cached as a local upvalue to avoid
	-- a global hash lookup on this frequently-called check. If the interval since
	-- the last bounce is shorter than the threshold, no real physical geometry
	-- could have produced this bounce legitimately.
	local TimeSinceLastBounce = OsClock() - Runtime.LastBounceTime
	local IsBounceIntervalTooShort = TimeSinceLastBounce < Behavior.CornerTimeThreshold
	if IsBounceIntervalTooShort then
		return true
	end

	-- Guard 2: Normal opposition. The dot product of two unit vectors equals
	-- cos(angle_between_them). A value of -1.0 means the normals point exactly
	-- opposite each other (180°, perfectly parallel opposing surfaces). The
	-- threshold of -0.85 catches any configuration where the surfaces are within
	-- about 32° of being parallel-opposing, which covers all practical concave
	-- corner traps with a reasonable margin for non-axis-aligned geometry.
	-- We only perform this check if a previous bounce normal exists (i.e., this
	-- is not the first bounce), because comparing against ZERO_VECTOR would
	-- always produce a dot of 0.0 and never trigger the guard.
	local HasPreviousBounceNormal = Runtime.LastBounceNormal ~= ZERO_VECTOR
	if HasPreviousBounceNormal then
		local NormalDotProduct = SurfaceNormal:Dot(Runtime.LastBounceNormal)
		local NormalsAreOpposing = NormalDotProduct < Behavior.CornerNormalDotThreshold
		if NormalsAreOpposing then
			return true
		end
	end

	-- Guard 3: Spatial proximity. A bullet making genuine forward progress
	-- through geometry will have non-trivial displacement between successive
	-- bounce contact points. Sub-threshold displacement indicates the bullet
	-- is oscillating in a very confined region. We skip this check if no
	-- previous bounce position is recorded (ZERO_VECTOR sentinel) to avoid
	-- comparing against the world origin.
	local HasPreviousBouncePosition = Runtime.LastBouncePosition ~= ZERO_VECTOR
	if HasPreviousBouncePosition then
		local BounceDisplacement = (ContactPosition - Runtime.LastBouncePosition).Magnitude
		local IsDisplacementTooSmall = BounceDisplacement < Behavior.CornerDisplacementThreshold
		if IsDisplacementTooSmall then
			return true
		end
	end

	return false
end

-- ─── Bounce Resolution ───────────────────────────────────────────────────────

--[=[
    ResolveBounce

    Description:
        Computes the post-bounce velocity vector given the bullet's incoming
        velocity and the surface normal at the contact point.

        The core reflection formula is the standard geometric mirror reflection:
            V_reflected = V - 2 * (V · N) * N
        where V is the incoming velocity and N is the unit surface normal.

        The derivation: (V · N) gives the signed scalar projection of V onto N
        — that is, how much of V is directed into the surface. Multiplying by N
        converts it back to a vector along the normal. Subtracting twice this
        component from V reverses the normal component while preserving the
        tangential component, producing a mirror reflection about the surface
        plane. This formula is exact for elastic reflection from a flat surface.

        Energy dissipation is modelled multiplicatively: the reflected velocity
        is scaled by (Restitution × MaterialRestitutionMultiplier). Restitution
        < 1.0 means kinetic energy is lost each bounce (inelastic collision),
        simulating material deformation and sound emission. This also ensures
        that a bullet with finite Restitution will eventually slow below
        BounceSpeedThreshold and stop bouncing naturally.

        Per-material restitution (MaterialRestitution table) allows different
        surfaces to absorb different amounts of energy. A rubber floor can have
        Restitution = 1.0 while a concrete wall uses Restitution = 0.5, without
        requiring separate Behavior tables per surface type.

        The NormalPerturbation path replaces the clean reflection with one
        computed against a randomly perturbed normal, simulating rough or
        irregular surfaces. The two paths are mutually exclusive: combining
        a clean reflection and a perturbed reflection would produce a
        double-reflection that is neither physically meaningful nor artistically
        predictable.

    Parameters:
        Cast: HybridCast
            The cast being resolved. Reads Behavior.Restitution,
            Behavior.MaterialRestitution, and Behavior.NormalPerturbation.

        HitResult: RaycastResult
            The raycast result at the contact point. Provides the surface normal
            (used for reflection) and the material (used for the per-material
            restitution lookup).

        IncomingVelocity: Vector3
            The bullet's velocity vector at the moment of surface contact. This
            should be the analytically computed velocity at the hit time, not a
            frame-start value, to ensure the reflection is computed from the
            correct impact angle.

    Returns:
        Vector3
            The post-bounce velocity vector. This becomes InitialVelocity for
            the new trajectory segment created in SimulateCast. It already has
            energy loss applied; the caller does not need to scale it further.

    Notes:
        If Restitution = 0.0, the returned vector has zero magnitude. SimulateCast
        does not check for this here — instead, the IsBelowMinSpeed check in the
        next frame will terminate the cast naturally. This avoids special-casing
        zero-restitution in ResolveBounce itself.
]=]
local function ResolveBounce(Cast: HybridCast, HitResult: RaycastResult, IncomingVelocity: Vector3): Vector3
	local Behavior = Cast.Behavior
	local SurfaceNormal = HitResult.Normal

	-- Standard geometric reflection. (V · N) is the component of V along N
	-- (positive = moving into the surface). Subtracting 2*(V·N)*N flips that
	-- component, turning the inward velocity into an outward velocity while
	-- preserving sideways motion. This is the physically correct formula for
	-- elastic reflection from a flat surface.
	local ReflectedVelocity = IncomingVelocity - 2 * IncomingVelocity:Dot(SurfaceNormal) * SurfaceNormal

	-- Per-material restitution override. Defaults to 1.0 (use only the base
	-- Restitution coefficient) if the material is not in the lookup table. This
	-- allows surfaces with different absorption characteristics to coexist in the
	-- same scene without requiring separate Behavior tables per material.
	local MaterialRestitutionMultiplier = 1.0
	if Behavior.MaterialRestitution then
		MaterialRestitutionMultiplier = Behavior.MaterialRestitution[HitResult.Material] or 1.0
	end

	-- Apply energy loss. The combined coefficient is Restitution × material multiplier.
	-- Values below 1.0 reduce speed after each bounce; 1.0 is perfectly elastic
	-- (no energy loss). The same multiplier applies to all velocity components
	-- uniformly — energy is lost proportionally, not directionally.
	local ScaledVelocity = ReflectedVelocity * Behavior.Restitution * MaterialRestitutionMultiplier

	-- Perturbation path: if NormalPerturbation > 0, we re-reflect against a
	-- randomly perturbed normal instead of the clean surface normal. This simulates
	-- rough or uneven surfaces where the micro-geometry deflects the bullet
	-- unpredictably. The perturbed result overwrites ScaledVelocity entirely
	-- because applying both clean and perturbed reflections would produce a
	-- double-reflection that has no physical interpretation.
	local ShouldPerturb = Behavior.NormalPerturbation > 0
	if ShouldPerturb then
		-- Generate a uniformly random unit-sphere direction by sampling each axis
		-- in [-0.5, 0.5] and taking the unit vector. Scale by NormalPerturbation
		-- to control how far the normal can deviate. Adding to the surface normal
		-- and re-normalising gives a perturbed normal that stays near the original
		-- surface orientation for small NormalPerturbation values.
		local NoiseVector = Vector3.new(
			math.random() - 0.5,
			math.random() - 0.5,
			math.random() - 0.5
		).Unit * Behavior.NormalPerturbation

		local PerturbedNormal = (SurfaceNormal + NoiseVector).Unit

		-- Recompute the full reflection + restitution against the perturbed normal.
		-- This replaces the clean ScaledVelocity computed above.
		ScaledVelocity = IncomingVelocity - 2 * IncomingVelocity:Dot(PerturbedNormal) * PerturbedNormal
		ScaledVelocity = ScaledVelocity * Behavior.Restitution * MaterialRestitutionMultiplier
	end

	return ScaledVelocity
end

-- ─── Pierce Resolution ───────────────────────────────────────────────────────

--[=[
    ResolvePierce

    Description:
        Processes a pierce chain starting from the first confirmed pierceable hit.
        The bullet has already been determined to meet pierce conditions (speed,
        angle, callback approval, and count limit) by SimulateCast before this
        function is called. ResolvePierce takes over to handle chained pierce
        behaviour: it casts successive rays through the geometry, asking
        CanPierceFunction about each new hit, until the chain ends either in
        open space or on a non-pierceable (solid) surface.

        Filter mutation strategy:
            To prevent the next raycast in the chain from re-detecting an
            already-pierced instance, that instance must be excluded from the
            active RaycastParams filter. The mutation strategy depends on the
            filter mode in use:
                - Exclude mode: the pierced instance is appended to the filter
                  list. Roblox's Exclude filter skips any instance in the list,
                  so adding the instance tells the next cast to ignore it.
                - Include mode: the pierced instance is removed from the filter
                  list. Roblox's Include filter only tests instances in the list,
                  so removing it excludes it from future detection.
            This mutation is intentionally permanent for the cast's lifetime —
            an instance pierced once will never be re-detected by the same cast,
            even if the bullet's trajectory curves back toward it. This is a
            deliberate game-design choice: re-piercing the same object on a
            curved trajectory would be surprising to players and could cause
            duplicate damage events.

        Speed attenuation:
            Each pierce reduces the bullet's speed by PenetrationSpeedRetention
            (e.g. 0.8 = retaining 80% of speed, 20% lost per pierce). The
            direction is preserved (only magnitude changes) to simulate linear
            penetration without deflection. This attenuated velocity is passed
            to the next CanPierceFunction call, allowing the callback to make
            speed-aware decisions (e.g. stopping the chain when speed falls below
            a meaningful threshold).

    Parameters:
        Cast: HybridCast
            The cast performing the pierce. Reads Behavior for configuration and
            mutates Runtime.PiercedInstances and Runtime.PierceCount.

        InitialPierceResult: RaycastResult
            The hit result that triggered the pierce chain. This is the FIRST
            pierceable surface — it has already been approved by CanPierceFunction
            in the caller before ResolvePierce is invoked.

        PierceOrigin: Vector3
            The world-space position from which the triggering raycast was cast.
            Not used directly inside this function but passed for completeness
            in case future chain-start logic needs it.

        RayDirection: Vector3
            The direction vector of the original raycast that produced
            InitialPierceResult. All subsequent pierce raycasts use this same
            direction, maintaining the bullet's straight-line path through
            the geometry.

        CurrentVelocity: Vector3
            The bullet's velocity at the moment of the first pierce contact.
            Mutated locally per pierce (speed attenuated) without affecting the
            caller's velocity variable.

    Returns:
        (boolean, RaycastResult?, Vector3)
            First: true if the chain ended at a solid (non-pierceable) hit.
            Second: the solid hit result if the first return is true, else nil.
            Third: the final attenuated velocity after all pierces in the chain.

    Notes:
        A hard iteration cap of 100 guards against degenerate geometry (e.g.
        two overlapping meshes where each reports the other as a new hit) that
        would otherwise cause an infinite loop. In practice, MaxPierceCount is
        checked inside the loop and provides the real limit long before 100
        iterations are reached.

        RayDirection is validated to be non-degenerate before the loop begins.
        A zero-length direction would cause workspace:Raycast to throw or return
        unpredictable results, corrupting the chain with no useful diagnostic.
]=]
local function ResolvePierce(
	Cast: HybridCast,
	InitialPierceResult: RaycastResult,
	PierceOrigin: Vector3,
	RayDirection: Vector3,
	CurrentVelocity: Vector3
): (boolean, RaycastResult?, Vector3?)

	-- Validate ray direction before entering the loop. A degenerate direction
	-- (length near zero) would cause workspace:Raycast to misbehave. Checking
	-- here rather than inside the loop avoids repeating the check on every
	-- iteration and gives a clear failure point for debugging.
	if RayDirection.Magnitude < 1e-6 then
		Logger:Warn("ResolvePierce: RayDirection is zero — skipping")

		return false, nil , nil
	end

	local Runtime = Cast.Runtime
	local Behavior = Cast.Behavior

	--[[
	    Filter mutation note: instances added to (or removed from) the filter list
	    during this pierce chain remain excluded for the entire lifetime of this cast.
	    This is a permanent side-effect by design. A bullet that pierced a wall
	    earlier in its flight should not re-detect that wall if its trajectory
	    curves back due to gravity. If you need to support re-detection of previously
	    pierced instances (e.g. for boomerang projectiles), you would need to
	    snapshot and restore the filter around specific trajectory segments.
	]]
	local RayParams = Behavior.RaycastParams
	local CanPierceCallback = Behavior.CanPierceFunction

	-- Cache the filter mode outside the loop. FilterType does not change during
	-- a cast's lifetime, so there is no reason to re-read the property on every
	-- iteration. Determining this once and branching on a local boolean is cheaper
	-- than reading an Enum property from a Roblox object each iteration.
	local IsExcludeFilter = RayParams.FilterType == Enum.RaycastFilterType.Exclude

	local PierceIterationCount = 0
	local CurrentPierceResult = InitialPierceResult
	local FoundSolidHit = false

	while true do
		local PiercedInstance = CurrentPierceResult.Instance

		-- Record this instance in PiercedInstances so SimulateCast can detect
		-- if the bullet re-encounters it via a different raycast path in the same
		-- frame (e.g. during high-fidelity sub-segments). Without this record,
		-- the same instance might be processed as a new hit by a later sub-segment.
		local PiercedList = Runtime.PiercedInstances
		PiercedList[#PiercedList + 1] = PiercedInstance

		-- Mutate the active filter to exclude the just-pierced instance from all
		-- future raycasts in this chain and in this cast's lifetime.
		local CurrentFilterList = RayParams.FilterDescendantsInstances
		if IsExcludeFilter then
			-- Exclude mode: appending to the list tells Roblox to skip this
			-- instance. O(1) append — no search needed.
			CurrentFilterList[#CurrentFilterList + 1] = PiercedInstance
		else
			-- Include mode: the instance must be removed from the list so Roblox
			-- no longer tests it. We use swap-remove (O(1)) rather than
			-- table.remove (O(n)) to avoid shifting elements in what can be a
			-- large filter list.
			local InstanceIndex = table.find(CurrentFilterList, PiercedInstance)
			if InstanceIndex then
				CurrentFilterList[InstanceIndex] = CurrentFilterList[#CurrentFilterList]
				CurrentFilterList[#CurrentFilterList] = nil
			end
		end
		RayParams.FilterDescendantsInstances = CurrentFilterList

		-- Attenuate speed by PenetrationSpeedRetention. The direction (Unit vector)
		-- is preserved because we assume the bullet travels in a straight line
		-- through the material without deflection. This gives the attenuated
		-- velocity that is both passed to the next CanPierceFunction call and
		-- fired with the OnPierce signal.
		local PostPierceSpeed = CurrentVelocity.Magnitude * Behavior.PenetrationSpeedRetention
		CurrentVelocity = CurrentVelocity.Unit * PostPierceSpeed

		-- Fire OnPierce with the attenuated velocity. FireOnPierce also increments
		-- PierceCount, so the count check below sees the updated value.
		FireOnPierce(Cast, CurrentPierceResult, CurrentVelocity)
		
		if Behavior.VisualizeCasts then
			Visualizer.Hit(CFrameNew(CurrentPierceResult.Position), "pierce")
			Visualizer.Normal(CurrentPierceResult.Position, CurrentPierceResult.Normal)
		end
		
		if Runtime.PierceCount >= Behavior.MaxPierceCount then
			-- MaxPierceCount reached. The bullet has exhausted its penetration
			-- capacity. Stop the chain here — the next surface (if any) will be
			-- handled as a terminal hit by SimulateCast.
			break
		end
		-- Advance the ray origin past the just-pierced surface by NUDGE along
		-- the travel direction. Without this offset, the next raycast would start
		-- exactly on the surface and could re-detect it at near-zero distance,
		-- producing a false re-hit of the same instance that was just filtered out.
		local NextRayOrigin = CurrentPierceResult.Position + RayDirection.Unit * NUDGE
		local NextPierceResult = workspace:Raycast(NextRayOrigin, RayDirection, RayParams)

		-- No further geometry hit: the pierce chain ends in open space. The bullet
		-- continues flying as normal without needing a terminal event here.
		if NextPierceResult == nil then
			break
		end

		PierceIterationCount += 1

		-- Hard iteration safety cap. This should never be reached under normal
		-- conditions because MaxPierceCount limits the chain first. It exists as
		-- a last-resort guard against degenerate geometry (e.g. two stacked
		-- transparent meshes that create an infinite alternating hit sequence).
		if PierceIterationCount >= 100 then
			Logger:Warn("ResolvePierce: exceeded 100 iterations — possible degenerate geometry")
			break
		end

		-- Ask CanPierceFunction whether the next instance can also be pierced.
		-- We pass the attenuated CurrentVelocity so the callback can make
		-- speed-aware decisions (e.g. stopping the chain once speed drops below
		-- a meaningful threshold). The LinkedContext is passed instead of the
		-- raw cast so the callback receives the public API object consistent with
		-- how it was set up in Fire().
		local LinkedContext = CastToBulletContext[Cast]
		local NextCanBePierced = CanPierceCallback and CanPierceCallback(LinkedContext, NextPierceResult, CurrentVelocity)

		if not NextCanBePierced then
			-- This instance cannot be pierced. The chain terminates here and
			-- this surface becomes a solid hit that SimulateCast must handle
			-- as a terminal impact.
			FoundSolidHit = true
			CurrentPierceResult = NextPierceResult
			break
		end

		CurrentPierceResult = NextPierceResult
	end

	return FoundSolidHit, CurrentPierceResult, CurrentVelocity
end

local function SimulateCast(Cast: HybridCast, Delta: number, IsSubSegment: boolean)
	local Runtime = Cast.Runtime
	local Behavior = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory

	-- ─── Analytic Position Computation ───────────────────────────────────────

	-- Compute elapsed time within the CURRENT trajectory segment only, not
	-- total runtime. This is crucial after a bounce: TotalRuntime continues
	-- accumulating but ActiveTrajectory.StartTime was set to the bounce time,
	-- so ElapsedBeforeAdvance correctly represents how far into the new arc
	-- we are, not how long the entire cast has been alive.
	local ElapsedBeforeAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	-- The raycast starts from the position the bullet occupied at the END of
	-- the previous frame (or the START of this sub-segment). Computing this
	-- analytically rather than caching the previous frame's output ensures
	-- the start position is always consistent with the trajectory, even if
	-- ModifyTrajectory changed the arc mid-flight.
	local LastPosition = PositionAtTime(
		ElapsedBeforeAdvance,
		ActiveTrajectory.Origin,
		ActiveTrajectory.InitialVelocity,
		ActiveTrajectory.Acceleration
	)

	-- Advance TotalRuntime by Delta. All subsequent position and velocity
	-- computations use ElapsedAfterAdvance so they reflect the end-of-step state.
	Runtime.TotalRuntime += Delta
	local ElapsedAfterAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	-- The target position is where the bullet would be at the end of this step
	-- if no hit occurs. The velocity is evaluated at the same time for use in
	-- threshold checks, cosmetic orientation, and signal payloads.
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

	-- The displacement vector from last frame to this frame. Used as the
	-- direction and magnitude for the raycast. Using the full displacement
	-- vector (not just the unit direction) ensures the raycast length matches
	-- exactly the distance the bullet travels this step — no more, no less.
	local FrameDisplacement = CurrentTargetPosition - LastPosition

	-- ─── Raycast ─────────────────────────────────────────────────────────────

	-- The ray covers exactly the displacement vector. Casting from LastPosition
	-- in the displacement direction with the displacement magnitude means the
	-- raycast tests only the region the bullet actually traversed this step —
	-- it cannot detect surfaces beyond the bullet's endpoint.
	local RayDirection = FrameDisplacement

	-- Skip frames where the bullet hasn't moved (e.g. Delta = 0 or speed near
	-- zero). A zero-length raycast would be ill-defined and would waste a Roblox
	-- API call. The IsBelowMinSpeed check later in this function will handle the
	-- speed-zero termination on the next frame.
	if FrameDisplacement.Magnitude < 1e-6 then return end
	local RaycastResult = workspace:Raycast(LastPosition, RayDirection, Behavior.RaycastParams)

	-- If the raycast hit something, use the hit point. Otherwise, use the
	-- analytically computed target position. BulletHitPoint is used for travel
	-- distance accumulation, cosmetic bullet placement, and visual segment drawing.
	local BulletHitPoint = RaycastResult and RaycastResult.Position or CurrentTargetPosition
	local FrameRayDisplacement = (BulletHitPoint - LastPosition).Magnitude

	-- ─── Travel Update ───────────────────────────────────────────────────────

	-- Fire OnTravel BEFORE hit processing so consumers receive the frame's
	-- current position even if the hit causes termination. If OnTravel fired
	-- after hit processing and the hit terminated the cast, OnTravel would
	-- never fire for this step — leaving trail effects or sound code with a
	-- one-frame gap at the terminal position.
	FireOnTravel(Cast, BulletHitPoint, CurrentVelocity)
	Runtime.DistanceCovered += FrameRayDisplacement

	-- ─── Cosmetic Bullet Update ──────────────────────────────────────────────

    --[[
        Orient the cosmetic bullet part so it faces the direction of travel.
        CFrame.new(position, lookAt) constructs a CFrame at position looking
        toward lookAt, aligning the part's positive Z axis (front face) with
        the travel direction. Adding velocity.Unit to position gives a point
        one unit ahead in the travel direction — the minimal lookAt offset that
        works for any non-zero velocity.

        The fallback direction (0, 0, 1) handles the degenerate case where
        speed is near zero (e.g. a bullet at the apex of its arc). Without it,
        velocity.Unit would be NaN and CFrame.new would produce a degenerate
        transform that could corrupt the part's state.
    ]]
	if Runtime.CosmeticBulletObject then
		local LookAt = BulletHitPoint + (
			CurrentVelocity:Dot(CurrentVelocity) > 1e-6
				and CurrentVelocity.Unit
				or Vector3.new(0, 0, 1)  -- fallback direction if speed is zero
		)
		Runtime.CosmeticBulletObject.CFrame = CFrameNew(BulletHitPoint, LookAt)
	end

	-- ─── Debug Visualisation ─────────────────────────────────────────────────

	-- Visualisation is gated on both VisualizeCasts and Delta > 0. The Delta
	-- guard prevents spurious zero-length segments from appearing in the
	-- visualiser during time-zero initialisation passes or paused frames.
	if Behavior.VisualizeCasts and Delta > 0 then
		Visualizer.Segment(CFrameNew(LastPosition, LastPosition + RayDirection), FrameRayDisplacement)
	end

	-- ─── Hit Detection ───────────────────────────────────────────────────────

    --[[
        The cosmetic bullet is a live Instance in the world. Without this guard,
        every raycast would immediately detect the visible bullet part itself at
        distance ~0, producing a self-hit on the first frame and terminating the
        cast before it travels any distance. We check by reference equality so
        any other part the bullet might coincidentally be near is not affected.
    ]]
	local IsHitOnCosmeticBullet = RaycastResult and RaycastResult.Instance == Runtime.CosmeticBulletObject
	local IsValidHit = RaycastResult ~= nil and not IsHitOnCosmeticBullet

	if IsValidHit then
		local LinkedContext = CastToBulletContext[Cast]
		local CanPierceCallback = Behavior.CanPierceFunction

		-- ─── Yield Detection Guard ───────────────────────────────────────────
        --[[
            CanPierceFunction must be synchronous. It is called while the simulation
            loop is running (inside _StepProjectile's frame event), so any yield
            inside it would suspend the entire simulation loop until it resumed —
            blocking frame processing for all other casts.

            Detection mechanism: before calling CanPierceFunction, we store the
            current coroutine in PierceCallbackThread. After it returns, we clear
            it. If PierceCallbackThread is still set when SimulateCast runs again
            in the NEXT top-level frame (IsSubSegment = false), it means the
            callback from the previous frame never returned — it yielded and the
            next frame began before it woke up. We terminate the cast and log an
            error rather than letting the hung coroutine corrupt simulation state.

            The IsSubSegment check suppresses this guard for sub-segment calls.
            In a resimulation loop, PierceCallbackThread being set from the
            previous sub-segment is expected: we set it, call the function, it
            returns synchronously, we clear it, then move to the next sub-segment.
            If we checked here, every sub-segment after the first would spuriously
            trigger the guard.
        ]]
		local HasHangingPierceCallback = Runtime.PierceCallbackThread ~= nil
			and Runtime.PierceCallbackThread ~= coroutine.running()
		if not IsSubSegment and CanPierceCallback and HasHangingPierceCallback then
			Terminate(Cast)
			Logger:Error("SimulateCast: CanPierceFunction appears to have yielded")
			return
		end

		-- Record the current coroutine as the active pierce callback thread.
		-- If CanPierceCallback is synchronous (as required), this will be cleared
		-- on the next line after the function returns. If it yields, this value
		-- will persist and trigger the guard on the next top-level frame step.
		Runtime.PierceCallbackThread = coroutine.running()
		local CanPierce = CanPierceCallback and CanPierceCallback(LinkedContext, RaycastResult, CurrentVelocity)
		Runtime.PierceCallbackThread = nil

		-- ─── Pierce Branch ───────────────────────────────────────────────────

		-- ImpactDot measures how head-on the bullet is striking the surface.
		-- The absolute value of (RayDirection.Unit · Normal) equals cos(impact angle).
		-- 1.0 = perfectly perpendicular (straight into the surface).
		-- 0.0 = perfectly parallel (grazing the surface).
		-- PierceNormalBias of 1.0 means ImpactDot >= 0.0, so all angles qualify.
		-- Lower PierceNormalBias values require more head-on impacts to pierce.
		local IsAbovePierceSpeedThreshold = CurrentVelocity.Magnitude >= Behavior.PierceSpeedThreshold
		local IsBelowMaxPierceCount = Runtime.PierceCount < Behavior.MaxPierceCount
		local ImpactDot = math.abs(RayDirection.Unit:Dot(RaycastResult.Normal))
		local MeetsNormalBias = ImpactDot >= (1.0 - Behavior.PierceNormalBias)

		-- All four conditions must be true simultaneously. Any single failed
		-- condition short-circuits the pierce path and falls through to bounce or
		-- terminal hit. The order is chosen so the cheapest comparisons (boolean
		-- flags and magnitude against a constant) are evaluated before the more
		-- expensive dot product with the normal.
		local PierceConditionsMet = CanPierce and IsAbovePierceSpeedThreshold and IsBelowMaxPierceCount and MeetsNormalBias

		local PierceWasResolved = false

		if PierceConditionsMet then		
			local FoundSolidHit, SolidHitResult, PostPierceVelocity = ResolvePierce(
				Cast,
				RaycastResult,
				LastPosition,
				RayDirection,
				CurrentVelocity
			)

			if FoundSolidHit and SolidHitResult then
				-- The pierce chain ended at a surface the bullet cannot pierce.
				-- That solid surface is the true terminal hit — we fire OnHit for
				-- it, not for the first pierceable surface. This gives consumers
				-- the position and normal of the actual stopping surface, which
				-- is where the impact VFX and damage should be applied.
				if Behavior.VisualizeCasts then
					Visualizer.Hit(CFrameNew(RaycastResult.Position), "pierce")
					Visualizer.Hit(CFrameNew(SolidHitResult.Position), "terminal")
				end

				FireOnHit(Cast, SolidHitResult, PostPierceVelocity)
				FireOnTerminated(Cast)
				Terminate(Cast)
				return
			end
			-- Pierce chain ended in open space (no solid terminal surface found).
			-- The bullet continues flying — no hit or termination event is needed.
			-- Simply set PierceWasResolved to prevent the bounce and terminal hit
			-- branches from evaluating this same surface.

			PierceWasResolved = true
		end

		-- ─── Bounce Branch ───────────────────────────────────────────────────

		-- Bounce is only evaluated if pierce did NOT occur. A surface cannot
		-- simultaneously be pierced through and bounced off — the outcomes are
		-- physically and logically mutually exclusive. Enforcing this in code
		-- prevents unexpected compound behaviours when both CanPierceFunction and
		-- CanBounceFunction are non-nil.
		if not PierceWasResolved then
			local CanBounceCallback = Behavior.CanBounceFunction

			-- Yield-detection guard for CanBounceFunction, symmetric to the pierce
			-- guard above. CanBounceFunction must not yield for the same reasons
			-- as CanPierceFunction. The IsSubSegment check prevents false positives
			-- during high-fidelity sub-segment calls.
			local PreviousThread = Runtime.BounceCallbackThread
			local HasHangingBounceCallback = PreviousThread ~= nil 
				and PreviousThread ~= coroutine.running()
			if not IsSubSegment and CanBounceCallback and HasHangingBounceCallback then
				Terminate(Cast)
				Logger:Error("SimulateCast: CanBounceFunction appears to have yielded — this is not allowed")
				return
			end

			Runtime.BounceCallbackThread = coroutine.running()
			local CanBounce = CanBounceCallback and CanBounceCallback(LinkedContext, RaycastResult, CurrentVelocity)
			Runtime.BounceCallbackThread = nil

			-- All four bounce conditions must be met. BouncesThisFrame is a
			-- per-real-frame counter (reset at the start of _StepProjectile, not
			-- per sub-segment), so MaxBouncesPerFrame is a true per-frame cap across
			-- all sub-segments combined. This prevents a bullet from consuming its
			-- entire MaxBounces budget in a single frame of rapid sub-segment
			-- processing, which would look wrong and could exhaust the bounce budget
			-- before the bullet has visually moved very far.
			local IsAboveBounceSpeedThreshold = CurrentVelocity.Magnitude >= Behavior.BounceSpeedThreshold
			local IsBelowMaxBounceCount = Runtime.BounceCount < Behavior.MaxBounces
			local IsBelowMaxBouncesThisFrame = Runtime.BouncesThisFrame < Behavior.MaxBouncesPerFrame
			local BounceConditionsMet = CanBounce
				and IsAboveBounceSpeedThreshold
				and IsBelowMaxBounceCount
				and IsBelowMaxBouncesThisFrame

			local BounceWasResolved = false

			if BounceConditionsMet then
				local IsTrapped = IsCornerTrap(Cast, RaycastResult.Normal, RaycastResult.Position)

				if not IsTrapped then
					-- Compute the reflected velocity. This gives the direction and
					-- speed the bullet should have immediately after leaving the surface,
					-- with energy loss already applied.
					local PostBounceVelocity = ResolveBounce(Cast, RaycastResult, CurrentVelocity)

					-- Offset the new trajectory origin by NUDGE along the surface normal.
					-- This prevents the very next raycast (at sub-segment or next frame
					-- start) from originating on the surface plane and immediately
					-- re-detecting it, which would produce an unwanted double-bounce at
					-- distance zero.
					local PostBounceOrigin = RaycastResult.Position + RaycastResult.Normal * NUDGE

					if Behavior.VisualizeCasts then
						Visualizer.Hit(CFrameNew(RaycastResult.Position), "bounce")
						Visualizer.Normal(RaycastResult.Position, RaycastResult.Normal)
						Visualizer.Velocity(RaycastResult.Position, PostBounceVelocity)
					end

					-- Create a new trajectory segment for the post-bounce path. The new
					-- segment starts at the current TotalRuntime with PostBounceVelocity
					-- as its initial velocity. Acceleration is inherited from the active
					-- trajectory so gravity continues to apply on the new arc.
					local NewTrajectory = {
						StartTime = Runtime.TotalRuntime,
						EndTime = -1,
						Origin = PostBounceOrigin,
						InitialVelocity = PostBounceVelocity,
						Acceleration = ActiveTrajectory.Acceleration,
					}
					table.insert(Runtime.Trajectories, NewTrajectory)
					Runtime.ActiveTrajectory = NewTrajectory

					-- Signal ResimulateHighFidelity to stop processing sub-segments
					-- on the old trajectory. The remaining sub-segments for this frame
					-- would compute positions on the pre-bounce arc, which is now
					-- inactive. The next frame will start from the new trajectory.
					Runtime.CancelResimulation = true

					-- Update bounce metadata for corner-trap detection on the next
					-- bounce. We check for a degenerate normal before storing because
					-- a zero-length normal stored in LastBounceNormal would corrupt the
					-- dot-product guard in IsCornerTrap, producing false-positive traps
					-- on every subsequent bounce.
					if RaycastResult.Normal:Dot(RaycastResult.Normal) > 1e-6 then
						Runtime.LastBounceNormal   = RaycastResult.Normal
						Runtime.LastBouncePosition = RaycastResult.Position
						Runtime.LastBounceTime     = OsClock()
					else
						Logger:Warn("SimulateCast: degenerate surface normal detected — corner trap state not updated")
					end
					Runtime.BouncesThisFrame += 1

					FireOnBounce(Cast, RaycastResult, PostBounceVelocity)
					BounceWasResolved = true
					return 
				else
					-- Corner trap confirmed: log and fall through to the terminal hit
					-- path below. Terminating here avoids consuming further bounce count
					-- in a loop that would never produce forward progress.
					if Behavior.VisualizeCasts then
						Visualizer.CornerTrap(RaycastResult.Position)
					end
					Logger:Print("SimulateCast: corner trap detected — terminating cast to prevent infinite bounce")
				end
			end

			-- ─── Terminal Hit ─────────────────────────────────────────────────
            --[[
                Reaches here when the hit qualifies for neither pierce nor bounce:
                  - CanPierceFunction returned false (or is nil).
                  - CanBounceFunction returned false (or is nil), speed was below
                    threshold, bounce count was exhausted, or a corner trap was detected.
                This is a definitive impact. The bullet stops here.
            ]]
			if not BounceWasResolved then
				FireOnHit(Cast, RaycastResult, CurrentVelocity)
				FireOnTerminated(Cast)
				Terminate(Cast)
				return
			end
		end
	end

	-- ─── Distance Termination ────────────────────────────────────────────────
    --[[
        The bullet has travelled at least MaxDistance studs since it was fired.
        We fire OnHit with a nil RaycastResult to distinguish this expiry from
        a physical surface impact. Consumers check `result == nil` to decide
        whether to play an impact effect or simply let the bullet disappear.
        This event fires after OnTravel for this step, so trail and position
        consumers are always up to date before the cast ends.
    ]]
	if Runtime.DistanceCovered >= Behavior.MaxDistance then
		if Behavior.VisualizeCasts then
			Visualizer.Hit(CFrameNew(CurrentTargetPosition), "terminal")	
		end

		FireOnHit(Cast, nil, CurrentVelocity)
		FireOnTerminated(Cast)
		Terminate(Cast)
		return
	end

	-- ─── Minimum Speed Termination ───────────────────────────────────────────
    --[[
        The bullet's speed has fallen below MinSpeed. This typically occurs after
        many bounces with a Restitution < 1.0 have bled away kinetic energy, or
        when very strong gravity decelerates a low-speed projectile. Like distance
        expiry, this fires OnHit with a nil result so consumers can distinguish
        this case from a physical collision. Without this check, a bullet at
        near-zero speed would simulate indefinitely, never reaching MaxDistance
        or hitting a surface — a live leak in the _ActiveCasts array.
    ]]
	local IsBelowMinSpeed = CurrentVelocity.Magnitude < Behavior.MinSpeed
	if IsBelowMinSpeed then
		FireOnHit(Cast, nil, CurrentVelocity)
		FireOnTerminated(Cast)
		Terminate(Cast)
		return
	end
end

-- ─── High-Fidelity Resimulation ──────────────────────────────────────────────

--[[
    Forward declaration required because ResimulateHighFidelity and SimulateCast
    form a mutual recursion:
        ResimulateHighFidelity subdivides a frame and calls SimulateCast for
        each sub-segment.
        SimulateCast is the top-level per-frame function that calls
        ResimulateHighFidelity when the frame displacement exceeds the segment size.
    Luau requires a variable to be declared before any function body references
    it. SimulateCast is assigned its body below after ResimulateHighFidelity,
    but ResimulateHighFidelity's body calls SimulateCast. The forward declaration
    here creates the upvalue slot that ResimulateHighFidelity can close over;
    the assignment of SimulateCast later fills that slot before either function
    is ever called at runtime.
]]
--[=[
    ResimulateHighFidelity

    Description:
        Subdivides a single frame's worth of bullet travel into multiple smaller
        time slices and simulates each one individually through SimulateCast. The
        purpose is to prevent thin-surface tunnelling: a bullet moving 20 studs
        per frame with a segment size of 0.5 produces 40 sub-segment raycasts,
        each starting from an analytically exact position. Even a surface only 1
        stud thick will be intersected by at least two of those raycasts — making
        it virtually impossible to miss without sub-segment counts in the hundreds.

        Without sub-segmentation, a single long raycast from frame start to frame
        end could skip entirely over a thin wall if the bullet's speed is high
        enough relative to the wall's thickness. At 300 studs/second and 60Hz,
        each frame covers 5 studs — enough to jump through any surface thinner
        than that undetected.

        Adaptive Segment Sizing:
            The function measures its own wall-clock time after the full loop and
            adjusts CurrentSegmentSize up or down to stay near the
            HighFidelityFrameBudget millisecond target. If the loop took longer
            than the budget, the segment size is multiplied by AdaptiveScaleFactor
            (segments get larger, fewer raycasts, cheaper). If the loop used less
            than half the budget, the segment size is divided by AdaptiveScaleFactor
            (segments get smaller, more raycasts, higher fidelity). This creates a
            self-tuning system that gracefully degrades under load rather than
            uniformly dropping fidelity for all bullets.

        Cascade Protection:
            IsActivelyResimulating prevents a re-entrant call to
            ResimulateHighFidelity from within a signal handler. Such re-entry
            would be a programming error (a signal handler should not trigger
            another round of resimulation on the same cast), and without this
            guard it would cause infinite recursion. The flag is cleared on both
            normal return and early termination.

        Global Frame Budget:
            FrameBudget.RemainingMicroseconds is decremented by each sub-segment's
            measured wall time. Once the budget is exhausted, the loop breaks early
            and remaining sub-segments are skipped. This ensures that a single fast
            bullet with a small segment size cannot consume the entire game thread's
            frame time, even if its own HighFidelityFrameBudget has not been reached.

    Parameters:
        Cast: HybridCast
            The cast to resimulate.

        ActiveTrajectory: Type.CastTrajectory
            The trajectory segment active at the start of this frame. Passed
            explicitly because SimulateCast calls inside the loop may modify
            Runtime.ActiveTrajectory (e.g. on a bounce), and we need the original
            value for the pre-frame position computation in _StepProjectile.

        ElapsedAtFrameStart: number
            Time elapsed in the active trajectory at the start of this frame,
            used by _StepProjectile to compute the pre-frame position for the
            total displacement calculation.

        FrameDelta: number
            Total frame time in seconds. Divided evenly across all sub-segments.

        FrameDisplacement: number
            Total displacement magnitude for the frame. Used to determine how
            many sub-segments are needed (FrameDisplacement / CurrentSegmentSize).

    Returns:
        boolean
            True if the cast was terminated during resimulation (hit, distance
            expiry, speed expiry, corner trap). False if the cast survived the frame.

    Notes:
        CancelResimulation is reset to false at the end of this function regardless
        of how the loop terminated. This ensures it does not persist into the next
        frame and incorrectly suppress normal resimulation.
]=]
local function ResimulateHighFidelity(
	Cast: HybridCast,
	ActiveTrajectory: Type.CastTrajectory,
	ElapsedAtFrameStart: number,
	FrameDelta: number,
	FrameDisplacement: number
): boolean

	-- Cascade protection: IsActivelyResimulating being true here indicates a
	-- signal handler or coroutine inside the previous SimulateCast call triggered
	-- another frame step on this cast before the current one finished. This is
	-- a logic error in consumer code. We terminate the cast and log an error
	-- rather than allowing a stack overflow.
	if Cast.Runtime.IsActivelyResimulating then
		Terminate(Cast)
		Logger:Error("ResimulateHighFidelity: cascade resimulation detected — possible signal handler re-entry")
		return false
	end

	Cast.Runtime.IsActivelyResimulating = true
	Cast.Runtime.CancelResimulation = false

	local Behavior = Cast.Behavior

	-- Compute the number of sub-segments by dividing total frame displacement by
	-- the current adaptive segment size. MathFloor truncates to an integer
	-- (we can't do a fractional raycast). MathClamp ensures at least 1 sub-segment
	-- (even if displacement < CurrentSegmentSize) and at most MAX_SUBSEGMENTS to
	-- prevent a degenerate case from consuming unbounded raycasts.
	local SubSegmentCount = MathClamp(
		MathFloor(FrameDisplacement / Cast.Runtime.CurrentSegmentSize),
		1,
		MAX_SUBSEGMENTS
	)

	if SubSegmentCount >= MAX_SUBSEGMENTS then
		-- The bullet is moving so fast relative to the segment size that it hit
		-- the hard cap. Aggressively double the normal adaptive increase to correct
		-- the situation in the next frame rather than gradually converging. Normal
		-- AdaptiveScaleFactor correction alone would take multiple frames to reach
		-- a safe segment size, during which every frame would hit the cap.
		Cast.Runtime.CurrentSegmentSize = Cast.Runtime.CurrentSegmentSize 
			* Behavior.AdaptiveScaleFactor * 2 
		Logger:Warn(string.format(
			"ResimulateHighFidelity: SubSegmentCount capped at %d — consider increasing HighFidelitySegmentSize",
			MAX_SUBSEGMENTS
			))
	end
	-- Each sub-segment receives an equal fraction of the total frame time.
	-- This ensures the sum of all sub-segment deltas equals FrameDelta exactly,
	-- preserving the correct total TotalRuntime advance across the frame.
	local SubSegmentDelta = FrameDelta / SubSegmentCount

	local HitOccurred = false
	local ResimStartTime = OsClock()

	for SegmentIndex = 1, SubSegmentCount do
		-- CancelResimulation is set by SimulateCast when a bounce occurs inside
		-- a sub-segment. A bounce creates a new ActiveTrajectory, so all remaining
		-- sub-segments would be computing positions on the old (now-inactive) arc.
		-- Stopping here ensures we don't advance the bullet along a trajectory it
		-- has already left. The next frame will pick up from the new trajectory.
		if Cast.Runtime.CancelResimulation then
			break
		end

		-- IsSubSegment = true tells SimulateCast this call is from a high-fidelity
		-- context, not the top-level frame loop. This suppresses the yield-detection
		-- guard that checks IsActivelyPiercing/IsBouncing: those flags being set
		-- between sub-segments is expected behaviour, not evidence of a yield.
		local SegmentStart = OsClock()
		SimulateCast(Cast, SubSegmentDelta, true)
		-- Deduct this sub-segment's wall time from the global frame budget. Once
		-- the budget reaches zero, further sub-segments on any cast are skipped
		-- for the remainder of this frame step. This prevents a single multi-part
		-- hit scenario (e.g. a grenade fragment bouncing in a tight space) from
		-- consuming the entire frame time.
		FrameBudget.RemainingMicroseconds -= (OsClock() - SegmentStart) * 1e6

		-- If SimulateCast terminated the cast (hit, distance, speed), record that
		-- and stop. Processing further sub-segments on a dead cast would be a
		-- use-after-free: the cast is removed from _ActiveCasts but we still hold
		-- a local reference to it.
		if not Cast.Alive then
			HitOccurred = true
			break
		end

		if FrameBudget.RemainingMicroseconds <= 0 then
			-- Global frame budget exhausted. Stop all sub-segments for this cast.
			-- Other casts in the same frame have already been denied further
			-- sub-segments as well (the budget is shared across all casts).
			break
		end
	end
	Cast.Runtime.CancelResimulation = false
	-- ─── Adaptive Segment Size Adjustment ────────────────────────────────────
    --[[
        Adaptive segment sizing uses the total wall-clock time of this
        resimulation loop to decide whether to coarsen or refine the next frame's
        sub-segments. The goal is to stay near HighFidelityFrameBudget milliseconds
        per cast per frame:

        Over budget: The loop took longer than the budget. Increase segment size
        so future frames produce fewer raycasts. The upper cap of 999 is
        effectively unlimited — it prevents math.min from receiving a second
        argument that is smaller than the product, which would incorrectly shrink
        the segment size.

        Under half budget: The loop has significant headroom. Decrease segment size
        to improve hit detection fidelity. MinSegmentSize provides a hard floor
        to prevent the segment size from shrinking to near-zero, which would produce
        an unbounded number of sub-segments.

        Within budget (between half and full): Leave the size unchanged. This
        dead-band prevents oscillation where every frame alternately coarsens and
        refines due to minor timing noise.
    ]]
	local ResimElapsedMilliseconds = (OsClock() - ResimStartTime) * 1000
	local IsOverBudget = ResimElapsedMilliseconds > Behavior.HighFidelityFrameBudget
	local IsUnderHalfBudget = ResimElapsedMilliseconds < Behavior.HighFidelityFrameBudget * 0.5

	if IsOverBudget then
		-- Too expensive this frame: coarsen segments to reduce raycast count next frame.
		Cast.Runtime.CurrentSegmentSize = math.min(
			Cast.Runtime.CurrentSegmentSize * Behavior.AdaptiveScaleFactor,
			999
		)
	elseif IsUnderHalfBudget then
		-- Headroom available: refine segments to improve hit detection accuracy.
		Cast.Runtime.CurrentSegmentSize = math.max(
			Cast.Runtime.CurrentSegmentSize / Behavior.AdaptiveScaleFactor,
			Behavior.MinSegmentSize
		)
	end

	-- Clear the flag unconditionally on all return paths. If it were left set
	-- by an early break (e.g. budget exhaustion), the next frame's call to
	-- ResimulateHighFidelity would immediately terminate the cast as a cascade.
	Cast.Runtime.IsActivelyResimulating = false
	return HitOccurred
end

-- ─── Core Simulation ─────────────────────────────────────────────────────────

--[=[
    SimulateCast

    Description:
        The core per-step simulation function. Advances a single cast forward by
        Delta seconds using the analytic kinematic equations, performs a raycast
        between the previous and current position, and responds to any surface
        hit with the appropriate resolution: pierce, bounce, or terminal impact.

        This function has two callers:
            1. _StepProjectile: the top-level per-frame driver. Calls with
               IsSubSegment = false and Delta = the full frame time (when not
               using high-fidelity mode) or hands off to ResimulateHighFidelity
               which calls SimulateCast with IsSubSegment = true.
            2. ResimulateHighFidelity: calls SimulateCast repeatedly with small
               Delta values (one sub-segment at a time) and IsSubSegment = true.

        The IsSubSegment flag controls whether the yield-detection guards for
        CanPierceFunction and CanBounceFunction are active. In a top-level call
        (IsSubSegment = false), if PierceCallbackThread or BounceCallbackThread
        are non-nil from a previous frame, it means those callbacks yielded and
        never returned — a fatal error that warrants cast termination. In a
        sub-segment call (IsSubSegment = true), those fields being set from the
        previous sub-segment is expected and should not trigger the guard.

        Hit resolution priority order:
            1. Pierce — evaluated first because a bullet capable of piercing
               should never simultaneously bounce. Treating them as sequential
               and exclusive ensures a single surface interaction produces
               exactly one physical outcome.
            2. Bounce — only evaluated if pierce did not occur.
            3. Terminal hit — reached if neither pierce nor bounce resolved the hit,
               or if a bounce was blocked by a corner trap.

        Distance and speed termination checks run after all hit processing.
        They use non-nil result signals (OnHit with nil RaycastResult) to allow
        consumers to distinguish expiry from physical impact in their handlers.

    Parameters:
        Cast: HybridCast
            The cast to advance.

        Delta: number
            Time in seconds to advance the simulation. For top-level calls this
            is the full frame delta; for sub-segment calls this is FrameDelta / N.

        IsSubSegment: boolean
            True when called from ResimulateHighFidelity. Controls whether the
            callback yield-detection guards are active.

    Notes:
        The CancelResimulation flag is set inside this function when a bounce
        occurs. It propagates to ResimulateHighFidelity's loop, which stops
        processing further sub-segments once a bounce has redirected the bullet
        onto a new trajectory arc.

        Distance accumulates along the actual ray path (hit point to start point)
        rather than the theoretical trajectory arc. This is a deliberate
        simplification: arc length integration would require numerical methods,
        and for the short per-frame distances involved the difference is negligible.
]=]


-- ─── Frame Loop ──────────────────────────────────────────────────────────────

--[=[
    _StepProjectile

    Description:
        The per-frame driver for all active projectile casts. Connected to the
        appropriate RunService event at solver creation time and called every
        frame with the elapsed frame time.

        The function resets the global frame budget at the start of each call so
        high-fidelity sub-segment raycasts across all casts are bounded by
        GLOBAL_FRAME_BUDGET_MS milliseconds total per frame, preventing any
        combination of fast bullets from saturating the game thread.

        For each active, unpaused cast, the function either:
            a) Calls SimulateCast directly (standard mode, one raycast per frame).
            b) Computes the total frame displacement and calls ResimulateHighFidelity
               to subdivide it into smaller steps (high-fidelity mode).

        High-fidelity mode requires a two-pass approach: first advance TotalRuntime
        by FrameDelta to compute the frame-end position (needed for displacement
        magnitude), then rewind TotalRuntime before calling ResimulateHighFidelity
        so sub-segments can re-advance it correctly in small increments. Without
        the rewind, TotalRuntime would be one full FrameDelta ahead before the
        first sub-segment even begins, causing all sub-segment position computations
        to be offset by one frame.

    Parameters:
        FrameDelta: number
            Duration of the current frame in seconds, supplied by the RunService
            event callback.

    Notes:
        ActiveCount is snapshotted before the iteration begins. Any cast created
        during this frame (e.g. from an OnHit signal handler that calls Fire() to
        spawn a fragment) will have been appended to _ActiveCasts after the snapshot,
        so it will not be processed until the next frame. This is intentional: casts
        born from events in frame N start simulating in frame N+1. Without this
        snapshot, a new cast could be processed in the same frame it was created,
        getting a partial frame of simulation inconsistent with its actual birth time.

        The `not Cast or not Cast.Alive` guard handles the case where an earlier
        iteration in the same frame terminated a cast that was later in the array.
        Swap-remove moves the surviving cast to the terminated cast's slot, so the
        array may have `nil` at indices that have not been visited yet if the removed
        cast happened to be at the current end of the active range.
]=]
local function _StepProjectile(FrameDelta: number)
	-- Reset the shared frame budget at the start of each frame. All high-fidelity
	-- sub-segment raycasts across every active cast draw from this pool. Once it
	-- reaches zero, ResimulateHighFidelity exits early for any cast that still
	-- has sub-segments remaining, preventing a large number of fast bullets from
	-- consuming the entire frame time on raycasts alone.
	FrameBudget.RemainingMicroseconds = GLOBAL_FRAME_BUDGET_MS * 1000
	local ActiveCount = #_ActiveCasts
	--[[
		ActiveCount is snapshotted here, before any casts are stepped. This
		ensures that casts registered during this frame (e.g. fragments spawned by
		an OnHit handler) are not stepped in the same frame they were created.
		Those casts exist at indices > ActiveCount and will be visited starting
		with the next _StepProjectile call. This gives every cast a consistent
		first-frame delta equal to exactly one full frame, not a partial frame
		that depends on when during the iteration the cast was registered.
	]]
	for CastIndex = 1, ActiveCount do
		local Cast = _ActiveCasts[CastIndex]

		-- Guard against nil (which can occur if an earlier termination's swap-remove
		-- moved a cast into this slot from beyond ActiveCount) and against dead casts
		-- (which can occur if a signal handler from an earlier cast in this iteration
		-- called context:Terminate() on a later cast before its index was reached).
		if not Cast or not Cast.Alive then continue end

		-- Paused casts (e.g. a bullet held in mid-air during a cutscene or ability
		-- animation) are skipped entirely. TotalRuntime does not advance for paused
		-- casts, so resuming them later produces seamless continuation from where
		-- they were paused.
		if Cast.Paused then continue end

		local Runtime = Cast.Runtime
		local Behavior = Cast.Behavior

		-- Reset the per-frame bounce counter before simulating this cast. This
		-- counter limits the total number of bounces that can occur across all
		-- sub-segments within a single frame step. Without a per-frame cap, a bullet
		-- entering tight geometry could bounce MaxBounces times in one frame and
		-- exhaust its entire lifetime budget instantaneously, producing a visible
		-- stutter where the bullet stops with no apparent cause.
		Runtime.BouncesThisFrame = 0

		-- High-fidelity mode is active when HighFidelitySegmentSize > 0 AND
		-- CurrentSegmentSize > 0 (the adaptive algorithm has not reduced it to zero,
		-- which should not happen given MinSegmentSize > 0 but is guarded anyway).
		local UseHighFidelity = Behavior.HighFidelitySegmentSize > 0
			and Runtime.CurrentSegmentSize > 0

		if UseHighFidelity then
			local CurrentTrajectory = Runtime.ActiveTrajectory
			local ElapsedAtFrameStart = Runtime.TotalRuntime - CurrentTrajectory.StartTime

			-- Compute the start position analytically from the current trajectory
			-- state. This is the position the bullet occupies at the beginning of
			-- this frame, before any time has been advanced.
			local PositionAtFrameStart = PositionAtTime(
				ElapsedAtFrameStart,
				CurrentTrajectory.Origin,
				CurrentTrajectory.InitialVelocity,
				CurrentTrajectory.Acceleration
			)

			-- Tentatively advance TotalRuntime by the full frame delta to compute
			-- the frame-end position. This position is used only to compute the
			-- total displacement magnitude for sub-segment count calculation —
			-- it does not represent a real simulation step.
			Runtime.TotalRuntime += FrameDelta
			local ElapsedAtFrameEnd = Runtime.TotalRuntime - CurrentTrajectory.StartTime

			local PositionAtFrameEnd = PositionAtTime(
				ElapsedAtFrameEnd,
				CurrentTrajectory.Origin,
				CurrentTrajectory.InitialVelocity,
				CurrentTrajectory.Acceleration
			)

			local TotalFrameDisplacement = (PositionAtFrameEnd - PositionAtFrameStart).Magnitude

			-- CRITICAL: rewind TotalRuntime to the pre-advance value. If we left
			-- TotalRuntime advanced by FrameDelta here, ResimulateHighFidelity's
			-- sub-segments would each advance it further, resulting in TotalRuntime
			-- being FrameDelta + (SubSegmentCount * SubSegmentDelta) = 2 * FrameDelta
			-- ahead by the end of the frame — a systematic double-advance that would
			-- cause all subsequent position computations to be one frame too far ahead.
			Runtime.TotalRuntime -= FrameDelta

			ResimulateHighFidelity(
				Cast,
				CurrentTrajectory,
				ElapsedAtFrameStart,
				FrameDelta,
				TotalFrameDisplacement
			)
			-- Always clear CancelResimulation after the high-fidelity pass, even if
			-- it was set by a bounce inside ResimulateHighFidelity. Without this reset,
			-- a bounce in frame N would leave CancelResimulation = true at the start of
			-- frame N+1, causing the first sub-segment of that frame to immediately break
			-- the resimulation loop without advancing the bullet at all.
			Cast.Runtime.CancelResimulation = false
		else
			-- Standard mode: one raycast for the full frame. Suitable for low-speed
			-- bullets, distant or cosmetic projectiles, or any cast where tunnelling
			-- through thin surfaces is not a concern.
			SimulateCast(Cast, FrameDelta, false)
		end
	end
end

-- ─── Module Definition ───────────────────────────────────────────────────────

local HybridSolver = {}
HybridSolver.__index = HybridSolver
HybridSolver.__type = IDENTITY

-- ─── Fire ────────────────────────────────────────────────────────────────────

--[=[
    HybridSolver:Fire

    Description:
        Creates, configures, and registers a new in-flight projectile cast.
        This is the primary entry point for all projectile creation. After Fire()
        returns, the cast is live and will be advanced every frame by
        _StepProjectile until it hits something, expires, or is manually
        terminated via context:Terminate().

        Fire() performs several responsibilities in sequence:
            1. Validates the BulletContext's required kinematic fields (Origin,
               Direction, Speed). Any missing or invalid field aborts immediately
               before any state is allocated, giving the caller a clear error at
               the boundary rather than a confusing nil-dereference inside SimulateCast.
            2. Resolves the effective Behavior by merging the caller's FireBehavior
               with DEFAULT_BEHAVIOR field by field. Explicit per-field resolution
               is preferred over setmetatable inheritance because the latter would
               silently mask typos (a misspelled field name would fall through to
               the default rather than being flagged).
            3. Acquires a pooled RaycastParams from ParamsPooler. The pool clones
               the caller's params so the pierce system's filter mutations never
               affect the caller's original params object. OriginalFilter is
               snapshot-frozen on the Behavior table for potential filter resets.
            4. Constructs the full HybridCast with its initial trajectory segment.
               The trajectory segment's Acceleration is the sum of the resolved
               gravity and the extra Acceleration field, combined once here so
               SimulateCast never needs to perform this addition at runtime.
            5. Optionally creates a cosmetic bullet Instance via either
               CosmeticBulletProvider (a function, takes priority) or
               CosmeticBulletTemplate (a BasePart to clone). The provider is
               timed to detect accidental yields.
            6. Registers the cast in _ActiveCasts and establishes the bidirectional
               HybridCast ↔ BulletContext mapping.
            7. Injects a Terminate callback into Context.__solverData so
               context:Terminate() can shut down the underlying cast without the
               context needing a direct HybridCast reference.

    Parameters:
        Context: BulletContext
            The public-facing bullet object that weapon code interacts with. Must
            have non-nil, finite Vector3 Origin and Direction fields and a finite
            number Speed. The context is passed as the first argument to every
            signal emission so consumers can identify the bullet and access
            its UserData.

        FireBehavior: HybridBehavior?
            Optional table of behavior overrides. Any field omitted or nil falls
            back to DEFAULT_BEHAVIOR. Passing nil for the entire argument applies
            all defaults. The caller's table is never mutated — all resolved values
            are stored in a new Behavior table on the HybridCast.

    Returns:
        HybridCast | false
            The newly created HybridCast on success, allowing the caller to
            introspect initial state if needed. False if input validation failed.

    Notes:
        Gravity is handled separately from Acceleration to allow zero-gravity
        scenarios. If Fb.Gravity has zero magnitude, DEFAULT_GRAVITY (workspace
        gravity) is used instead with a logged warning. A zero-vector gravity
        stored as the acceleration would cause VelocityAtTime to produce a constant
        velocity trajectory with no arc, which is physically correct for zero
        gravity but surprising if the caller accidentally passed a zero vector.

        CosmeticBulletProvider and CosmeticBulletTemplate are mutually exclusive.
        If both are provided, Template is ignored and a warning is logged. This
        is a deliberate priority rule rather than an error, to avoid breaking
        callers that set a default template on a shared Behavior table and then
        override it with a provider for specific bullet types.
]=]
function HybridSolver.Fire(Self: HybridSolver, Context: any, FireBehavior: HybridBehavior) : HybridCast
	-- Validate the three required fields on the context. All three are consumed
	-- directly to construct the initial trajectory segment: Origin → segment.Origin,
	-- Direction.Unit * Speed → segment.InitialVelocity. If any is nil, NaN, or
	-- infinity, the trajectory would be constructed with invalid values that would
	-- silently propagate through all kinematic computations. Failing here prevents
	-- that corruption and gives the caller an actionable error message.
	if not t.Vector3(Context.Origin) or not t.Vector3(Context.Direction) or not t.number(Context.Speed) then
		Logger:Warn("Fire: Context must have Origin (Vector3), Direction (Vector3), and Speed (number)")
		return nil
	end
	
	FireBehavior = FireBehavior or {} :: HybridBehavior
	-- ─── Behavior Resolution ─────────────────────────────────────────────────
    --[[
        Each field is resolved individually with an `or` fallback to DEFAULT_BEHAVIOR.
        This is deliberately verbose rather than using metatable inheritance because
        setmetatable(fb, {__index = DEFAULT_BEHAVIOR}) would silently accept misspelled
        field names: `CanPirceFunction` would not be caught and would fall through to
        nil, making the cast behave as if piercing were disabled with no diagnostic.
        Explicit resolution makes every field name a visible constant that is checked
        at the point of use.

        Note: CanBounceFunction and CanPierceFunction are NOT given DEFAULT_BEHAVIOR
        fallbacks because their default is intentionally nil — a bullet with no
        callback configured should never bounce or pierce. Falling back to a non-nil
        default would cause all bullets to start bouncing or piercing unexpectedly.
    ]]

	local ResolvedAcceleration 		= FireBehavior.Acceleration or DEFAULT_BEHAVIOR.Acceleration
	local ResolvedMaxDistance 		= FireBehavior.MaxDistance or DEFAULT_BEHAVIOR.MaxDistance
	local ResolvedRaycastParams	 	= FireBehavior.RaycastParams or DEFAULT_BEHAVIOR.RaycastParams
	local ResolvedMinSpeed 			= FireBehavior.MinSpeed or DEFAULT_BEHAVIOR.MinSpeed
	local ResolvedCanPierceFunction = FireBehavior.CanPierceFunction
	local ResolvedMaxPierceCount    = FireBehavior.MaxPierceCount or DEFAULT_BEHAVIOR.MaxPierceCount
	local ResolvedPierceSpeedThreshold = FireBehavior.PierceSpeedThreshold or DEFAULT_BEHAVIOR.PierceSpeedThreshold
	local ResolvedPenetrationSpeedRetention = FireBehavior.PenetrationSpeedRetention or DEFAULT_BEHAVIOR.PenetrationSpeedRetention
	local ResolvedPierceNormalBias = FireBehavior.PierceNormalBias or DEFAULT_BEHAVIOR.PierceNormalBias
	local ResolvedCanBounceFunction = FireBehavior.CanBounceFunction
	local ResolvedMaxBounces = FireBehavior.MaxBounces or DEFAULT_BEHAVIOR.MaxBounces
	local ResolvedBounceSpeedThreshold = FireBehavior.BounceSpeedThreshold or DEFAULT_BEHAVIOR.BounceSpeedThreshold
	local ResolvedRestitution = FireBehavior.Restitution or DEFAULT_BEHAVIOR.Restitution
	local ResolvedMaterialRestitution = FireBehavior.MaterialRestitution or DEFAULT_BEHAVIOR.MaterialRestitution
	local ResolvedNormalPerturbation = FireBehavior.NormalPerturbation or DEFAULT_BEHAVIOR.NormalPerturbation
	local ResolvedHighFidelitySegmentSize = FireBehavior.HighFidelitySegmentSize or DEFAULT_BEHAVIOR.HighFidelitySegmentSize
	local ResolvedHighFidelityFrameBudget = FireBehavior.HighFidelityFrameBudget or DEFAULT_BEHAVIOR.HighFidelityFrameBudget
	local ResolvedAdaptiveScaleFactor = FireBehavior.AdaptiveScaleFactor or DEFAULT_BEHAVIOR.AdaptiveScaleFactor
	local ResolvedMinSegmentSize = FireBehavior.MinSegmentSize or DEFAULT_BEHAVIOR.MinSegmentSize
	local ResolvedMaxBouncesPerFrame = FireBehavior.MaxBouncesPerFrame or DEFAULT_BEHAVIOR.MaxBouncesPerFrame
	local ResolvedCornerTimeThreshold = FireBehavior.CornerTimeThreshold or DEFAULT_BEHAVIOR.CornerTimeThreshold
	local ResolvedCornerNormalDotThreshold = FireBehavior.CornerNormalDotThreshold or DEFAULT_BEHAVIOR.CornerNormalDotThreshold
	local ResolvedCornerDisplacementThreshold = FireBehavior.CornerDisplacementThreshold or DEFAULT_BEHAVIOR.CornerDisplacementThreshold
	local ResolvedCosmeticBulletTemplate = FireBehavior.CosmeticBulletTemplate
	local ResolvedCosmeticBulletContainer = FireBehavior.CosmeticBulletContainer
	local ResolvedCosmeticBulletProvider = FireBehavior.CosmeticBulletProvider
	local ResolvedVisualizeCasts = FireBehavior.VisualizeCasts or DEFAULT_BEHAVIOR.VisualizeCasts

	-- Gravity is resolved separately from Acceleration because the two represent
	-- physically distinct concepts: gravity is the ambient gravitational field
	-- (constant for the cast's lifetime), while Acceleration is an extra
	-- impulse (thrust, wind, etc.) that is layered on top.
	-- The zero-magnitude guard prevents a degenerate gravity vector from being
	-- stored. A zero-length gravity would cause no arc at all, which might be
	-- intentional (space game) but is more likely an accidental nil coercion.
	-- Falling back to workspace gravity in that case makes the bullet behave
	-- as expected by default. The two are summed once here to produce a single
	-- EffectiveAcceleration constant, avoiding a per-frame addition in SimulateCast.
	local ResolvedGravity = DEFAULT_GRAVITY
	if FireBehavior.Gravity then
		if FireBehavior.Gravity.Magnitude > 0 then
			ResolvedGravity = FireBehavior.Gravity
		else
			Logger:Info("Fire: provided Gravity has zero magnitude — falling back to workspace gravity")
		end
	end

	local EffectiveAcceleration = ResolvedGravity + ResolvedAcceleration
	-- ─── HybridCast Construction ──────────────────────────────────────────────
    --[[
        HybridCast is the internal representation of an in-flight projectile.
        It is intentionally kept separate from BulletContext (the public API)
        to enforce a clean boundary: weapon code sees only BulletContext methods
        and fields; the solver uses HybridCast directly. This prevents consumer
        code from accidentally mutating internal simulation state (e.g. corrupting
        TotalRuntime or ActiveTrajectory) which would produce silent physics errors
        that are very difficult to debug.

        The Runtime sub-table holds all state that changes every frame.
        The Behavior sub-table holds all configuration that is constant for the
        cast's lifetime (set at Fire() and never modified). This separation makes
        it clear at a glance which fields are invariants and which are mutable,
        and allows future serialisation of Behavior without including transient state.
    ]]

	-- Acquire a pooled RaycastParams. The pool may return a clone of the provided
	-- params to avoid the pierce system's filter mutations from affecting the
	-- caller's original object. If the pool is exhausted, a warning is logged
	-- and the original params are used directly as a fallback — this is safe but
	-- means pierce filter mutations will affect the caller's params object.
	local AcquiredParams = ParamsPooler.Acquire(ResolvedRaycastParams)
	if not AcquiredParams then
		Logger:Warn("Fire: RaycastParams pool exhausted — falling back to direct params")
		AcquiredParams = ResolvedRaycastParams
	end

	local HybridCast: HybridCast = {
		Alive = true,
		Paused = false,
		-- StartTime records wall-clock time of creation for external diagnostics
		-- (e.g. computing cast age for effects). It is NOT used in kinematic
		-- calculations — those use TotalRuntime which starts at 0.
		StartTime = OsClock(),

		Runtime = {
			-- TotalRuntime starts at 0 and advances by Delta on each SimulateCast
			-- call. It is relative to the cast's birth, not wall-clock time, so
			-- pausing works correctly (TotalRuntime pauses with the cast).
			TotalRuntime = 0,
			DistanceCovered = 0,

			-- Trajectories is the complete ordered history of trajectory segments.
			-- Each element represents one arc (initial fire, or post-bounce arc).
			-- The first element is always the initial firing arc, with StartTime = 0.
			-- Subsequent elements are appended by SimulateCast on each bounce or by
			-- ModifyTrajectory on mid-flight changes.
			Trajectories = {
				{
					StartTime = 0,
					EndTime = -1,  -- -1 means this segment is still active
					Origin = Context.Origin,
					InitialVelocity = Context.Direction.Unit * Context.Speed,
					Acceleration = EffectiveAcceleration,
				}
			},

			-- ActiveTrajectory is the segment currently being simulated. It starts
			-- as a reference to Trajectories[1] and is reassigned on each bounce.
			-- Keeping a direct reference avoids indexing Trajectories[#Trajectories]
			-- on every frame, which would be O(1) but slightly more expensive than
			-- a direct field read.
			ActiveTrajectory = nil,

			-- Thread sentinels for CanBounceFunction and CanPierceFunction yield
			-- detection. Storing the coroutine before the callback and clearing it
			-- after allows SimulateCast to detect if the callback never returned
			-- (i.e., yielded). See the yield-detection guard in SimulateCast for
			-- detailed explanation.
			BounceCallbackThread = nil,
			PierceCallbackThread = nil,

			PierceCount = 0,
			-- PiercedInstances records every instance that has been pierced by this
			-- cast. This is used to prevent a sub-segment raycast from re-detecting
			-- an instance that was pierced earlier in the same frame.
			PiercedInstances = {},


			BounceCount = 0,

			--[[
			    BouncesThisFrame counts the total bounces across ALL sub-segments
			    within a single _StepProjectile call. It is reset at the top of
			    each frame step, not between sub-segments. This makes
			    MaxBouncesPerFrame a true per-real-frame limit regardless of how
			    many high-fidelity sub-segments are processed.

			    This is intentional: a cast running 20 sub-segments with
			    MaxBouncesPerFrame = 2 will bounce at most twice across those 20
			    sub-segments combined. If MaxBouncesPerFrame were per-sub-segment,
			    a fast bullet could perform 20 * MaxBouncesPerFrame bounces per frame,
			    exhausting its entire bounce budget in a single real-time frame and
			    producing an instant, silent stop.
			]]
			BouncesThisFrame = 0,
			-- LastBounceTime, LastBounceNormal, and LastBouncePosition are the three
			-- fields used by IsCornerTrap to detect infinite-bounce configurations.
			-- They are initialised to sentinel values: -math.huge for time (so the
			-- first bounce never triggers the temporal guard) and ZERO_VECTOR for
			-- normal/position (detected by ~= ZERO_VECTOR checks in IsCornerTrap).
			LastBounceTime = -math.huge,
			LastBounceNormal = ZERO_VECTOR,
			LastBouncePosition = ZERO_VECTOR,

			-- IsActivelyResimulating prevents ResimulateHighFidelity from being
			-- called re-entrantly on the same cast. CancelResimulation signals the
			-- sub-segment loop to stop when a bounce has changed the active trajectory.
			IsActivelyResimulating = false,
			CancelResimulation = false,

			-- CurrentSegmentSize begins at HighFidelitySegmentSize and is
			-- adjusted adaptively each frame by ResimulateHighFidelity. It is
			-- stored on Runtime (not Behavior) because it changes over the cast's
			-- lifetime in response to measured performance.
			CurrentSegmentSize = ResolvedHighFidelitySegmentSize,

			CosmeticBulletObject = nil,
		},

		Behavior = {
			-- EffectiveAcceleration is the pre-computed sum of gravity and extra
			-- acceleration, stored here so SimulateCast never needs to compute the
			-- sum at runtime. It is stored on Behavior (treated as invariant) because
			-- neither gravity nor the extra acceleration change after Fire(). If
			-- mid-flight acceleration changes are needed, they should be applied via
			-- HybridCast:SetAcceleration(), which opens a new trajectory segment.
			Acceleration = EffectiveAcceleration,
			MaxDistance = ResolvedMaxDistance,
			MinSpeed = ResolvedMinSpeed,
			Gravity = ResolvedGravity,

			-- AcquiredParams is the pooled (possibly cloned) RaycastParams instance.
			-- All raycasts for this cast's lifetime use this object. The pierce system
			-- mutates its FilterDescendantsInstances to exclude pierced instances.
			RaycastParams = AcquiredParams,

			-- OriginalFilter is a frozen deep clone of the filter list at Fire() time.
			-- It is used in Terminate() to reset the pooled params before returning
			-- them to the pool, ensuring no pierce-chain contamination carries over
			-- to the next cast that acquires these params.
			OriginalFilter = table.freeze(table.clone(
				ResolvedRaycastParams.FilterDescendantsInstances or {}
				)),

			CanPierceFunction = ResolvedCanPierceFunction,
			MaxPierceCount = ResolvedMaxPierceCount,
			PierceSpeedThreshold = ResolvedPierceSpeedThreshold,
			PenetrationSpeedRetention = ResolvedPenetrationSpeedRetention,
			PierceNormalBias = ResolvedPierceNormalBias,

			CanBounceFunction = ResolvedCanBounceFunction,
			MaxBounces = ResolvedMaxBounces,
			BounceSpeedThreshold = ResolvedBounceSpeedThreshold,
			Restitution = ResolvedRestitution,
			-- MaterialRestitution maps Enum.Material values to per-surface restitution
			-- multipliers. Stored directly on Behavior for O(1) lookup in ResolveBounce.
			MaterialRestitution = ResolvedMaterialRestitution,
			NormalPerturbation = ResolvedNormalPerturbation,

			HighFidelitySegmentSize = ResolvedHighFidelitySegmentSize,
			HighFidelityFrameBudget = ResolvedHighFidelityFrameBudget,
			AdaptiveScaleFactor = ResolvedAdaptiveScaleFactor,
			MinSegmentSize = ResolvedMinSegmentSize,
			MaxBouncesPerFrame = ResolvedMaxBouncesPerFrame,

			CornerTimeThreshold = ResolvedCornerTimeThreshold,
			CornerNormalDotThreshold = ResolvedCornerNormalDotThreshold,
			CornerDisplacementThreshold = ResolvedCornerDisplacementThreshold,

			VisualizeCasts = ResolvedVisualizeCasts,
		},

		-- UserData is a free-form table for weapon code to attach cast-specific
		-- metadata (e.g. shooter's UserId, weapon type, damage value, hit group
		-- flags). It is surfaced on the BulletContext and passed unchanged via
		-- every signal emission so consumers can route events without maintaining
		-- a separate lookup table keyed on cast identity.
		UserData = {},
	}

	-- Attach CAST_STATE_METHODS as the __index metatable so SetVelocity, GetPosition,
	-- etc. are callable on the HybridCast. This is done after construction rather than
	-- inline because the method table is shared across all casts — it must not be
	-- stored per-instance. Using a metatable achieves method sharing at zero per-cast
	-- memory cost.
	setmetatable(HybridCast,{ __index = CAST_STATE_METHODS})
	-- Wire the ActiveTrajectory pointer after the HybridCast table is fully constructed.
	-- It cannot be set inline inside the Runtime sub-table literal because the
	-- Trajectories table it points into does not exist yet at that point in the
	-- constructor expression. Doing it here, after all sub-tables are created,
	-- guarantees that Trajectories[1] is a valid, populated table.
	HybridCast.Runtime.ActiveTrajectory = HybridCast.Runtime.Trajectories[1]

	-- ─── Cosmetic Bullet Setup ────────────────────────────────────────────────

    --[[
        Two mechanisms are supported for creating the cosmetic bullet object:

        CosmeticBulletProvider (function): Called once during Fire() and must
        return a BasePart or nil. This pattern allows object pooling (the function
        can dequeue from a pool), procedural mesh generation, or any other creation
        strategy. The provider is called synchronously and its execution time is
        measured — anything above PROVIDER_TIMEOUT seconds triggers a warning,
        since a yielding provider would stall the caller's thread.

        CosmeticBulletTemplate (BasePart): A simpler alternative: the template is
        cloned once and used directly. No pooling is possible with this approach,
        but it requires less setup code for simple cases.

        If both are provided, Provider takes priority and a warning is logged to
        alert the caller that Template is being ignored. This prevents silent
        surprises when a shared Behavior table has a default Template set and a
        specific Fire() call also supplies a Provider.
    ]]
	if ResolvedCosmeticBulletProvider ~= nil then
		if type(ResolvedCosmeticBulletProvider) ~= "function" then
			Logger:Warn("Fire: CosmeticBulletProvider must be a function — ignoring")
		else
			if ResolvedCosmeticBulletTemplate then
				Logger:Warn("Fire: CosmeticBulletTemplate is ignored when CosmeticBulletProvider is set")
			end

			-- Measure wall-clock time around the provider call. Providers must not
			-- yield; any call exceeding PROVIDER_TIMEOUT is almost certainly doing so.
			local ProviderStartTime = OsClock()
			local ProviderSuccess, ProviderResult = pcall(ResolvedCosmeticBulletProvider)
			local ProviderElapsedSeconds = OsClock() - ProviderStartTime

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
				-- Parent the bullet to the configured container (or workspace if nil).
				-- Setting Parent here rather than inside the provider gives the solver
				-- control over when the object becomes visible — immediately before
				-- simulation begins, not at some earlier point inside the provider.
				ProviderResult.Parent = ResolvedCosmeticBulletContainer
				HybridCast.Runtime.CosmeticBulletObject = ProviderResult
			end
		end
	elseif ResolvedCosmeticBulletTemplate then
		-- Clone the template. This is a full deep-copy including all descendant
		-- parts and scripts — callers should use a simple BasePart as the template
		-- to keep clone cost low. The clone is parented immediately.
		local ClonedBullet = ResolvedCosmeticBulletTemplate:Clone()
		ClonedBullet.Parent = ResolvedCosmeticBulletContainer
		HybridCast.Runtime.CosmeticBulletObject = ClonedBullet
	end

	-- ─── Registration & Context Linking ──────────────────────────────────────

	-- Register in the active array so _StepProjectile picks up this cast starting
	-- from the next frame. Registering last (after all state is fully constructed)
	-- ensures the cast is never partially visible to the frame loop.
	Register(HybridCast)

	-- Establish the bidirectional weak map between the internal HybridCast and the
	-- public BulletContext. Both directions are set atomically (no intermediate
	-- state where one is set and the other is not) to prevent a race where a
	-- signal fires between the two assignments and fails to find its reverse mapping.
	CastToBulletContext[HybridCast] = Context
	BulletContextToCast[Context] = HybridCast

	-- Inject a Terminate closure into the context's __solverData table. This is
	-- the mechanism by which context:Terminate() reaches the internal HybridCast
	-- without the context holding a direct reference to the internal solver table.
	-- The closure captures HybridCast by upvalue, so it is always valid for the
	-- lifetime of the context object.
	if Context.__solverData and type(Context.__solverData) == "table" then
		Context.__solverData.Terminate = function()
			Terminate(HybridCast)
		end
	end

	return HybridCast
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--[=[
    HybridSolver:GetSignals

    Description:
        Returns the module-level Signals table, giving consumers access to the
        five event signals: OnHit, OnTravel, OnPierce, OnBounce, and OnTerminated.

        Because signals are module-level rather than per-cast, consumers call this
        once during initialisation (e.g. in a weapon module's :Init method) and
        the connected handlers receive events from every cast managed by this solver.
        The BulletContext argument on each signal allows handlers to dispatch by
        cast identity, accessing context.UserData to retrieve cast-specific metadata
        such as the shooter's identity or weapon type.

        Returning the table by reference (not a copy) means consumers see the same
        Signal objects that the solver fires. There is no performance cost to calling
        GetSignals() on every frame — it is a simple field read.

    Returns:
        { OnHit, OnTravel, OnPierce, OnBounce, OnTerminated }
            The shared Signals table. See the Signals declaration comments for
            detailed per-signal contracts, argument types, and usage notes.
]=]
function HybridSolver.GetSignals(Self: HybridSolver)
	return Signals
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    The Factory table is what consumers receive when they require this module.
    Calling Factory.new() creates a HybridSolver instance and starts the
    per-frame simulation loop.

    Why a factory pattern rather than a singleton?
        The frame loop connection is deferred to Factory.new() rather than
        established at module load time. This means the simulation loop does not
        start until a consumer explicitly creates a solver — avoiding an unnecessary
        RunService connection in any game mode or context that requires this module
        but does not actually fire projectiles (e.g. a menu screen that requires
        the module for type checking only).

    Why a metatable-based instance rather than returning HybridSolver directly?
        The returned instance is a new empty table with HybridSolver as its
        __index. This keeps the public API surface clean (consumers see only the
        methods defined on HybridSolver) while all state is managed at module scope.
        Multiple calls to Factory.new() return distinct instance tables that all
        share the same underlying module-level state — which is correct because
        there is only one _ActiveCasts registry and one set of Signals.
]]
local Factory = {}
Factory.__type = IDENTITY

-- Re-export BehaviorBuilder so consumers can do:
--     local HybridSolver = require(path.to.HybridSolver)
--     local Behavior = HybridSolver.BehaviorBuilder.Sniper():Build()
-- rather than requiring BehaviorBuilder separately and keeping two module
-- paths in sync across every weapon script.
Factory.BehaviorBuilder = BehaviorBuilder

--[=[
    Factory.new

    Description:
        Creates a HybridSolver instance and connects the per-frame simulation loop
        to the appropriate RunService event (Heartbeat on server, RenderStepped
        on client). Must be called before any :Fire() calls.

        The _FrameLoopActive guard prevents the frame loop from being connected
        more than once. Multiple connections would cause every active cast to be
        simulated multiple times per frame — a hard-to-diagnose bug where bullets
        move at integer multiples of their intended speed. The guard logs a warning
        and returns a valid (though redundant) solver instance rather than throwing,
        so production code that accidentally calls new() twice does not crash.

    Returns:
        HybridSolver
            The solver instance. Call :Fire() on it to create projectiles and
            :GetSignals() to connect event handlers.
]=]
local _FrameLoopActive = false

function Factory.new(): HybridSolver
	if _FrameLoopActive then
		-- Warn rather than error: a duplicate new() call is a bug but not a
		-- crash-level failure. The returned instance still works correctly —
		-- it shares the same module-level state as the original instance.
		Logger:Warn("Factory.new: called more than once — returning existing solver instance")
		return setmetatable({}, { __index = HybridSolver })
	end

	_FrameLoopActive = true
	-- Connect the simulation loop once. All subsequent projectile simulation is
	-- driven by this single connection — no per-cast connections are ever created.
	-- The lambda wrapper passes FrameDelta as a named parameter to _StepProjectile
	-- for readability and to avoid using the implicit vararg inside _StepProjectile.
	_FrameEvent:Connect(function(FrameDelta: number)
		_StepProjectile(FrameDelta)
	end)

	return setmetatable({}, { __index = HybridSolver })
end
-- ─── Type Exports ────────────────────────────────────────────────────────────
export type HybridCast = Type.HybridCast & typeof(CAST_STATE_METHODS)

export type HybridBehavior = {
	-- ─── Physics ─────────────────────────────────────────────────────────────
	Acceleration                 : Vector3?,
	MaxDistance                  : number?,
	RaycastParams                : RaycastParams?,
	Gravity                      : Vector3?,
	MinSpeed                     : number?,

	-- ─── Pierce ──────────────────────────────────────────────────────────────
	CanPierceFunction            : ((Context: BulletContext.BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean)?,
	MaxPierceCount               : number?,
	PierceSpeedThreshold         : number?,
	PenetrationSpeedRetention    : number?,
	PierceNormalBias             : number?,

	-- ─── Bounce ──────────────────────────────────────────────────────────────
	CanBounceFunction            : ((Context: BulletContext.BulletContext, Result: RaycastResult, Velocity: Vector3) -> boolean)?,
	MaxBounces                   : number?,
	BounceSpeedThreshold         : number?,
	Restitution                  : number?,
	MaterialRestitution          : { [Enum.Material]: number }?,
	NormalPerturbation           : number?,

	-- ─── High Fidelity ───────────────────────────────────────────────────────
	HighFidelitySegmentSize      : number?,
	HighFidelityFrameBudget      : number?,
	AdaptiveScaleFactor          : number?,
	MinSegmentSize               : number?,
	MaxBouncesPerFrame           : number?,

	-- ─── Corner Trap ─────────────────────────────────────────────────────────
	CornerTimeThreshold          : number?,
	CornerNormalDotThreshold     : number?,
	CornerDisplacementThreshold  : number?,

	-- ─── Cosmetic ────────────────────────────────────────────────────────────
	CosmeticBulletTemplate       : BasePart?,
	CosmeticBulletContainer      : Instance?,
	CosmeticBulletProvider       : (() -> Instance?)?,

	-- ─── Debug ───────────────────────────────────────────────────────────────
	VisualizeCasts               : boolean?,
}

export type HybridSolver = typeof(setmetatable({}, { __index = HybridSolver }))

-- ─── Module Return ───────────────────────────────────────────────────────────

--[[
    The module returns Factory wrapped in a protective metatable.

    __index: Logs a warning when an undefined key is accessed on the Factory.
    This catches typos at runtime — e.g. `HybridSolver.Frie(...)` would silently
    return nil and produce a confusing "attempt to call nil value" error deep inside
    weapon code. With this guard, the error is surfaced immediately at the access
    site with a clear message identifying the invalid key name.

    __newindex: Prevents external code from adding new keys to the Factory table.
    Module tables returned by require() are shared across all consumers — any code
    that writes a field onto the Factory table would mutate it for all consumers
    simultaneously. This guard converts that silent global mutation into an explicit
    error, preventing accidental cross-consumer interference via module-level state.
]]
return setmetatable(Factory, {
	__index = function(_, Key)
		Logger:Warn(string.format("HybridSolver: attempt to index nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key)
		Logger:Error(string.format("HybridSolver: attempt to write to protected key '%s'", tostring(Key)))
	end,
})