-- ─── CastTrajectory ──────────────────────────────────────────────────────────

--[[
    Represents one continuous arc of a projectile's flight path.
    A new segment is appended to Runtime.Trajectories whenever the bullet
    bounces, or when ModifyTrajectory opens a new arc due to a mid-flight
    kinematic change. EndTime of -1 indicates the segment is still active.
]]
export type CastTrajectory = {
	StartTime       : number,   -- Runtime.TotalRuntime when this segment began
	EndTime         : number,   -- Runtime.TotalRuntime when closed; -1 while active
	Origin          : Vector3,  -- World-space start position of this arc
	InitialVelocity : Vector3,  -- Velocity at StartTime (studs/second)
	Acceleration    : Vector3,  -- Constant acceleration for this arc (gravity + extra)
}

-- ─── CastRuntime ─────────────────────────────────────────────────────────────

--[[
    All state that changes frame-to-frame during a cast's lifetime.
    Kept separate from CastBehavior (invariant config) so it is immediately
    clear which fields are mutable vs. fixed after Fire().
]]
export type CastRuntime = {
	-- ─── Core ────────────────────────────────────────────────────────────────

	-- Simulation clock in seconds, relative to the cast's birth (not wall time).
	-- Advances by Delta on every SimulateCast call; does NOT advance while paused.
	TotalRuntime           : number,

	-- Cumulative distance the bullet has travelled along its actual ray path.
	-- Compared against Behavior.MaxDistance each frame for distance termination.
	DistanceCovered        : number,

	-- ─── Trajectory ──────────────────────────────────────────────────────────

	-- Ordered history of all arc segments. Trajectories[1] is always the initial
	-- firing arc. New entries are appended on every bounce or ModifyTrajectory call.
	Trajectories           : { CastTrajectory },

	-- Direct reference to the currently simulated segment (always Trajectories[N]
	-- for the most recently appended N). Avoids re-indexing the array each frame.
	ActiveTrajectory       : CastTrajectory,

	-- ─── Pierce ──────────────────────────────────────────────────────────────

	-- Total number of successful pierces so far (incremented by FireOnPierce
	-- before the OnPierce signal fires).
	PierceCount            : number,

	-- Every instance that has been pierced during this cast's lifetime. Used to
	-- detect re-encounter of a previously pierced instance via a later sub-segment.
	PiercedInstances       : { Instance },

	-- Sentinel for the CanPierceFunction yield-detection guard. Set to
	-- coroutine.running() immediately before calling the callback and cleared
	-- immediately after it returns. If it is still set at the start of the NEXT
	-- top-level frame step, the callback must have yielded — the cast is terminated.
	PierceCallbackThread   : thread?,

	-- ─── Bounce ──────────────────────────────────────────────────────────────

	-- Total number of successful bounces so far (incremented by FireOnBounce
	-- before the OnBounce signal fires).
	BounceCount            : number,

	-- Number of bounces that occurred during the current _StepProjectile call.
	-- Reset to 0 at the top of every frame step (not between sub-segments).
	-- Compared against Behavior.MaxBouncesPerFrame to prevent exhausting the
	-- entire bounce budget in a single real-time frame of rapid sub-segment passes.
	BouncesThisFrame       : number,

	-- Wall-clock time (os.clock()) of the most recent bounce. Initialised to
	-- -math.huge so the first bounce never triggers the temporal corner-trap guard.
	LastBounceTime         : number,

	-- Surface normal of the most recent bounce contact. ZERO_VECTOR sentinel
	-- (Vector3.zero) means no bounce has occurred yet, which suppresses the
	-- normal-opposition guard in IsCornerTrap.
	LastBounceNormal       : Vector3,

	-- World-space position of the most recent bounce contact. ZERO_VECTOR
	-- sentinel suppresses the spatial-proximity guard in IsCornerTrap.
	LastBouncePosition     : Vector3,

	-- Sentinel for the CanBounceFunction yield-detection guard. Same semantics
	-- as PierceCallbackThread — set before the callback, cleared after return,
	-- and checked at the top of the next top-level frame step.
	BounceCallbackThread   : thread?,

	-- ─── High Fidelity ───────────────────────────────────────────────────────

	-- True while ResimulateHighFidelity is actively running sub-segments for this
	-- cast. Guards against re-entrant calls (e.g. from a signal handler) that
	-- would otherwise cause infinite recursion.
	IsActivelyResimulating : boolean,

	-- Set to true by SimulateCast when a bounce redirects the bullet onto a new
	-- trajectory, signalling ResimulateHighFidelity's sub-segment loop to stop
	-- processing the now-stale arc. Cleared unconditionally at the end of each
	-- ResimulateHighFidelity call and after each _StepProjectile high-fidelity pass.
	CancelResimulation     : boolean,

	-- The adaptive segment size used by ResimulateHighFidelity. Starts at
	-- Behavior.HighFidelitySegmentSize and is scaled up or down each frame
	-- based on measured wall-clock cost vs. the HighFidelityFrameBudget target.
	CurrentSegmentSize     : number,

	-- ─── Cosmetic ────────────────────────────────────────────────────────────

	-- The live BasePart cosmetic bullet in the world, or nil if none was created.
	-- Positioned and oriented every frame via CFrame.new(pos, lookAt).
	-- Destroyed and nilled during Terminate().
	CosmeticBulletObject   : BasePart?,
}

