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

	-- Fixed-size ring buffer of recent bounce contact positions (world-space).
	-- Written by Bounce.RecordBounceState; read by IsCornerTrap Pass 2.
	-- Replaces the old single LastBouncePosition scalar — the buffer lets Pass 2
	-- detect revisits regardless of how many intermediate bounces occurred.
	BouncePositionHistory  : { Vector3 },

	-- Write cursor for BouncePositionHistory. Advances modulo CornerPositionHistorySize
	-- on each bounce, producing a circular overwrite pattern with no allocation.
	BouncePositionHead     : number,

	-- Exponential moving average of post-bounce unit velocity vectors.
	-- Converges toward zero when bounce directions cancel (trapped); stays
	-- healthy when the bullet makes consistent forward progress. Initialised
	-- to Vector3.zero so the first bounce seeds the EMA from a neutral state.
	-- Updated by Bounce.RecordBounceState; read by IsCornerTrap Pass 3.
	VelocityDirectionEMA   : Vector3,

	-- ─── Pass 4: Net-Displacement Guard ──────────────────────────────────────

	-- World-space position of the very first bounce contact ever recorded for
	-- this cast. Written once by Bounce.RecordBounceState on the first bounce
	-- and never overwritten thereafter. Pass 4 measures displacement from this
	-- origin to detect bullets that bounce many times without going anywhere.
	-- Nil until the first bounce occurs.
	FirstBouncePosition    : Vector3?,

	-- Running count of bounces recorded by RecordBounceState. Kept separate
	-- from BounceCount (which is incremented later by FireOnBounce) so that
	-- Pass 4 always has an accurate count at the moment IsCornerTrap is called.
	CornerBounceCount      : number,

	-- Sentinel for the CanBounceFunction yield-detection guard. Same semantics
	-- as PierceCallbackThread — set before the callback, cleared after return,
	-- and checked at the top of the next top-level frame step.
	BounceCallbackThread   : thread?,

	-- ─── Homing ──────────────────────────────────────────────────────────────

	-- Sentinel for the CanHomeFunction yield-detection guard. Same semantics
	-- as PierceCallbackThread and BounceCallbackThread — set before the callback,
	-- cleared after return, and checked at the top of the next top-level frame step.
	CanHomeCallbackThread  : thread?,

	-- Sentinel for the CastFunction yield-detection guard. Same semantics as
	-- PierceCallbackThread — set before the call, cleared after return, and checked
	-- before the next call. Applies to the serial path only; the parallel path
	-- (Step / StepHighFidelity) already hard-errors on yield via Roblox's runtime.
	CastFunctionThread     : thread?,

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

	-- ─── Penetration ─────────────────────────────────────────────────────────

	-- Remaining kinetic energy budget for penetration (in studs).
	-- Initialised to Behavior.PenetrationForce at Fire() time and decremented
	-- by each pierce's measured material thickness. When it reaches 0 the
	-- bullet stops inside the material. nil when PenetrationForce is disabled.
	PenetrationForceRemaining : number?,

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

export type CanHomeFunction = (
	context         : any,     -- BulletContext (public API object)
	currentPosition : Vector3, -- Current bullet world-space position
	currentVelocity : Vector3  -- Current bullet velocity
) -> boolean

