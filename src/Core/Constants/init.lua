--!native
--!optimize 2
--!strict

-- ─── Vetra Constants ─────────────────────────────────────────────────────────
--
-- Single source of truth for every magic number, string, and vector constant
-- used across Vetra's modules. All consumers require this module and reference
-- values by name rather than re-declaring them locally.
--
-- Rules:
--   • Only pure, context-free values live here (numbers, strings, frozen
--     vectors, colours). Values that depend on runtime state — e.g. anything
--     that reads workspace or RunService — belong in the module that uses them.
--   • This table is frozen; no module may write to it.
-- ─────────────────────────────────────────────────────────────────────────────

return table.freeze({

	-- Fallback look-at direction for cosmetic bullet orientation when speed
	-- is near zero (velocity.Unit would be NaN). Points along +Z axis.
	LOOK_AT_FALLBACK = Vector3.new(0, 0, 1),

	-- World up vector — used for perpendicular axis selection in cone sampling.
	UP_VECTOR = Vector3.new(0, 1, 0),

	-- World right vector — fallback perpendicular axis when BaseDirection is
	-- nearly parallel to UP_VECTOR.
	RIGHT_VECTOR = Vector3.new(1, 0, 0),

	-- Minimum squared magnitude for velocity, normals, and displacement vectors.
	-- Below this threshold a vector is considered degenerate.
	-- Equivalent to Magnitude < 1e-6.
	MIN_MAGNITUDE_SQ = 1e-12,

	-- Minimum value for Dot(v,v) comparisons that were originally written as
	-- Dot() > 1e-6 (i.e. already squared, not replacing a .Magnitude check).
	MIN_DOT_SQ = 1e-6,

	-- Minimum squared velocity magnitude before a direction is considered
	-- degenerate (avoids NaN from .Unit on near-zero vectors).
	MIN_VELOCITY_SQ = 1e-12,

	-- Minimum distance to homing target before the cast is considered arrived.
	MIN_HOMING_ARRIVAL_DISTANCE = 1e-4,
	MIN_HOMING_ARRIVAL_DISTANCE_SQ = 1e-8,

	-- Minimum angle in radians before a direction is considered already aligned.
	-- Used as fast-exit in Rodrigues rotation to avoid degenerate cross products.
	MIN_ANGLE_RAD = 1e-6,

	-- Spin magnitude floor in Magnus decay. Below this value SpinVector is
	-- zeroed to avoid asymptotic never-quite-zero spin.
	MIN_SPIN_MAGNITUDE = 0.01,

	-- Dot-product threshold for selecting perpendicular axis in cone sampling.
	-- If |BaseDirection.X| < this, use X axis; otherwise use Y axis.
	PERPENDICULAR_AXIS_THRESHOLD = 0.9,

	-- Hard iteration cap for the pierce chain loop. Guards against degenerate
	-- geometry (stacked zero-thickness meshes) causing an infinite loop.
	PIERCE_MAX_ITERATIONS = 100,

	-- Epsilon for forward-difference velocity approximation in
	-- TrajectoryPositionProvider. Small enough for accuracy, large enough
	-- to avoid floating-point noise.
	PROVIDER_VELOCITY_EPSILON = 1e-3,

	-- ── Physics ──────────────────────────────────────────────────────────────

	-- Small positional offset applied after a bounce or pierce to prevent the
	-- next raycast from immediately re-hitting the same surface.
	NUDGE = 0.01,

	-- Shared zero vector — avoids repeated Vector3.zero allocations.
	ZERO_VECTOR = Vector3.zero,

	-- Speed of sound in studs/s. Used by drag physics and the supersonic
	-- transition signal.
	SPEED_OF_SOUND = 340,
	
	-- NOTE: DEFAULT_GRAVITY is intentionally absent from Constants.
	-- workspace.Gravity is a runtime value that can change (gravity zones,
	-- zero-G sections, etc.). Computing it once at require() time would
	-- permanently freeze it for all subsequent casts. Callers that need a
	-- gravity default must read workspace.Gravity at cast-fire time instead.

	-- Re-export of Core/MachTables so callers that already have a Constants
	-- reference do not need a separate require.
	MACH_TABLES = require(script.MachTables),

	-- ── 6DOF Defaults ────────────────────────────────────────────────────────
	-- Default air density for aerodynamic force calculations. Unity-normalised
	-- for game-scale tuning — multiply by ReferenceArea to get physically
	-- meaningful results.
	DEFAULT_AIR_DENSITY       = 1.225,

	-- Default maximum angular speed (rad/s). Prevents divergence from
	-- improperly tuned aerodynamic coefficients. 200π ≈ 628 rad/s ≈ 6000 RPM.
	DEFAULT_MAX_ANGULAR_SPEED = 200 * math.pi,

	-- Fixed sub-step size for 6DOF angular integration (seconds).
	-- Smaller values reduce integration error on stiff gyroscopic systems
	-- (pitching moment + precession) at the cost of more iterations per
	-- drag-recalc interval. 1/240 keeps error below 0.01 rad for all
	-- coefficients in the documented tuning range while adding at most
	-- ~2 extra iterations per frame at the default DragSegmentInterval.
	ANGULAR_SUBSTEP = 1 / 240,

	-- ── Simulation ───────────────────────────────────────────────────────────

	-- Hard ceiling on sub-segments generated per high-fidelity resimulation
	-- pass. Exceeding this cap triggers an adaptive segment-size increase.
	MAX_SUBSEGMENTS = 500,

	-- Default per-frame CPU budget for the high-fidelity resimulation loop,
	-- in milliseconds.
	GLOBAL_FRAME_BUDGET_MS = 4,


	-- ── Core / Pooling ───────────────────────────────────────────────────────

	-- Maximum number of RaycastParams instances kept in the pool. Requests
	-- beyond this limit fall back to direct allocation.
	MAX_PARAMS_POOL_SIZE = 2048,

	-- Maximum number of VeSignal connection objects held in the free list
	-- between firings. Keeps GC pressure low for high-frequency signals.
	MAX_SIGNAL_POOL_SIZE = 1000,

	-- Maximum seconds a CosmeticBulletProvider function may run before Vetra
	-- warns that it is likely yielding unintentionally.
	PROVIDER_TIMEOUT = .1,


	-- ── Spatial Partition ────────────────────────────────────────────────────

	-- Step frequency tiers. Values represent "step every N frames".
	-- HOT = full fidelity, WARM = half, COLD = quarter.
	SPATIAL_TIERS = table.freeze({
		HOT  = 1,
		WARM = 2,
		COLD = 4,
	}),

	-- Size of each grid cell in studs.
	SPATIAL_DEFAULT_CELL_SIZE       = 50,

	-- Radius (in cells) around each interest point marked as HOT.
	SPATIAL_DEFAULT_HOT_RADIUS      = 1,

	-- Radius (in cells) around each interest point marked as WARM.
	-- Cells inside HotRadius are already HOT so WARM only fills the ring beyond.
	SPATIAL_DEFAULT_WARM_RADIUS     = 3,

	-- How many frames between grid rebuilds.
	SPATIAL_DEFAULT_UPDATE_INTERVAL = 3,

	THRESHOLD_DIRECTION = {
		Ascending  = true,
		Descending = false,
	},
	-- ── Visualizer ───────────────────────────────────────────────────────────

	-- Name of the Folder parented under workspace.Terrain that holds all
	-- debug adornments. Changing this string changes where adornments appear
	-- in the Explorer.
	VISUALIZER_FOLDER_NAME = "VetraSolverVisualization",

	-- Lifetime in seconds of each debug adornment before Debris removes it.
	VISUALIZER_LIFETIME = 3,

	-- Segment colours — server and client use different colours so trajectory
	-- mismatches can be diagnosed by colour alone.
	COLOR_SEGMENT_CLIENT = Color3.new(1, 0, 0),
	COLOR_SEGMENT_SERVER = Color3.fromRGB(255, 145, 11),

	-- Impact point colours — three distinct colours prevent misreading a
	-- pierce as a terminal hit or a bounce as a pierce.
	COLOR_HIT_TERMINAL = Color3.new(0.2, 1, 0.5),
	COLOR_HIT_BOUNCE   = Color3.new(1, 0.85, 0.1),
	COLOR_HIT_PIERCE   = Color3.new(1, 0.2, 0.2),

	-- ── Parallel Events ──────────────────────────────────────────────────────

	-- Event type identifiers written by ActorWorker/ParallelPhysics into the
	-- SharedTable result buffer, and read by Coordinator in the apply pass.
	-- Centralised here so both sides reference the same constant — a mismatch
	-- becomes a nil comparison (never matches) rather than a silent drop.
	PARALLEL_EVENT = table.freeze({
		Travel        = "travel",
		Hit           = "hit",
		BouncePending = "bounce_pending",
		Bounce        = "bounce",
		PiercePending = "pierce_pending",
		DistanceEnd   = "dist_end",
		SpeedEnd      = "spd_end",
		TrajUpdate    = "traj_update",
		Skip          = "skip",
	}),

	-- ── Validation Results ─────────────────────────────────────────────────

	-- Outcome identifiers returned by HitValidator.Validate().
	-- Callers should always compare against these constants rather than raw
	-- strings so a rename here produces a type error, not a silent mismatch.
	VALIDATION_RESULT = table.freeze({
		Validated  = "Validated",
		Suspicious = "Suspicious",
		Rejected   = "Rejected",
	}),

	-- ── Visualizer Hit Types ───────────────────────────────────────────────

	-- Passed to Visualizer.Hit() to select the marker colour.
	-- Using this enum instead of raw strings prevents silent mismatches when
	-- the string values are ever renamed.
	VISUALIZER_HIT_TYPE = table.freeze({
		Terminal = "terminal",
		Bounce   = "bounce",
		Pierce   = "pierce",
	}),
})