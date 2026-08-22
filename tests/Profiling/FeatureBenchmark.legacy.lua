--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — stackable feature benchmark, full feature surface (PARALLEL path)
--
-- Same idea as Benchmark.legacy.lua: flip toggles, run, compare. This one covers
-- the features that file left out — Coriolis, Wind, Magnus, Tumble, Pierce,
-- Suspend, BatchTravel, CosmeticBullets — and reports via ScriptProfilerService
-- instead of the built-in Profiler, so main-thread and worker time land in one
-- ranked list.
--
-- HOW TO USE
--   1. Flip flags in TOGGLES.
--   2. Run. Read the ranked dump in Output.
--   3. Change ONE flag. Run again. Compare.
--
-- WHAT TO READ IN THE DUMP
--   · wall/frame is the number that matters. Everything else is attribution.
--   · Percentages are trustworthy; absolute ms are NOT a frame budget. Parallel
--     worker time sums across all shards and nested frames double-count in the
--     flat view, so the total runs several times wall-clock. Rank, don't budget.
--   · VetraShard_N rows are per-worker. They're concurrent with each other, so a
--     shard row growing while wall/frame holds steady is fine.
--
-- READING IT HONESTLY
--   · The profiler costs time per cast and inflates what it measures. Compare
--     runs against each other, never against an unprofiled frametime.
--   · Only compare runs with the same SAMPLE_FRAMES and CAST_COUNT — a shorter
--     window samples an earlier part of the flight, which shifts LOD/occupancy
--     ratios and makes two runs incomparable.
--   · Features interact. Stacking A+B is not cost(A)+cost(B); measure the stack
--     you actually ship.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local SPS               = game:GetService("ScriptProfilerService")

local Vetra = require(ReplicatedStorage.src)

