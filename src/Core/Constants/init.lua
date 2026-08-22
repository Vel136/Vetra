--!strict
--!optimize 2
--!native

return table.freeze({
	LOOK_AT_FALLBACK = Vector3.new(0, 0, 1),
	UP_VECTOR        = Vector3.new(0, 1, 0),
	RIGHT_VECTOR     = Vector3.new(1, 0, 0),

	MIN_MAGNITUDE_SQ = 1e-12,
	MIN_DOT_SQ       = 1e-6,
	MIN_VELOCITY_SQ  = 1e-12,

	MIN_HOMING_ARRIVAL_DISTANCE    = 1e-4,
	MIN_HOMING_ARRIVAL_DISTANCE_SQ = 1e-8,

	MIN_ANGLE_RAD    = 1e-6,
	MIN_SPIN_MAGNITUDE = 0.01,

	PERPENDICULAR_AXIS_THRESHOLD = 0.9,
	PIERCE_MAX_ITERATIONS        = 100,
	PROVIDER_VELOCITY_EPSILON    = 1e-3,

	NUDGE       = 0.01,
	ZERO_VECTOR = Vector3.zero,
	SPEED_OF_SOUND = 340,

	MACH_TABLES = require(script.MachTables),

	DEFAULT_AIR_DENSITY       = 1.225,
	DEFAULT_MAX_ANGULAR_SPEED = 200 * math.pi,
	ANGULAR_SUBSTEP           = 1 / 240,

	MAX_SUBSEGMENTS        = 500,
	HF_SUBSEGMENT_SOFT_CAP = 96,

	RAY_ORIGIN_EPSILON = 1.2e-6,
	GLOBAL_FRAME_BUDGET_MS = 4,
	PARALLEL_HF_WORKER_BUDGET_MS = 6,

	PARALLEL_DEFAULT_SHARD_COUNT = 4,

	PARALLEL_CLOCK_ADVANCE_MAX_DELTA = 1 / 10,

	MAX_PARAMS_POOL_SIZE = 2048,
	PROVIDER_TIMEOUT     = .1,

	SPATIAL_TIERS = table.freeze({
		HOT  = 1,
		WARM = 2,
		COLD = 4,
	}),

	SPATIAL_DEFAULT_CELL_SIZE       = 50,
	SPATIAL_DEFAULT_HOT_RADIUS      = 1,
	SPATIAL_DEFAULT_WARM_RADIUS     = 3,
	SPATIAL_DEFAULT_UPDATE_INTERVAL = 3,

	SPATIAL_CELL_STRIDE    = 65536,
	SPATIAL_CELL_OFFSET    = 32768,
	SPATIAL_CELL_STRIDE_SQ = 65536 * 65536,

	THRESHOLD_DIRECTION = {
		Ascending  = true,
		Descending = false,
	},

	VISUALIZER_FOLDER_NAME = "VetraSolverVisualization",
	VISUALIZER_LIFETIME    = 10,

	COLOR_SEGMENT_CLIENT = Color3.new(1, 0, 0),
	COLOR_SEGMENT_SERVER = Color3.fromRGB(255, 145, 11),

	COLOR_HIT_TERMINAL = Color3.new(0.2, 1, 0.5),
	COLOR_HIT_BOUNCE   = Color3.new(1, 0.85, 0.1),
	COLOR_HIT_PIERCE   = Color3.new(1, 0.2, 0.2),

	PARALLEL_EVENT = table.freeze({
		Travel        = "travel",
		Hit           = "hit",
		BouncePending = "bounce_pending",
		Bounce        = "bounce",
		PiercePending = "pierce_pending",
		DistanceEnd   = "dist_end",
		DisplacementEnd = "disp_end",
		SpeedEnd      = "spd_end",
		TrajUpdate    = "traj_update",
		Skip          = "skip",
	}),

	VISUALIZER_HIT_TYPE = table.freeze({
		Terminal = "terminal",
		Bounce   = "bounce",
		Pierce   = "pierce",
	}),
})
