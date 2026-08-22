--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — DYNAMIC OCCUPANCY A/B benchmark
--
-- Two arms, same scene, interleaved:
--     OFF  — no occupancy of any kind. Every step raycasts.
--     DYN  — DynamicOccupancy attached. A registered-part voxel test decides
--            whether the raycast runs at all.
--
-- HOW TO RUN — this is a ModuleScript returning a function, NOT a drop-in Script:
--
--     require(ServerScriptService.Tests.Profiling.DynOccBenchmark)()
--
--   ScriptProfilerService is PluginSecurity. A plain Script in ServerScriptService
--   CANNOT connect OnNewData — it throws "lacking capability Plugin". Run this
--   through a plugin-capability context (the Studio MCP execute_luau bridge, or a
--   real plugin). If the connect fails the run degrades to wall-clock only rather
--   than dying, but you lose the attribution that makes this worth running.
--
-- WHY THE SCENE LOOKS LIKE THIS
--   DynamicOccupancy is NOT a world grid — it only knows about parts passed to
--   Register(). A cast flying through empty space gets no benefit from it, it just
--   pays the lookup. So the obstacle field is the ONLY geometry, it is fully
--   registered, and casts are aimed through it.
--
--   Density is tuned so roughly HALF of segments get collapsed. Both extremes are
--   useless: ~0% skip means DYN pays lookup cost with no savings, and ~100% skip
--   means the casts are missing the field entirely and you are measuring "skip
--   everything" vs "raycast everything" — a best case no real scene reaches. The
--   run prints SkipRatio per arm and warns outside 15–85%; believe the warning.
--
--   The parts MOVE (that's the "dynamic" being tested), driven by ONE
--   benchmark-wide connection so the field never freezes between arms.
--
-- READING IT HONESTLY
--   · Arms are interleaved OFF/DYN/OFF/DYN over ROUNDS and reported as MEDIANS.
--     A single sequential pass puts all warmup and drift on whichever arm ran
--     second; at these frame times that was worth a few ms of fake delta.
--   · The profiler inflates what it measures. Compare arms to each other, never to
--     an unprofiled frametime.
--   · Absolute ms in the ranked dump are attribution, not a budget — parallel
--     worker time sums across shards and nested frames double-count. Rank only.
--   · SegmentClear legitimately appears TWICE in the dump (main-VM and worker-side
--     copies are distinct functions). Add them for the true cost.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local SPS               = game:GetService("ScriptProfilerService")

local Vetra = require(ReplicatedStorage.src)

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────────────────────────────────────
-- Defaults. Every one of these is overridable per call — see the Options note on
-- the returned function. The matrix (serial/parallel x HF off/on) is three calls,
-- not three edits.
local PARALLEL      = true
local HF_SIZE       = 0        -- HighFidelitySegmentSize; 0 = HF off
local CAST_COUNT    = 4000
local SHARD_COUNT   = 16
local SAMPLE_FRAMES = 120
local WARMUP_FRAMES = 30
local ROUNDS        = 3        -- OFF/DYN pairs; medians reported
local SPEED         = 500
local PROFILER_HZ   = 1000

local ORIGIN     = Vector3.new(0, 100, 0)
local VOXEL_SIZE = 4
local SCENE_SEED = 20260719

-- Obstacle field: a moving slab of parts straddling the flight path. Tuned for a
-- ~40–60% skip ratio — see the density note in the header before changing these.
local OBSTACLE_COUNT = 700
local OBSTACLE_SIZE  = Vector3.new(24, 24, 24)
local FIELD_START_X  = 250     -- first obstacle plane, studs downrange
local FIELD_DEPTH    = 1400    -- obstacles spread over this much X
local FIELD_SPREAD   = 90      -- +/- Y and Z scatter; tight enough that casts meet it
local ORBIT_RADIUS   = 20      -- how far each part drifts per cycle
local ORBIT_SPEED    = 1.5

-- Cone half-angle for fired casts. Must stay tight enough that casts actually
-- reach the obstacle field — see the density note in the header.
local SPREAD = 0.05

-- Default DragModel is Quadratic (decel = Cd * Speed^2). At SPEED=500 anything
-- "realistic" stops the bullet in frame 1. Keep tiny. (See Benchmark.legacy.lua.)
local DRAG_COEFFICIENT = 2e-6

-- ─────────────────────────────────────────────────────────────────────────────
-- SCENE
-- ─────────────────────────────────────────────────────────────────────────────
-- Built per run, not at module scope: the runner destroys the scene when it
-- finishes, so a module-scope scene would leave a second call firing at dead parts.
local Scene: Folder
local Obstacles: { BasePart } = {}
local Homes: { Vector3 } = {}

local function buildScene()
	Scene = Instance.new("Folder")
	Scene.Name   = "DynOccScene"
	Scene.Parent = workspace

	table.clear(Obstacles)
	table.clear(Homes)

	-- Seeded, not math.random(): every arm and every round must fly through the
	-- SAME field. A fresh scatter would make the arms different benchmarks.
	local Rng = Random.new(SCENE_SEED)

	for Index = 1, OBSTACLE_COUNT do
		local Part      = Instance.new("Part")
		Part.Anchored   = true
		Part.CanCollide = false
		Part.Size       = OBSTACLE_SIZE
		Part.Position   = Vector3.new(
			FIELD_START_X + (Index / OBSTACLE_COUNT) * FIELD_DEPTH,
			ORIGIN.Y + Rng:NextNumber(-1, 1) * FIELD_SPREAD,
			Rng:NextNumber(-1, 1) * FIELD_SPREAD
		)
		Part.Parent = Scene
		Obstacles[Index] = Part
		Homes[Index]     = Part.Position
	end

	task.wait()
end

-- Drives the obstacle field. Wired ONCE for the whole benchmark rather than per
-- arm, so the field keeps moving continuously — through warmup, through both arms,
-- and through the gap between them. A field that freezes between arms lets the
-- dynamic grid settle onto stale-but-correct transforms, which is exactly the case
-- dynamic occupancy is supposed to be stressed on.
local function animate(Clock: number)
	for Index, Part in ipairs(Obstacles) do
		local Phase = Clock * ORBIT_SPEED + Index
		Part.Position = Homes[Index] + Vector3.new(
			0,
			math.sin(Phase) * ORBIT_RADIUS,
			math.cos(Phase) * ORBIT_RADIUS
		)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PROFILER
--
-- ServerRequestData() does NOT return the payload — it requests it, and the JSON
-- arrives on OnNewData. See the capability note in the header.
-- ─────────────────────────────────────────────────────────────────────────────
local Capture: { string } = {}
local ProfilerAvailable = pcall(function()
	SPS.OnNewData:Connect(function(_, Json)
		table.insert(Capture, Json)
	end)
end)

if not ProfilerAvailable then
	warn("[DynOccBenchmark] ScriptProfilerService unavailable (needs Plugin capability) — " ..
		"wall-clock only. Run via execute_luau / a plugin for the ranked dump.")
end

local function profiled(Fn: () -> (number, number)): (string?, number, number)
	if not ProfilerAvailable then
		local Wall, Worst = Fn()
		return nil, Wall, Worst
	end
	table.clear(Capture)
	SPS:ServerStart(PROFILER_HZ)
	local Wall, Worst = Fn()
	SPS:ServerRequestData()
	local Deadline = os.clock()
	while #Capture == 0 and os.clock() - Deadline < 2 do task.wait() end
	SPS:ServerStop()
	return Capture[1], Wall, Worst
end

type Row = { Name: string, Src: string, Line: number, Dur: number }

local function parse(Json: string?): ({ Row }, number)
	if not Json then return {}, 0 end
	local Data  = HttpService:JSONDecode(Json)
	local Rows: { Row } = {}
	local Total = 0
	for _, Fn in ipairs(Data.Functions) do
		local Source   = Fn.Source or ""
		local Duration = Fn.TotalDuration or 0
		Total += Duration
		if string.find(Source, "src", 1, true) or string.find(Source, "Vetra", 1, true) then
			table.insert(Rows, {
				Name = Fn.Name or "?", Src = Source,
				Line = Fn.Line or 0,   Dur = Duration,
			})
		end
	end
	table.sort(Rows, function(A, B) return A.Dur > B.Dur end)
	return Rows, Total
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ONE ARM
-- ─────────────────────────────────────────────────────────────────────────────
type Result = {
	Label: string, Wall: number, Worst: number, Active: number,
	Rows: { Row }, Total: number, SkipRatio: number,
}

local function runArm(Label: string, UseDynamic: boolean): Result
	local Solver = PARALLEL
		and Vetra.new({ ShardCount = SHARD_COUNT })
		or  Vetra.new()

	-- Parallel workers init asynchronously; firing too early drops casts silently.
	if PARALLEL then task.wait(5) end

	-- The field is animated by a benchmark-wide connection (see the runner), so
	-- nothing here starts or stops the motion. This arm only owns the grid refresh.
	local DynGrid: any = nil
	local RefreshConn: RBXScriptConnection? = nil

	if UseDynamic then
		DynGrid = Vetra.DynamicOccupancy.new(VOXEL_SIZE)
		local Registered = 0
		for _, Part in ipairs(Obstacles) do
			if Vetra.DynamicOccupancy.Register(DynGrid, Part) then
				Registered += 1
			end
		end
		if Registered == 0 then
			warn("[DynOccBenchmark] no obstacles registered — parts are smaller than the " ..
				"minimum voxel count. Raise OBSTACLE_SIZE or lower VOXEL_SIZE.")
		end
		-- Dynamic occupancy reads cached transforms; without this refresh every
		-- lookup tests stale positions and the moving field is a lie.
		RefreshConn = RunService.Heartbeat:Connect(function()
			Vetra.DynamicOccupancy.UpdateTransforms(DynGrid)
		end)
	end

	local Behavior: any = {
		MaxDistance             = 1e6,
		FireTravelEvents        = false,
		HighFidelitySegmentSize = HF_SIZE,
		MaxBounces              = 0,
		DragCoefficient         = DRAG_COEFFICIENT,
	}
	if UseDynamic then
		Behavior.DynamicOccupancy = DynGrid
	end

	local function direction(): Vector3
		return Vector3.new(
			1,
			(math.random() * 2 - 1) * SPREAD,
			(math.random() * 2 - 1) * SPREAD
		).Unit
	end

	local function fire(Count: number)
		for _ = 1, Count do
			Solver:Fire(Vetra.BulletContext.new({
				Origin    = ORIGIN,
				Direction = direction(),
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

	local Json, Wall, Worst = profiled(function(): (number, number)
		local W, Peak = 0, 0
		for _ = 1, SAMPLE_FRAMES do
			topUp()
			local T0 = os.clock()
			RunService.PreSimulation:Wait()
			local Frame = os.clock() - T0
			W += Frame
			if Frame > Peak then Peak = Frame end
		end
		return W, Peak
	end)

	-- Sanity signal: how often did the grid actually collapse a raycast? Sampled
	-- from the live cast set against the same grid the sim used. See the density
	-- note in the header — both 0% and 100% mean the comparison is meaningless.
	local SkipRatio = 0
	if UseDynamic then
		local Sampled, Clear = 0, 0
		-- Accessors, not raw fields: on the parallel path live state lives worker-side
		-- and Cast.Position / Cast.Velocity read nil. Get* pulls the mirrored value.
		for _, Cast in ipairs(Solver._ActiveCasts) do
			local Pos = Cast:GetPosition()
			local Vel = Cast:GetVelocity()
			if Pos and Vel then
				Sampled += 1
				if Vetra.DynamicOccupancy.SegmentClear(DynGrid, Pos, Vel * (1 / 60)) then
					Clear += 1
				end
			end
			if Sampled >= 500 then break end
		end
		SkipRatio = Sampled > 0 and (Clear / Sampled) or 0
	end

	local Rows, Total = parse(Json)

	if RefreshConn then RefreshConn:Disconnect() end
	Solver:Destroy()
	task.wait(0.5)

	return {
		Label = Label, Wall = Wall, Worst = Worst, Active = Active,
		Rows = Rows, Total = Total, SkipRatio = SkipRatio,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- REPORT
-- ─────────────────────────────────────────────────────────────────────────────
local function median(Values: { number }): number
	local Sorted = table.clone(Values)
	table.sort(Sorted)
	local N = #Sorted
	if N == 0 then return 0 end
	if N % 2 == 1 then return Sorted[(N + 1) // 2] end
	return (Sorted[N // 2] + Sorted[N // 2 + 1]) / 2
end

local function dump(R: Result)
	print(string.rep("─", 76))
	print(string.format("  ARM: %s   (representative round)", R.Label))
	print(string.format("  frames=%d   activeCasts=%d   wall/frame=%.3f ms   worst=%.3f ms",
		SAMPLE_FRAMES, R.Active, R.Wall / SAMPLE_FRAMES * 1000, R.Worst * 1000))
	if #R.Rows == 0 then
		print("  (no profiler attribution — wall-clock only)")
		return
	end
	print(string.format("  profiler total=%.1f ms across %d Vetra fns  ← rank only, not a budget",
		R.Total / 1000, #R.Rows))
	print(string.rep("─", 76))
	print(string.format("  %-30s %-26s %9s %7s", "FUNCTION", "SOURCE:LINE", "ms", "%"))
	print("  " .. string.rep("-", 72))
	for Index = 1, math.min(15, #R.Rows) do
		local Row   = R.Rows[Index]
		local Short = string.match(Row.Src, "([^%.]+%.[^%.]+)$") or Row.Src
		print(string.format("  %-30s %-26s %9.2f %6.1f%%",
			string.sub(Row.Name, 1, 30),
			string.sub(Short .. ":" .. Row.Line, 1, 26),
			Row.Dur / 1000,
			R.Total > 0 and (Row.Dur / R.Total * 100) or 0))
	end
end

-- Exported as a function, not run at require time: the profiler needs Plugin
-- capability, so the useful invocation is `require(...)()` from execute_luau.
--
-- Options override the CONFIG constants for this call only, so the serial/parallel
-- x HF matrix is three calls rather than three edits between runs:
--
--     Run({ Parallel = false })                 -- serial, HF off
--     Run({ Parallel = true, HfSize = 4 })      -- parallel, HF on
--
-- Recognised: Parallel, HfSize, CastCount, ShardCount, SampleFrames, Rounds.
--
-- Overrides are applied against the ORIGINAL defaults every call, not against
-- whatever the previous call left behind. Running the matrix back-to-back in one
-- session would otherwise leak round N's settings into round N+1 — the second call
-- silently inheriting the first's HfSize is exactly the kind of thing that makes a
-- benchmark lie about which config it measured.
local DEFAULTS = {
	Parallel     = PARALLEL,
	HfSize       = HF_SIZE,
	CastCount    = CAST_COUNT,
	ShardCount   = SHARD_COUNT,
	SampleFrames = SAMPLE_FRAMES,
	Rounds       = ROUNDS,
}

return function(Options: { [string]: any }?)

local Opt = Options or {}
local function pick(Key: string): any
	local Value = Opt[Key]
	if Value == nil then return DEFAULTS[Key] end
	return Value
end

PARALLEL      = pick("Parallel")
HF_SIZE       = pick("HfSize")
CAST_COUNT    = pick("CastCount")
SHARD_COUNT   = pick("ShardCount")
SAMPLE_FRAMES = pick("SampleFrames")
ROUNDS        = pick("Rounds")

print(string.rep("═", 76))
print("Vetra — dynamic occupancy A/B")
print(string.format("  path    : %s", PARALLEL and ("parallel, " .. SHARD_COUNT .. " shards") or "serial"))
print(string.format("  casts   : %d   sample: %d frames (%d warmup)  rounds: %d",
	CAST_COUNT, SAMPLE_FRAMES, WARMUP_FRAMES, ROUNDS))
print(string.format("  scene   : %d moving obstacles, voxel=%d", OBSTACLE_COUNT, VOXEL_SIZE))
print(string.format("  fidelity: %s", HF_SIZE > 0 and ("HF on, segment=" .. HF_SIZE) or "HF off"))
print(string.format("  profiler: %s", ProfilerAvailable and "on" or "UNAVAILABLE (wall-clock only)"))
print(string.rep("═", 76))

buildScene()

-- One connection for the whole benchmark: the field never stops moving, including
-- between arms and between rounds.
local AnimConn = RunService.Heartbeat:Connect(function()
	animate(os.clock())
end)

local OffWall, DynWall = {}, {}
local OffWorst, DynWorst = {}, {}
local Skips = {}
local LastOff: Result, LastDyn: Result

-- Interleaved, not sequential: warmup and drift would otherwise land entirely on
-- whichever arm always ran second.
for Round = 1, ROUNDS do
	print(string.format("  … round %d/%d", Round, ROUNDS))

	local Off = runArm("OCCUPANCY OFF", false)
	table.insert(OffWall, Off.Wall / SAMPLE_FRAMES * 1000)
	table.insert(OffWorst, Off.Worst * 1000)
	LastOff = Off

	local Dyn = runArm("DYNAMIC OCCUPANCY", true)
	table.insert(DynWall, Dyn.Wall / SAMPLE_FRAMES * 1000)
	table.insert(DynWorst, Dyn.Worst * 1000)
	table.insert(Skips, Dyn.SkipRatio)
	LastDyn = Dyn
end

dump(LastOff)
dump(LastDyn)

local OffMs   = median(OffWall)
local DynMs   = median(DynWall)
local SkipMed = median(Skips)

print(string.rep("═", 76))
print(string.format("  medians over %d rounds", ROUNDS))
print(string.format("  OFF  wall/frame : %.3f ms   (worst %.3f ms)", OffMs, median(OffWorst)))
print(string.format("  DYN  wall/frame : %.3f ms   (worst %.3f ms)", DynMs, median(DynWorst)))
print(string.format("  delta           : %+.3f ms  (%+.1f%%)",
	DynMs - OffMs, OffMs > 0 and ((DynMs - OffMs) / OffMs * 100) or 0))
print(string.format("  DYN skip ratio  : %.1f%% of sampled segments collapsed", SkipMed * 100))

if SkipMed < 0.15 then
	warn("[DynOccBenchmark] skip ratio is very low — DYN is paying lookup cost with almost " ..
		"no savings. Densify the field or tighten SPREAD before reading the delta.")
elseif SkipMed > 0.85 then
	warn("[DynOccBenchmark] skip ratio is near-total — the casts are barely meeting the " ..
		"obstacle field, so this measures 'skip everything' vs 'raycast everything', a best " ..
		"case no real scene reaches. Widen FIELD_SPREAD or lower OBSTACLE_COUNT.")
end
print(string.rep("═", 76))

AnimConn:Disconnect()
Scene:Destroy()
print("Vetra — done")

return {
	Parallel = PARALLEL, HfSize = HF_SIZE,
	OffMs = OffMs, DynMs = DynMs, SkipRatio = SkipMed,
	OffWall = OffWall, DynWall = DynWall,
}

end