-- Optional user-supplied cast function. Replaces the built-in workspace:Raycast
-- so consumers can use Spherecast, Blockcast, or any custom intersection test.
-- Must return a RaycastResult-compatible value (Position, Normal, Material, Instance)
-- or nil for no hit. Safe to call from parallel context if it only wraps a
-- workspace cast method — arbitrary Lua must not yield or write Instance properties.
export type CastFunction = (
	origin    : Vector3,
	direction : Vector3, -- NOT a unit vector; magnitude = displacement distance
	params    : RaycastParams
) -> RaycastResult?

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

	-- Maximum bullet speed in studs/second. OnHit fires with nil RaycastResult
	-- when the current speed exceeds this threshold. Defaults to math.huge (no cap).
	MaxSpeed                   : number,

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

	-- Optional custom cast function. When set, replaces workspace:Raycast for every
	-- intersection test this cast performs — including parallel steps and high-fidelity
	-- sub-segments. Use this to support Spherecast, Blockcast, or any bespoke test.
	-- nil = use the default workspace:Raycast.
	CastFunction               : CastFunction?,

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

	-- Maximum material thickness (in studs) the bullet can penetrate.
	-- A secondary raycast is fired from inside the object outward to measure
	-- actual thickness. If thickness > PenetrationDepth, the bullet stops inside.
	-- 0 = disabled (no thickness check).
	PenetrationDepth           : number,

	-- Kinetic energy budget (in studs) available for penetration.
	-- Each stud of material thickness consumes this budget. If exhausted before
	-- the exit point, the bullet stops inside the material.
	-- 0 = disabled (no energy budget check).
	PenetrationForce           : number,

	-- ─── Homing ──────────────────────────────────────────────────────────────

	-- Optional callback: return true to allow homing to steer this frame.
	-- Return false to temporarily suppress homing without permanently disengaging.
	-- Must be synchronous (must not yield). nil = always home when active.
	CanHomeFunction            : CanHomeFunction?,

	-- ─── Bullet Mass ─────────────────────────────────────────────────────────

	-- Mass of the bullet in kilograms. Used to compute ImpactForce on OnHit
	-- and BounceForce on OnBounce. 0 = disabled (forces are zero vectors).
	BulletMass                 : number,

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

	-- Number of recent bounce contact positions kept in the ring buffer.
	-- IsCornerTrap Pass 2 checks whether the new contact is within
	-- CornerDisplacementThreshold of any buffered position. A value of 4
	-- catches 2-wall, 3-wall, and most multi-surface traps within the first
	-- full cycle. Larger values increase detection range at trivial cost.
	CornerPositionHistorySize  : number,

	-- Maximum stud distance (squared internally) between a new contact and any
	-- buffered contact for Pass 2 to declare a revisit. Geometry-agnostic:
	-- works for any wall angle without geometric tuning.
	CornerDisplacementThreshold: number,

	-- ─── Corner Trap Pass 4 ───────────────────────────────────────────────────

	-- Minimum studs of net displacement required per bounce from the first
	-- bounce contact position. After N bounces the bullet must be at least
	-- N x CornerMinProgressPerBounce studs away from FirstBouncePosition.
	-- Catches slow-drift and ring-buffer-exhaustion cases that Passes 1-3 may
	-- not accumulate enough history to detect in time.
	-- Set to 0 to disable Pass 4 entirely (e.g. intentional billiard-style loops).
	CornerMinProgressPerBounce : number,

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

-- ─── ParallelTrajectorySegment ───────────────────────────────────────────────
--[[
    Plain-data trajectory segment used by the parallel physics system.
    Unlike CastTrajectory it carries no EndTime, IsSampled, or SampledFn —
    those are main-thread concerns only.

    This is the SSOT for the segment shape that:
      • ParallelPhysics produces in NewTrajectory results
      • ActorWorker stores in its local per-cast state
      • Coordinator/_ResumeCast passes back to the Actor
      • EventHandlers reads when applying trajectory updates
]]
export type ParallelTrajectorySegment = {
	Origin          : Vector3,
	InitialVelocity : Vector3,
	Acceleration    : Vector3,
	StartTime       : number,
}

