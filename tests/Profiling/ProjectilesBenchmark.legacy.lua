--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║        VETRA  v4  vs  FastCast2  v0.0.9  — Pure-Time Benchmark      ║
    ║                                                                      ║
    ║  WHY MIN-OF-N:                                                       ║
    ║    Roblox Luau only exposes collectgarbage("count") — GC cannot     ║
    ║    be stopped or forced.  GC pauses only ADD time to a sample,      ║
    ║    never remove it.  The MINIMUM across many repeated runs is       ║
    ║    therefore the sample least likely to contain a GC pause —        ║
    ║    it IS the pure solver cost.                                       ║
    ║                                                                      ║
    ║  SETUP: place as ServerScript. Siblings required:                   ║
    ║    • Vetra      (ModuleScript)                                       ║
    ║    • FastCast2  (ModuleScript)                                       ║
    ╚══════════════════════════════════════════════════════════════════════╝
]]

local RunService = game:GetService("RunService")

local Vetra         = require(game.ReplicatedStorage.src)
local FastCast2     = require(script.Parent.FastCast2)
local BulletContext = require(game.ReplicatedStorage.src.Core.BulletContext)

local StaticOccupancy = Vetra.StaticOccupancy
local VoxelBaker      = Vetra.VoxelBaker

local CFG = {
	ParallelWorkers  = 16,
	BulletTiers      = { 20000 },
	Repetitions      = 1,
	StepSampleFrames = 60,
	BulletSpeed      = 300,
	-- Finite so bullets die on their own after a bounded flight. This lets each
	-- tier drain to zero active casts before the next one fires, so a tier's
	-- frame samples measure ONLY that tier's load — no carry-over from earlier,
	-- longer-lived bullets. ~1200 studs spans the occupancy region and dies in
	-- ~4s at speed 300: still under load while sampling, gone shortly after.
	BulletMaxDist    = 999_999,
	WarmupCount      = 50,
	DrainTimeout     = 8,        -- max seconds to wait for casts to clear per tier

	-- Static-occupancy voxel grid. Vetra marches this grid before raycasting,
	-- skipping the ray entirely for empty space. FastCast2 has no equivalent,
	-- so it always ray-tests — the grid is what the comparison is measuring.
	UseOccupancy     = true,
	OccVoxelSize     = 4,        -- studs per voxel
	OccPartCount     = 400,      -- obstacles baked into the scene
	OccRegionSize    = Vector3.new(2000, 800, 2000),
}

-- ─── Utilities ────────────────────────────────────────────────────────────────

local function printf(fmt, ...) print(string.format(fmt, ...)) end
local function ruler(c, w) print(string.rep(c or "─", w or 72)) end

local function tMin(t)
	local m = math.huge
	for _, v in t do if v < m then m = v end end
	return m
end

