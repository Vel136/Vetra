--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — stackable feature benchmark (PARALLEL path)
--
-- Fires CAST_COUNT bullets with whatever combination of features you enable in
-- the TOGGLES block below, then dumps the profiler report. Every toggle is
-- independent, so you can isolate one feature or stack several and watch how the
-- costs compose.
--!strict
-- HOW TO USE
--   1. Flip flags in TOGGLES.
--   2. Run. Read the profiler dump in Output.
--   3. Change ONE flag. Run again. Compare.
--
-- WHAT TO READ IN THE DUMP
--   Main thread (Coordinator) — coordination only. Physics does NOT run here.
--     · "event handler dispatch" scales with events returned per frame, which is
--       driven almost entirely by FireTravelEvents.
--     · "homing/trajectory provider calls" should be ~0 unless Homing is on.
--   Workers — where physics actually runs, concurrently across shards.
--     · "step (base fidelity)" / "step (high fidelity)" are the real sim cost.
--     · "casts stepped" is PER SHARD, not global. Multiply by SHARD_COUNT.
--     · "raycasts skipped by occupancy" is the occupancy grid's payoff.
--     · "casts skipped by LOD" is the LOD throttle's payoff.
--
-- READING IT HONESTLY
--   · Wall-clock frametime is the number that matters. A worker phase growing
--     while frametime drops is fine — workers run in parallel with each other.
--   · The profiler costs time per cast. At high CAST_COUNT it inflates the very
--     worker numbers it reports. Trust the shape and the counters over the
--     absolute milliseconds.
--   · Counters are per-frame averages over the sample window. A shorter window
--     samples an earlier part of the bullets' flight, which shifts LOD and
--     occupancy ratios. Only compare runs with the same SAMPLE_TIME.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Vetra = require(ReplicatedStorage.src)