-- ─── CastSnapshot ────────────────────────────────────────────────────────────
--[[
    The complete read-only snapshot of a cast's state consumed by
    ParallelPhysics.Step and ParallelPhysics.StepHighFidelity.

    This is the SSOT for:
      • What ActorWorker must store and populate per local cast
      • What Coordinator._AddCastMessage must include
      • What ParallelPhysics is permitted to read (never writes back)

    Results are returned via ParallelResult — this table is never mutated
    by the parallel physics module.
]]
export type CastSnapshot = {
	-- Identity
	Id                          : number,

	-- Active trajectory
	TrajectoryOrigin            : Vector3,
	TrajectoryInitialVelocity   : Vector3,
	TrajectoryAcceleration      : Vector3,
	TrajectoryStartTime         : number,

	-- Runtime scalars
	TotalRuntime                : number,
	DistanceCovered             : number,
	IsSupersonic                : boolean,
	LastDragRecalculateTime     : number,
	SpinVector                  : Vector3,
	HomingElapsed               : number,
	HomingDisengaged            : boolean,
	HomingAcquired              : boolean,
	CurrentSegmentSize          : number,
	BouncesThisFrame            : number,
	IsTumbling                  : boolean,
	TumbleRandom                : Random?,   -- seeded from CastId; nil until tumble begins
	BounceCount                 : number,
	PierceCount                 : number,
	LastBounceTime              : number,

	-- LOD / Spatial
	IsLOD                       : boolean,
	LODDistance                 : number,
	LODFrameAccumulator         : number,
	LODDeltaAccumulator         : number,
	SpatialFrameAccumulator     : number,
	SpatialDeltaAccumulator     : number,
	SpatialTier                 : number,
	LODOrigin                   : Vector3?,

	-- Bounce tracking (corner trap)
	BouncePositionHistory       : { Vector3 },
	BouncePositionHead          : number,
	VelocityDirectionEMA        : Vector3,
	FirstBouncePosition         : Vector3?,
	CornerBounceCount           : number,

	-- Behavior: limits
	MaxDistance                 : number,
	MinSpeed                    : number,
	MaxSpeed                    : number,
	MaxBounces                  : number,
	MaxBouncesPerFrame          : number,
	MaxPierceCount              : number,

	-- Behavior: drag
	DragCoefficient             : number,
	DragModel                   : number,
	DragSegmentInterval         : number,

	-- Behavior: bounce
	BounceSpeedThreshold        : number,
	Restitution                 : number,
	NormalPerturbation          : number,
	MaterialRestitution         : { [string]: number }?,

	-- Behavior: pierce
	PierceSpeedThreshold        : number,
	PenetrationSpeedRetention   : number,
	PierceNormalBias            : number,

	-- Behavior: magnus
	MagnusCoefficient           : number,
	SpinDecayRate               : number,

	-- Behavior: homing
	HomingStrength              : number,
	HomingMaxDuration           : number,
	HomingTarget                : Vector3?,

	-- Behavior: high fidelity
	HighFidelitySegmentSize     : number,
	AdaptiveScaleFactor         : number,
	MinSegmentSize              : number,
	HighFidelityFrameBudget     : number,

	-- Behavior: corner trap config
	CornerTimeThreshold         : number,
	CornerDisplacementThreshold : number,
	CornerEMAAlpha              : number,
	CornerEMAThreshold          : number,
	CornerMinProgressPerBounce  : number,

	-- Callback presence flags
	HasCanPierceCallback        : boolean,
	HasCanBounceCallback        : boolean,
	HasCanHomeCallback          : boolean,


	-- Speed profiles (nil when not configured)
	SupersonicDragCoefficient   : number?,
	SupersonicDragModel         : number?,
	SubsonicDragCoefficient     : number?,
	SubsonicDragModel           : number?,

	-- Physics environment
	BaseAcceleration            : Vector3,
	Wind                        : Vector3,
	WindResponse                : number,
	GyroDriftRate               : number?,
	GyroDriftAxis               : Vector3?,
	TumbleSpeedThreshold        : number?,
	TumbleDragMultiplier        : number?,
	TumbleLateralStrength       : number?,
	TumbleOnPierce              : boolean?,
	TumbleRecoverySpeed         : number?,

	-- Raycast filter transport fields.
	-- RaycastParams cannot cross Actor boundaries — the Actor reconstructs
	-- its own local RaycastParams from these two fields on AddCast.
	-- ParallelPhysics.Step receives the Actor-local RaycastParams object
	-- directly in the snapshot table (not serialized through here).
	FilterType                  : Enum.RaycastFilterType,
	FilterList                  : { Instance },

	-- Misc
	VisualizeCasts              : boolean,

	-- Provider positions (pre-fetched on main thread, nil when not used)
	ProvidedLastPosition        : Vector3?,
	ProvidedCurrentPosition     : Vector3?,
	ProvidedCurrentVelocity     : Vector3?,

	-- Remaining resim delta after a pending event was resolved
	RemainingResimDelta         : number?,
}