-- ─────────────────────────────────────────────────────────────────────────────
-- TOGGLES — flip these
-- ─────────────────────────────────────────────────────────────────────────────
local TOGGLES = {
	-- ── sync path ────────────────────────────────────────────────────────────
	-- Emit OnTravel every frame: puts every cast on the sync path. Usually the
	-- single most expensive flag on the main thread.
	FireTravelEvents = false,
	-- Attach a real listener. Only meaningful with FireTravelEvents on; without a
	-- listener you pay marshal + dispatch and discard it, which no real game ships.
	ConnectOnTravel  = false,
	-- Coalesce per-cast OnTravel into one OnTravelBatch per frame. Trades N signal
	-- fires for 1 + N appends. Only meaningful with FireTravelEvents on.
	BatchTravel      = false,

	-- ── throttles (these should REDUCE cost) ─────────────────────────────────
	LOD              = false,
	Occupancy        = true,
	DynamicOccupancy = false,
	SpatialPartition = true,

	-- ── integration ──────────────────────────────────────────────────────────
	HighFidelity     = false,
	SixDOF           = true,
	Drag             = true,

	-- ── forces ───────────────────────────────────────────────────────────────
	-- Solver-level rotating-frame deflection. Cheap per cast, but always-on.
	Coriolis         = false,
	-- Solver-level wind. Folded into acceleration at Fire, so ~free per frame.
	Wind             = false,
	-- Spin-induced lateral force. Needs SpinVector AND MagnusCoefficient.
	Magnus           = false,

	-- ── interactions ─────────────────────────────────────────────────────────
	Bounce           = false,
	-- Gates each bounce on a main-thread callback: the worker SUSPENDS the cast
	-- until the answer returns. True round-trip coupling — expensive.
	CanBounce        = false,
	Pierce           = false,
	-- Gates each pierce on a main-thread callback. Same round-trip as CanBounce.
	CanPierce        = false,
	-- Yaw instability below a speed threshold. Rides on SixDOF — enable both.
	Tumble           = false,
	Homing           = false,

	-- ── cosmetics ────────────────────────────────────────────────────────────
	-- Clone a part per cast and BulkMoveTo it each frame. At CAST_COUNT parts this
	-- is a real main-thread cost and a real instance count.
	CosmeticBullets  = false,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SCENE
-- ─────────────────────────────────────────────────────────────────────────────
local CAST_COUNT    = 5000
local SHARD_COUNT   = 16
local SAMPLE_FRAMES = 120
local WARMUP_FRAMES = 30
local SPEED         = 600
local PROFILER_HZ   = 1000

local ORIGIN       = Vector3.new(0, 100, 0)
local LOD_ORIGIN   = Vector3.new(0, 0, 0)
local LOD_DISTANCE = 3000

local OCC_VOXEL_SIZE  = 4
local OCC_REGION_SIZE = Vector3.new(2000, 800, 2000)

local DYN_PART_COUNT = 50
local HOMING_TARGET  = Vector3.new(5000, 100, 0)

-- See Benchmark.legacy.lua: the default DragModel is Quadratic, so this scales
-- Speed^2 directly (decel = DragCoefficient * Cd * Speed^2). At SPEED=600 a
-- "realistic" 0.3 yields ~550g and the bullet stops dead in frame 1. Keep tiny.
local DRAG_COEFFICIENT = 2e-6

-- Rotating-frame deflection. 45° latitude, scale 1 = Earth rate.
local CORIOLIS_LATITUDE = 45
local CORIOLIS_SCALE    = 1

local WIND_VECTOR = Vector3.new(30, 0, 0)

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

local Solver = Vetra.new(SolverConfig)

if TOGGLES.LOD then
	Solver:SetLODOrigin(LOD_ORIGIN)
end

if TOGGLES.SpatialPartition then
	-- One interest point at the spawn. Casts fly outward and leave the HOT region,
	-- so most end up COLD — that's the throttle being measured.
	Solver:SetInterestPoints({ ORIGIN })
end

if TOGGLES.Coriolis then
	Solver:SetCoriolisConfig(CORIOLIS_LATITUDE, CORIOLIS_SCALE)
end

if TOGGLES.Wind then
	Solver:SetWind(WIND_VECTOR)
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
		warn("[FeatureBenchmark] DynamicOccupancy is on but Occupancy is off. The dynamic " ..
			"grid is consulted alongside the static one — enable both for a meaningful reading.")
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
-- COSMETIC TEMPLATE
-- ─────────────────────────────────────────────────────────────────────────────
local CosmeticTemplate: any = nil
local CosmeticContainer: any = nil
if TOGGLES.CosmeticBullets then
	CosmeticTemplate            = Instance.new("Part")
	CosmeticTemplate.Size       = Vector3.new(0.2, 0.2, 1)
	CosmeticTemplate.Anchored   = true
	CosmeticTemplate.CanCollide = false
	CosmeticTemplate.CanQuery   = false
	CosmeticTemplate.CanTouch   = false

	CosmeticContainer        = Instance.new("Folder")
	CosmeticContainer.Name   = "CosmeticBullets"
	CosmeticContainer.Parent = workspace
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TRAVEL LISTENER
-- ─────────────────────────────────────────────────────────────────────────────
local TravelEventCount = 0
if TOGGLES.ConnectOnTravel then
	if not TOGGLES.FireTravelEvents then
		warn("[FeatureBenchmark] ConnectOnTravel is on but FireTravelEvents is off — no " ..
			"travel events will be emitted, so the listener will never fire.")
	end
	if TOGGLES.BatchTravel then
		Solver:GetSignals().OnTravelBatch:Connect(function(Batch)
			TravelEventCount += #Batch
		end)
	else
		Solver:GetSignals().OnTravel:Connect(function()
			TravelEventCount += 1
		end)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BEHAVIOR
-- ─────────────────────────────────────────────────────────────────────────────
local function makeBehavior(): any
	local Behavior: any = {
		MaxDistance             = 1e6,
		FireTravelEvents        = TOGGLES.FireTravelEvents,
		BatchTravel             = TOGGLES.BatchTravel,
		HighFidelitySegmentSize = TOGGLES.HighFidelity and 0.5 or 0,
		LODDistance             = TOGGLES.LOD and LOD_DISTANCE or 0,
		SixDOFEnabled           = TOGGLES.SixDOF,
		-- NOT a real-world Cd — see DRAG_COEFFICIENT above.
		DragCoefficient         = TOGGLES.Drag and DRAG_COEFFICIENT or 0,
	}

	if TOGGLES.Occupancy then
		Behavior.StaticOccupancy = StaticGrid
	end
	if TOGGLES.DynamicOccupancy then
		Behavior.DynamicOccupancy = DynGrid
	end

	-- Magnus needs spin to act on: coefficient alone does nothing.
	if TOGGLES.Magnus then
		Behavior.SpinVector       = Vector3.new(0, 0, 250)
		Behavior.MagnusCoefficient = 0.02
		Behavior.SpinDecayRate     = 0.1
	end

	if TOGGLES.Bounce then
		Behavior.MaxBounces           = 10
		Behavior.Restitution          = 0.6
		Behavior.BounceSpeedThreshold = 0
	else
		Behavior.MaxBounces = 0
	end

	if TOGGLES.CanBounce then
		if not TOGGLES.Bounce then
			warn("[FeatureBenchmark] CanBounce is on but Bounce is off (MaxBounces=0) — the " ..
				"gate will never be consulted.")
		end
		Behavior.CanBounceFunction = function() return true end
	end

	if TOGGLES.Pierce then
		Behavior.MaxPierceCount      = 5
		Behavior.PierceSpeedThreshold = 0
		Behavior.PierceSpeedRetention = 0.8
	end

	if TOGGLES.CanPierce then
		if not TOGGLES.Pierce then
			warn("[FeatureBenchmark] CanPierce is on but Pierce is off — the gate will never " ..
				"be consulted.")
		end
		Behavior.CanPierceFunction = function() return true end
	end

	-- Tumble is a 6DOF attitude behavior; without SixDOF there's no attitude to
	-- destabilise.
	if TOGGLES.Tumble then
		if not TOGGLES.SixDOF then
			warn("[FeatureBenchmark] Tumble is on but SixDOF is off — tumbling rides on the " ..
				"6DOF attitude integrator and will not engage.")
		end
		Behavior.TumbleSpeedThreshold  = SPEED * 0.5
		Behavior.TumbleDragMultiplier  = 3.0
		Behavior.TumbleLateralStrength = 0.5
		Behavior.TumbleRecoverySpeed   = SPEED * 0.8
	end

	if TOGGLES.Homing then
		Behavior.HomingStrength         = 0.5
		Behavior.HomingPositionProvider = function() return HOMING_TARGET end
	end

	if TOGGLES.CosmeticBullets then
		Behavior.CosmeticBulletTemplate  = CosmeticTemplate
		Behavior.CosmeticBulletContainer = CosmeticContainer
	end

	return Behavior
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PROFILER
--
-- ServerRequestData() does NOT return the payload — it requests it, and the JSON
-- arrives on OnNewData. Everything is PluginSecurity per the docs but resolves
-- fine from this context.
-- ─────────────────────────────────────────────────────────────────────────────
local Capture: { string } = {}
SPS.OnNewData:Connect(function(_, Json)
	table.insert(Capture, Json)
end)

local function profiled(Fn: () -> number): (string?, number)
	table.clear(Capture)
	SPS:ServerStart(PROFILER_HZ)
	local Wall = Fn()
	SPS:ServerRequestData()
	local Deadline = os.clock()
	while #Capture == 0 and os.clock() - Deadline < 2 do task.wait() end
	SPS:ServerStop()
	return Capture[1], Wall
end

local function report(Json: string?, Wall: number, ActiveCasts: number)
	if not Json then
		warn("[FeatureBenchmark] no profiler data returned")
		return
	end

	local Data  = HttpService:JSONDecode(Json)
	local Rows  = {}
	local Total = 0

	for _, Fn in ipairs(Data.Functions) do
		local Source   = Fn.Source or ""
		local Duration = Fn.TotalDuration or 0
		Total += Duration
		if string.find(Source, "src", 1, true) or string.find(Source, "Vetra", 1, true) then
			table.insert(Rows, {
				Name = Fn.Name or "?",
				Src  = Source,
				Line = Fn.Line or 0,
				Dur  = Duration,
			})
		end
	end
	table.sort(Rows, function(A, B) return A.Dur > B.Dur end)

	print(string.rep("─", 76))
	print(string.format("  frames=%d   activeCasts=%d   wall/frame=%.3f ms",
		SAMPLE_FRAMES, ActiveCasts, Wall / SAMPLE_FRAMES * 1000))
	print(string.format("  profiler total=%.1f ms across %d fns (%d Vetra)  ← rank only, not a budget",
		Total / 1000, #Data.Functions, #Rows))
	print(string.rep("─", 76))
	print(string.format("  %-30s %-26s %9s %7s", "FUNCTION", "SOURCE:LINE", "ms", "%"))
	print("  " .. string.rep("-", 72))
	for Index = 1, math.min(20, #Rows) do
		local Row   = Rows[Index]
		local Short = string.match(Row.Src, "([^%.]+%.[^%.]+)$") or Row.Src
		print(string.format("  %-30s %-26s %9.2f %6.1f%%",
			string.sub(Row.Name, 1, 30),
			string.sub(Short .. ":" .. Row.Line, 1, 26),
			Row.Dur / 1000,
			Total > 0 and (Row.Dur / Total * 100) or 0))
	end
	print(string.rep("─", 76))
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

print(string.rep("─", 76))
print("Vetra — feature benchmark (full surface)")
print(string.rep("─", 76))
print(string.format("  casts   : %d across %d shards", CAST_COUNT, SHARD_COUNT))
print(string.format("  sample  : %d frames (%d warmup)", SAMPLE_FRAMES, WARMUP_FRAMES))
print(string.format("  enabled : %s", enabledList()))
print(string.rep("─", 76))

-- Parallel workers init asynchronously; firing too early drops casts silently
-- (known parallel startup race).
task.wait(5)

local Context = Vetra.BulletContext.new({
	Origin    = ORIGIN,
	Direction = Vector3.new(1, 0, 0),
	Speed     = SPEED,
})
local Behavior = makeBehavior()

local function fire(Count: number)
	for _ = 1, Count do
		Solver:Fire(Vetra.BulletContext.new({
			Origin    = ORIGIN,
			Direction = Vector3.new(1, 0, 0),
			Speed     = SPEED,
		}), Behavior)
	end
end

-- Hold the population steady so every sampled frame does comparable work.
local function topUp()
	local Live = #Solver._ActiveCasts
	if Live < CAST_COUNT then fire(CAST_COUNT - Live) end
end

fire(CAST_COUNT)
for _ = 1, WARMUP_FRAMES do topUp(); RunService.PreSimulation:Wait() end

local Active = #Solver._ActiveCasts
local Json, Wall = profiled(function()
	local W = 0
	for _ = 1, SAMPLE_FRAMES do
		topUp()
		local T0 = os.clock()
		RunService.PreSimulation:Wait()
		W += (os.clock() - T0)
	end
	return W
end)

report(Json, Wall, Active)

if TOGGLES.ConnectOnTravel then
	print(string.format("  OnTravel listener fired %d times over %d frames (~%.0f/frame)",
		TravelEventCount, SAMPLE_FRAMES, TravelEventCount / SAMPLE_FRAMES))
	print(string.rep("─", 76))
end

Solver:Destroy()
print("Vetra — done")