-- ─────────────────────────────────────────────────────────────────────────────
-- TOGGLES — flip these
-- ─────────────────────────────────────────────────────────────────────────────
local TOGGLES = {
	-- Emit OnTravel every frame. Puts every cast on the sync path: the Coordinator
	-- dispatches a step and reads a record back per cast per frame. Usually the
	-- single most expensive flag on the main thread.
	FireTravelEvents = false,

	-- Attach a real listener to OnTravel. Only meaningful with FireTravelEvents on.
	-- With it off you pay full marshal + dispatch and discard the result, which is
	-- not a shape any real game ships. Turn ON for a realistic reading.
	ConnectOnTravel  = false,

	-- Down-step casts beyond LODDistance from the LOD origin (1-in-3 frames).
	LOD              = false,

	-- Static occupancy grid: proves a segment is empty without raycasting.
	Occupancy        = false,

	-- Dynamic occupancy for moving parts. Consulted ALONGSIDE the static grid, so
	-- enable Occupancy too for a meaningful reading.
	DynamicOccupancy = false,

	-- Sub-stepped high-fidelity integration. Substantially more expensive per cast.
	HighFidelity     = false,

	-- 6DOF rigid-body attitude integration (orientation + angular velocity).
	SixDOF           = false,

	-- Spatial tier throttling (HOT/WARM/COLD by proximity to interest points).
	SpatialPartition = true,

	-- Aerodynamic drag, recalculated periodically. Opens new trajectory segments.
	Drag             = false,

	-- Homing. Adds a per-frame main-thread provider call per cast — this is what
	-- shows up as "homing/trajectory provider calls".
	Homing           = false,

	-- Bounce off geometry.
	Bounce           = false,

	-- Gate each bounce on a main-thread callback. The worker SUSPENDS the cast
	-- until the answer comes back, so this is true round-trip coupling.
	CanBounce        = false,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SCENE
-- ─────────────────────────────────────────────────────────────────────────────
local CAST_COUNT  = 20000
local SHARD_COUNT = 16
local SAMPLE_TIME = 20
local SPEED       = 600

local ORIGIN       = Vector3.new(0, 100, 0)
local LOD_ORIGIN   = Vector3.new(0, 0, 0)
local LOD_DISTANCE = 3000

local OCC_VOXEL_SIZE  = 4
local OCC_REGION_SIZE = Vector3.new(2000, 800, 2000)

local DYN_PART_COUNT = 50
local HOMING_TARGET  = Vector3.new(5000, 100, 0)

-- Sized against the Quadratic model so drag is a real force but doesn't kill the
-- bullet instantly: decel = DRAG_COEFFICIENT * Cd * SPEED^2. With Cd~0.3 from the
-- G-series table at Mach ~1.7, this gives roughly
--     2e-6 * 0.3 * 600^2  ~=  0.2 studs/s^2
-- i.e. gentle next to gravity (~196), so casts stay alive for the whole window and
-- keep paying the drag-recalc cost we're here to measure. Raise it to make drag
-- bite harder, but watch for early terminations swallowing the sample.
local DRAG_COEFFICIENT = 2e-6

-- ─────────────────────────────────────────────────────────────────────────────
-- SOLVER
-- ─────────────────────────────────────────────────────────────────────────────
local SolverConfig: any = { ShardCount = SHARD_COUNT }

if TOGGLES.SpatialPartition then
	SolverConfig.SpatialPartition = {
		Enabled        = true,
		CellSize       = 50,
		HotRadius      = 1,
		WarmRadius     = 3,
		UpdateInterval = 1,
		FallbackTier   = 4,   -- COLD: cells with no interest point step at 1/4 rate
	}
end
local Solver = Vetra.newParallel(SolverConfig)

if TOGGLES.LOD then
	Solver:SetLODOrigin(LOD_ORIGIN)
end

if TOGGLES.SpatialPartition then
	-- A single interest point at the spawn. Casts fly outward and leave the HOT
	-- region, so most end up COLD — that's the throttle being measured.
	Solver:SetInterestPoints({ ORIGIN })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- OCCUPANCY
-- ─────────────────────────────────────────────────────────────────────────────
local StaticGrid: any = nil
if TOGGLES.Occupancy then
	StaticGrid = Vetra.StaticOccupancy.new(OCC_VOXEL_SIZE)
	Vetra.VoxelBaker.BakeRegion(StaticGrid, CFrame.new(LOD_ORIGIN), OCC_REGION_SIZE, { Verbose = true })
end

local DynGrid: any = nil
if TOGGLES.DynamicOccupancy then
	if not TOGGLES.Occupancy then
		warn("[Benchmark] DynamicOccupancy is on but Occupancy is off. The dynamic grid is " ..
			"consulted alongside the static one — enable both for a meaningful reading.")
	end
	DynGrid = Vetra.DynamicOccupancy.new(OCC_VOXEL_SIZE)
	for Index = 1, DYN_PART_COUNT do
		local Part      = Instance.new("Part")
		Part.Anchored   = true
		Part.CanCollide = false
		Part.Size       = Vector3.new(20, 20, 20)
		Part.Position   = Vector3.new((Index % 10) * 200, 100, math.floor(Index / 10) * 200)
		Part.Parent     = workspace
		Vetra.DynamicOccupancy.Register(DynGrid, Part)
	end
	-- Dynamic occupancy tracks moving parts, so transforms must be refreshed each
	-- frame or every lookup reads stale positions.
	RunService.Heartbeat:Connect(function()
		Vetra.DynamicOccupancy.UpdateTransforms(DynGrid)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TRAVEL LISTENER
-- ─────────────────────────────────────────────────────────────────────────────
local TravelEventCount = 0
if TOGGLES.ConnectOnTravel then
	if not TOGGLES.FireTravelEvents then
		warn("[Benchmark] ConnectOnTravel is on but FireTravelEvents is off — no travel " ..
			"events will be emitted, so the listener will never fire.")
	end
	Solver:GetSignals().OnTravel:Connect(function()
		TravelEventCount += 1
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BEHAVIOR
-- ─────────────────────────────────────────────────────────────────────────────
local function makeBehavior(): any
	local Behavior: any = {
		MaxDistance             = 1e6,
		FireTravelEvents        = TOGGLES.FireTravelEvents,
		HighFidelitySegmentSize = TOGGLES.HighFidelity and 0.5 or 0,
		LODDistance             = TOGGLES.LOD and LOD_DISTANCE or 0,
		SixDOFEnabled           = TOGGLES.SixDOF,
		-- NOT a real-world Cd. The default DragModel is Quadratic, so this scales
		-- Speed^2 directly: deceleration = DragCoefficient * Cd * Speed^2. At
		-- SPEED=600 a "realistic-looking" 0.3 yields ~108,000 studs/s^2 (~550g) and
		-- the bullet stops dead in the first frame. Keep this tiny.
		DragCoefficient         = TOGGLES.Drag and DRAG_COEFFICIENT or 0,
	}

	if TOGGLES.Occupancy then
		Behavior.StaticOccupancy = StaticGrid
	end
	if TOGGLES.DynamicOccupancy then
		Behavior.DynamicOccupancy = DynGrid
	end

	if TOGGLES.Bounce then
		Behavior.MaxBounces           = 10
		Behavior.Restitution          = 0.6
		Behavior.BounceSpeedThreshold = 0
	else
		Behavior.MaxBounces = 0
	end

	if TOGGLES.CanBounce then
		Behavior.CanBounceFunction = function() return true end
	end

	if TOGGLES.Homing then
		Behavior.HomingStrength         = 0.5
		Behavior.HomingPositionProvider = function() return HOMING_TARGET end
	end

	return Behavior
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RUN
-- ─────────────────────────────────────────────────────────────────────────────
local function enabledList(): string
	local On = {}
	for Name, Value in TOGGLES do
		if Value then table.insert(On, Name) end
	end
	table.sort(On)
	return #On > 0 and table.concat(On, ", ") or "(none — baseline)"
end

print(string.rep("─", 68))
print("Vetra — feature benchmark")
print(string.rep("─", 68))
print(string.format("  casts   : %d across %d shards", CAST_COUNT, SHARD_COUNT))
print(string.format("  sample  : %ds", SAMPLE_TIME))
print(string.format("  enabled : %s", enabledList()))
print(string.rep("─", 68))

-- Parallel workers init asynchronously; firing too early drops casts silently
-- (known parallel startup race).
task.wait(5)

local Context = Vetra.BulletContext.new({
	Origin    = ORIGIN,
	Direction = Vector3.new(1, 0, 0),
	Speed     = SPEED,
})
local Behavior = makeBehavior()

for _ = 1, CAST_COUNT do
	Solver:Fire(Context, Behavior)
end
print("Vetra — Done firing")

if TOGGLES.ConnectOnTravel then
	print(string.rep("─", 68))
	print(string.format("  OnTravel listener fired %d times over %ds (~%.0f/frame at 60fps)",
		TravelEventCount, SAMPLE_TIME, TravelEventCount / (SAMPLE_TIME * 60)))
	print(string.rep("─", 68))
end