-- ─── Callback Types ──────────────────────────────────────────────────────────

export type CanPierceFunction = (
	context  : any,          -- BulletContext (public API object)
	result   : RaycastResult,
	velocity : Vector3       -- Current attenuated velocity at point of contact
) -> boolean

export type CanBounceFunction = (
	context  : any,          -- BulletContext (public API object)
	result   : RaycastResult,
	velocity : Vector3       -- Current velocity at point of contact
) -> boolean

-- ─── CastBehavior ────────────────────────────────────────────────────────────

--[[
    All configuration that is fixed for the cast's lifetime (set in Fire() and
    never mutated by the solver). Kept separate from CastRuntime so serialisation
    or inspection of invariant config is straightforward.
]]
export type CastBehavior = {
	-- ─── Physics ─────────────────────────────────────────────────────────────

	-- Pre-computed sum of Gravity + extra Acceleration. Stored once in Fire() so
	-- SimulateCast never needs to recompute the sum at runtime.
	Acceleration               : Vector3,

	-- Maximum flight distance in studs. OnHit fires with nil RaycastResult when
	-- DistanceCovered >= MaxDistance.
	MaxDistance                : number,

	-- Minimum bullet speed in studs/second. OnHit fires with nil RaycastResult
	-- when the current speed falls below this threshold.
	MinSpeed                   : number,

	-- Resolved gravity vector (downward, world-space). Combined with the extra
	-- Acceleration field into the single Acceleration value stored above.
	Gravity                    : Vector3,

	-- When true, ResetPierceState() is called automatically on the cast immediately
	-- after each confirmed bounce opens a new trajectory segment. This restores the
	-- RaycastParams filter, PiercedInstances list, and PierceCount to their Fire()-time
	-- values so the post-bounce arc begins with a clean pierce slate.
	ResetPierceOnBounce		   : boolean,
	-- Pooled (possibly cloned) RaycastParams used for every raycast this cast
	-- performs. The pierce system mutates FilterDescendantsInstances on this object
	-- over the cast's lifetime. Reset to OriginalFilter in Terminate() before the
	-- params are returned to ParamsPooler.
	RaycastParams              : RaycastParams,

	-- ─── Pierce ──────────────────────────────────────────────────────────────

	-- Frozen deep-clone of RaycastParams.FilterDescendantsInstances at Fire() time.
	-- Used in Terminate() to restore the pooled params to a clean state so no
	-- pierce-chain contamination carries over to the next cast that acquires them.
	OriginalFilter             : { Instance },

	-- Optional callback: return true to permit a pierce of the hit instance.
	-- Must be synchronous (must not yield). nil disables piercing entirely.
	CanPierceFunction          : CanPierceFunction?,

	-- Maximum total pierce count for this cast's lifetime. Once PierceCount
	-- reaches this value, all subsequent surfaces are treated as solid hits.
	MaxPierceCount             : number,

	-- Minimum bullet speed required for a pierce attempt. Below this speed the
	-- hit is treated as a solid impact regardless of CanPierceFunction.
	PierceSpeedThreshold       : number,

	-- Fraction of speed retained after each pierce (e.g. 0.8 = 20% energy lost
	-- per pierce). Applied multiplicatively — deeper chains lose progressively more.
	PenetrationSpeedRetention  : number,

	-- Controls minimum approach angle for pierce eligibility.
	-- ImpactDot = |RayDir.Unit · SurfaceNormal|. Pierce requires ImpactDot >= (1 - PierceNormalBias).
	-- 1.0 = all angles accepted; 0.0 = only perfectly perpendicular impacts pierce.
	PierceNormalBias           : number,

	-- ─── Bounce ──────────────────────────────────────────────────────────────

	-- Optional callback: return true to permit a bounce off the hit surface.
	-- Must be synchronous (must not yield). nil disables bouncing entirely.
	CanBounceFunction          : CanBounceFunction?,

	-- Maximum total bounce count for this cast's lifetime.
	MaxBounces                 : number,

	-- Minimum bullet speed required for a bounce attempt. Below this threshold
	-- the hit is treated as a solid terminal impact.
	BounceSpeedThreshold       : number,

	-- Base energy-retention coefficient applied to reflected velocity (0–1).
	-- 1.0 = perfectly elastic; 0.0 = bullet stops dead on contact.
	Restitution                : number,

	-- Optional per-material restitution multipliers. Combined multiplicatively with
	-- the base Restitution in ResolveBounce. nil or absent key → multiplier of 1.0.
	MaterialRestitution        : { [Enum.Material]: number }?,

	-- Magnitude of random normal perturbation applied during bounce reflection,
	-- simulating rough surfaces. 0.0 = clean specular reflection.
	NormalPerturbation         : number,

	-- ─── High Fidelity ───────────────────────────────────────────────────────

	-- Starting (and minimum target) size of each sub-segment in studs. Stored on
	-- Behavior as the initial value; the live adaptive value lives on Runtime.CurrentSegmentSize.
	HighFidelitySegmentSize    : number,

	-- Target wall-clock budget per cast per frame for high-fidelity sub-segment
	-- raycasts, in milliseconds. ResimulateHighFidelity adjusts CurrentSegmentSize
	-- up or down to stay near this target.
	HighFidelityFrameBudget    : number,

	-- Multiplicative factor applied to CurrentSegmentSize when scaling up (over budget)
	-- or down (under half budget). Values > 1 converge faster but overshoot more.
	AdaptiveScaleFactor        : number,

	-- Hard floor for CurrentSegmentSize in studs. Prevents the adaptive algorithm
	-- from shrinking segments to near-zero and producing unbounded raycast counts.
	MinSegmentSize             : number,

	-- Maximum bounces allowed across all sub-segments within a single
	-- _StepProjectile call. Prevents a bullet from exhausting its entire lifetime
	-- bounce budget in one real-time frame of rapid sub-segment processing.
	MaxBouncesPerFrame         : number,

	-- ─── Corner Trap ─────────────────────────────────────────────────────────

	-- Minimum time in seconds that must elapse between successive bounces.
	-- Two bounces closer together than this threshold are treated as a corner trap.
	CornerTimeThreshold        : number,

	-- Dot-product threshold for the normal-opposition guard.
	-- If SurfaceNormal · LastBounceNormal < this value, a corner trap is declared.
	-- Default -0.85 ≈ surfaces within ~32° of face-to-face opposition.
	CornerNormalDotThreshold   : number,

	-- Minimum stud distance between successive bounce contact points.
	-- Displacement below this threshold triggers the spatial-proximity guard.
	CornerDisplacementThreshold: number,

	-- ─── Debug ───────────────────────────────────────────────────────────────

	-- When true, Visualizer draws cast segments, hit points, normals, bounce
	-- vectors, and corner trap markers. Zero runtime cost when false.
	VisualizeCasts             : boolean,
}