local function meanSd(t)
	local sum = 0
	for _, v in t do sum += v end
	local mean = sum / #t
	local var  = 0
	for _, v in t do var += (v - mean)^2 end
	return mean, math.sqrt(var / #t)
end

local function sampleFrames(n)
	local samples  = table.create(n)
	local captured = 0
	local conn
	conn = RunService.PreSimulation:Connect(function(dt)
		captured += 1
		samples[captured] = dt * 1_000
		if captured >= n then conn:Disconnect() end
	end)
	while captured < n do RunService.PreSimulation:Wait() end
	return samples
end

local function frameMean(samples)
	local s = 0
	for _, v in samples do s += v end
	return s / #samples
end

-- ─── Occupancy scene + grid ─────────────────────────────────────────────────

local ORIGIN = Vector3.new(0, 5, 0)

-- Obstacle scene the occupancy grid is baked from. The parts are EXCLUDED from
-- both solvers' raycasts so they never terminate a bullet early — bullets fly
-- the full distance in every pass, and the only difference the grid makes is
-- whether Vetra can skip rays over the empty voxels between obstacles.
local occScene: Folder? = nil
local occGrid: any = nil

if CFG.UseOccupancy then
	print("  Baking occupancy scene...")
	occScene = Instance.new("Folder")
	occScene.Name = "ProjBench_OccScene"
	occScene.Parent = workspace
	for _ = 1, CFG.OccPartCount do
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = Vector3.new(math.random(8, 40), math.random(8, 40), math.random(8, 40))
		p.CFrame = CFrame.new(math.random(-400, 400), math.random(0, 120), math.random(-400, 400))
		p.Parent = occScene
	end
	task.wait()

	occGrid = StaticOccupancy.new(CFG.OccVoxelSize)
	VoxelBaker.BakeRegion(occGrid, CFrame.new(ORIGIN), CFG.OccRegionSize, { Verbose = true })
	print("  Occupancy grid baked.\n")
end

-- ─── Shared params ────────────────────────────────────────────────────────────

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType                 = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.FilterDescendantsInstances = if occScene then { occScene } else {}

local DIRECTIONS = {}
do
	local count = 360
	for i = 1, count do
		local theta = (i / count) * math.pi * 2
		local phi   = math.pi / 4
		DIRECTIONS[i] = Vector3.new(
			math.cos(theta) * math.cos(phi),
			math.sin(phi),
			math.sin(theta) * math.cos(phi)
		)
	end
end

local function getDir(i) return DIRECTIONS[((i - 1) % #DIRECTIONS) + 1] end

-- ─── Build solvers ONCE ───────────────────────────────────────────────────────

print("\n  Building solvers (once)...")

-- Vetra
local vetraSolver = Vetra.newParallel({ShardCount = 16})

-- FastCast2
local fcCaster   = FastCast2.new()
local vmFolder   = Instance.new("Folder")
vmFolder.Name    = "FC2_VMs"
vmFolder.Parent  = workspace
local conFolder  = Instance.new("Folder")
conFolder.Name   = "FC2_Containers"
conFolder.Parent = workspace

fcCaster:Init(
	CFG.ParallelWorkers,
	vmFolder,  "FastCastVMs",
	conFolder, "Containers", "Worker",
	false, nil, false, nil, nil, nil
)

print("  Waiting for workers to spin up...")
task.wait(2)
print("  Solvers ready.\n")

-- ─── Behaviors (defined once) ─────────────────────────────────────────────────

local VETRA_BEHAVIOR = {
	MaxDistance             = CFG.BulletMaxDist,
	RaycastParams           = RAYCAST_PARAMS,
	HighFidelitySegmentSize = 0,
	StaticOccupancy         = occGrid,   
}

local FC_BEHAVIOR = FastCast2.newBehavior()
FC_BEHAVIOR.Acceleration  = Vector3.new(0, -workspace.Gravity, 0)
FC_BEHAVIOR.MaxDistance   = CFG.BulletMaxDist
FC_BEHAVIOR.RaycastParams = RAYCAST_PARAMS
FC_BEHAVIOR.FastCastEventsConfig = {
	UseLengthChanged = false, UseHit = false,
	UsePierced = false, UseCastTerminating = false, UseCastFire = false,
}
FC_BEHAVIOR.FastCastEventsModuleConfig = {
	UseLengthChanged = false, UseHit = false, UsePierced = false,
	UseCastTerminating = false, UseCanPierce = false, UseCastFire = false,
}

-- ─── Fire helpers ─────────────────────────────────────────────────────────────
local function vetraFire(count)

	for i = 1, count do
		vetraSolver:Fire(
			BulletContext.new({ Origin = ORIGIN, Direction = getDir(i), Speed = CFG.BulletSpeed }),
			VETRA_BEHAVIOR
		)
	end

end

local function fcFire(count)
	for i = 1, count do
		local dir = getDir(i)
		fcCaster:RaycastFire(ORIGIN, dir, dir * CFG.BulletSpeed, FC_BEHAVIOR)
	end
end

-- ─── Warmup ───────────────────────────────────────────────────────────────────

print("  Warmup...")
vetraFire(CFG.WarmupCount)
fcFire(CFG.WarmupCount)
task.wait(1)
print("  Warmup done.\n")

-- ─── Drain ────────────────────────────────────────────────────────────────────

-- Wait for every in-flight bullet to die before the next tier fires, so each
-- tier's frame samples measure only its own load. Vetra exposes its live count
-- via _ActiveCasts; FastCast2 has no public counter but its casts die on the
-- same finite MaxDistance, so once Vetra is empty FC2 has drained too. The
-- timeout guards against a stray cast that never terminates.
-- Vetra: poll the real live count until it hits zero (bounded by DrainTimeout).
local function drainVetra(solver)
	local deadline = os.clock() + CFG.DrainTimeout
	while os.clock() < deadline do
		local active = solver._ActiveCasts
		if not active or #active == 0 then return end
		RunService.PreSimulation:Wait()
	end
	local left = solver._ActiveCasts and #solver._ActiveCasts or 0
	if left > 0 then
		printf("    [drain] Vetra timeout with %d casts still active", left)
	end
end

-- FastCast2: no live-count API, so wait out the worst-case flight time —
-- MaxDistance / Speed plus a margin — by which point every FC2 bullet has
-- exceeded its distance budget and self-terminated.
local FC_DRAIN_SECONDS = math.min(CFG.DrainTimeout, CFG.BulletMaxDist / CFG.BulletSpeed + 1)
local function drainFastCast()
	task.wait(FC_DRAIN_SECONDS)
end

-- ─── Tier runner ──────────────────────────────────────────────────────────────

type TierResult = { tier: number, minFireMicros: number, minFrameMs: number }

local function runTier(label, count, fireFn): TierResult
	local allFire  = {}
	local allFrame = {}

	for rep = 1, CFG.Repetitions do
		local t0 = os.clock()
		fireFn(count)
		local t1 = os.clock()

		local fireUs = ((t1 - t0) / count) * 1_000_000
		table.insert(allFire, fireUs)

		local fm = frameMean(sampleFrames(CFG.StepSampleFrames))
		table.insert(allFrame, fm)

		printf("    [%s] rep %d/%d  fire=%.2f μs/b  frame=%.3f ms",
			label, rep, CFG.Repetitions, fireUs, fm)
	end

	local fireMn, fireSd   = meanSd(allFire)
	local frameMn, frameSd = meanSd(allFrame)
	local minFire          = tMin(allFire)
	local minFrame         = tMin(allFrame)

	printf("    [%s] ── SUMMARY  minFire=%.2f μs/b (mean %.2f ±%.2f)  minFrame=%.3f ms (mean %.3f ±%.3f)",
		label, minFire, fireMn, fireSd, minFrame, frameMn, frameSd)

	return { tier = count, minFireMicros = minFire, minFrameMs = minFrame }
end

-- ─── Run tiers ────────────────────────────────────────────────────────────────

local vetraResults = {}
local fcResults    = {}

--print("\n  [Phase 2]  FastCast2")
--ruler("-")
--for _, tier in CFG.BulletTiers do
--	printf("  Tier %d...", tier)
--	table.insert(fcResults, runTier("FC2", tier, fcFire))
--	task.wait(0.3)
--end

print("  [Phase 1]  Vetra")
ruler("-")
for _, tier in CFG.BulletTiers do
	printf("  Tier %d...", tier)
	table.insert(vetraResults, runTier("Vetra", tier, vetraFire))
end

-- ─── Output ───────────────────────────────────────────────────────────────────

local function printTable(label, results)
	ruler("═")
	printf("  %s", label)
	ruler("─")
	printf("%-10s  %-18s  %-18s", "Bullets", "Min Fire μs/b", "Min Frame ms")
	ruler("-", 50)
	for _, r in results do
		printf("%-10d  %-18.2f  %-18.3f", r.tier, r.minFireMicros, r.minFrameMs)
	end
	ruler("─")
end

local function printComparison(vRes, fRes)
	ruler("═")
	printf("  HEAD-TO-HEAD  (min-of-%d, lower = better)", CFG.Repetitions)
	ruler("─")
	printf("%-10s  %-28s  %-28s  %-12s",
		"Bullets", "Fire μs/b  Vetra / FC2", "Frame ms   Vetra / FC2", "Winner")
	ruler("-", 82)
	for i, vr in vRes do
		local fr = fRes[i]
		if not fr then continue end
		local frameWin = if vr.minFrameMs    < fr.minFrameMs    then "Vetra" else "FC2"
		local fireWin  = if vr.minFireMicros < fr.minFireMicros then "Vetra" else "FC2"
		printf("%-10d  %8.2f / %-17.2f  %8.3f / %-16.3f  frame:%-6s fire:%s",
			vr.tier,
			vr.minFireMicros, fr.minFireMicros,
			vr.minFrameMs,    fr.minFrameMs,
			frameWin, fireWin
		)
	end
	ruler("═")
end

printTable("Vetra  (" .. CFG.ParallelWorkers .. " shards, solvers created once)", vetraResults)
printTable("FastCast2  (" .. CFG.ParallelWorkers .. " workers, solvers created once)", fcResults)
printComparison(vetraResults, fcResults)

print("\n  LEGEND")
print("  Min Fire μs/b : min μs per Fire() call  ← pure solver dispatch cost")
print("  Min Frame ms  : min mean PreSimulation dt    ← pure step cost")
print("  Solvers created ONCE and reused across all tiers — no setup bias.")
if CFG.UseOccupancy then
	printf("  Occupancy: %d-stud voxel grid over %d obstacles (Vetra only; FC2 ray-tests every step).",
		CFG.OccVoxelSize, CFG.OccPartCount)
end
ruler("═")