-- ─── ParallelResult ──────────────────────────────────────────────────────────
--[[
    The plain-data result table returned by ParallelPhysics.Step and
    ParallelPhysics.StepHighFidelity.

    This is the SSOT for what the Actor serialises into SharedTable via
    PackEvent / PackTravelEvent, and what EventHandlers / Coordinator reads
    during the apply pass. All fields are optional except Id and Event —
    each event type populates only the subset it needs.
]]
export type ParallelResult = {
	-- Always present
	Id    : number,
	Event : string,  -- PARALLEL_EVENT constant

	-- Runtime state updates (present on all non-skip events)
	TotalRuntime             : number?,
	DistanceCovered          : number?,
	IsSupersonic             : boolean?,
	LastDragRecalcTime       : number?,
	SpinVector               : Vector3?,
	HomingElapsed            : number?,
	HomingDisengaged         : boolean?,
	HomingAcquired           : boolean?,
	CurrentSegmentSize       : number?,
	BouncesThisFrame         : number?,
	IsLOD                    : boolean?,
	LODFrameAccumulator      : number?,
	LODDeltaAccumulator      : number?,
	SpatialFrameAccumulator  : number?,
	SpatialDeltaAccumulator  : number?,

	-- Trajectory opened during this step (drag, homing, bounce)
	Trajectory               : ParallelTrajectorySegment?,

	-- Geometry (hit / bounce / pierce)
	HitPosition              : Vector3?,
	HitNormal                : Vector3?,
	HitMaterial              : Enum.Material?,
	RayOrigin                : Vector3?,

	-- Travel position / velocity
	TravelPosition           : Vector3?,
	TravelVelocity           : Vector3?,
	FiredAccumulatedDelta    : number?,
	CosmeticCFrame           : CFrame?,
	VisualizationRayOrigin   : Vector3?,

	-- Bounce-specific
	PreBounceVelocity        : Vector3?,
	ReflectedVelocity        : Vector3?,
	IsCornerTrap             : boolean?,
	BounceCount              : number?,
	LastBounceTime           : number?,
	BouncePositionHistory    : { Vector3 }?,
	BouncePositionHead       : number?,
	VelocityDirectionEMA     : Vector3?,
	FirstBouncePosition      : Vector3?,
	CornerBounceCount        : number?,

	-- Pending event: remaining sub-segment time for resimulation resumption
	RemainingResimDelta      : number?,
}

-- ─── ResumeSyncData ──────────────────────────────────────────────────────────
--[[
    Partial snapshot sent from the main thread to an Actor via
    Coordinator:_ResumeCast. Contains only the fields that may have changed
    during main-thread processing (hook callbacks, Pierce.ResolveChain, bounce
    reflection) and need to be synced back before the Actor resumes stepping.
    All fields are optional — each handler populates only what it touched.
]]
export type ResumeSyncData = {
	TotalRuntime    : number?,
	DistanceCovered : number?,
	PierceCount     : number?,
	BounceCount     : number?,
	BouncesThisFrame: number?,
	LastBounceTime  : number?,

	TrajectoryOrigin          : Vector3?,
	TrajectoryInitialVelocity : Vector3?,
	TrajectoryAcceleration    : Vector3?,
	TrajectoryStartTime       : number?,

	BouncePositionHistory : { Vector3 }?,
	BouncePositionHead    : number?,
	VelocityDirectionEMA  : Vector3?,
	FirstBouncePosition   : Vector3?,
	CornerBounceCount     : number?,

	RemainingResimDelta : number?,
}

return {}