-- ─── VetraCast ───────────────────────────────────────────────────────────────

--[[
    The complete internal representation of one in-flight projectile.
    This is the type that _ActiveCasts stores and _StepProjectile iterates.
    It is intentionally kept internal to Vetra — consumers interact
    with BulletContext, not VetraCast directly.
]]
export type VetraCast = {
	-- ─── Lifecycle ───────────────────────────────────────────────────────────

	-- True while the cast is alive and being simulated. Set to false as the very
	-- first action in Terminate() so re-entrant termination calls are no-ops.
	Alive     : boolean,

	-- When true, _StepProjectile skips this cast entirely. TotalRuntime does not
	-- advance, producing seamless resumption from the paused position.
	Paused    : boolean,

	-- Wall-clock time (os.clock()) when Fire() created this cast. Used for external
	-- diagnostics (e.g. computing cast age for effects). NOT used in kinematics —
	-- kinematic time is tracked by Runtime.TotalRuntime.
	StartTime : number,

	-- Registry index in _ActiveCasts. Written by Register() and cleared by Remove().
	-- Enables O(1) swap-remove without a linear search of the active array.
	_registryIndex : number?,

	-- ─── Separated Concerns ──────────────────────────────────────────────────

	Runtime  : CastRuntime,
	Behavior : CastBehavior,

	-- ─── UserData ────────────────────────────────────────────────────────────

	-- Free-form table for weapon code to attach cast-specific metadata (shooter
	-- UserId, weapon type, damage value, hit-group flags, etc.). Surfaced on
	-- BulletContext and passed unchanged via every signal emission.
	UserData : { [any]: any },
}

return {}