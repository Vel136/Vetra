--!strict
-- ProfileHFOccupancy.server.lua — does occupancy help HIGH-FIDELITY parallel?
-- Compares GRID OFF vs ON, serial and parallel, with HF ON.
-- Phase breakdown via Simulation.Profiler: serial passes drive the main-VM
-- module directly; parallel passes broadcast to the worker VMs through
-- Coordinator:SetProfilerEnabled (each Actor has its OWN Profiler instance).

local RunService = game:GetService("RunService")

local Vetra    = require(game.ReplicatedStorage:WaitForChild("src")) -- ← EDIT PATH
local Profiler = require(game.ReplicatedStorage.src.Simulation.Profiler)
local BulletContext  = Vetra.BulletContext
local OccupancyGrid  = Vetra.StaticOccupancy
local VoxelBaker     = Vetra.VoxelBaker

local BULLETS       = 1500
local WARMUP_FRAMES = 20
local SAMPLE_FRAMES = 90
local ORIGIN        = Vector3.new(0, 50, 0)

local scene = Instance.new("Folder")
scene.Name = "HFOccScene"
scene.Parent = workspace
for _ = 1, 400 do
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = Vector3.new(math.random(8, 40), math.random(8, 40), math.random(8, 40))
	p.CFrame = CFrame.new(math.random(-400, 400), math.random(0, 120), math.random(-400, 400))
	p.Parent = scene
end
task.wait()

local grid = OccupancyGrid.new(4)
VoxelBaker.BakeRegion(grid, CFrame.new(ORIGIN), Vector3.new(2000, 800, 2000), { Verbose = true })

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude

local function randomDir(): Vector3
	return Vector3.new(math.random() * 2 - 1, math.random() * 0.5, math.random() * 2 - 1).Unit
end

local function baseBehavior(useGrid: boolean)
	
	local Behavior = Vetra.BehaviorBuilder.new()
	
	Behavior:Physics()
		:MaxDistance(950)
		:Gravity(Vector3.new(0, -9.80665, 0))
		:Done()
	
	Behavior:Drag():Model(Vetra.Enums.DragModel.G7):Done()
	
	Behavior:StaticOccupancy(useGrid and grid or nil)

	Behavior:FireTravelEvents(false)
	
	return Behavior:Build()
end

local function runPass(label: string, useGrid: boolean, makeSolver: () -> any)
	local solver   = makeSolver()
	local behavior = baseBehavior(useGrid)
	local isParallel = solver._Coordinator ~= nil

	local function fire(n: number)
		for _ = 1, n do
			solver:Fire(BulletContext.new({
				Origin = ORIGIN, Direction = randomDir(), Speed = 400 + math.random() * 200,
			}), behavior)
		end
	end
	local function topUp()
		local n = #solver._ActiveCasts
		if n < BULLETS then fire(BULLETS - n) end
	end

	fire(BULLETS)
	for _ = 1, WARMUP_FRAMES do topUp(); RunService.PreSimulation:Wait() end

	-- Enable profiling only for the sample window. For parallel this must happen
	-- AFTER warmup: workers are provably bound by now (they're stepping casts),
	-- so the SetProfiler message cannot race worker startup and be dropped.
	if isParallel then
		solver._Coordinator:SetProfilerEnabled(true)
	else
		Profiler.Reset()
		Profiler.Enabled = true
	end

	local wholeStep = 0
	for _ = 1, SAMPLE_FRAMES do
		topUp()
		local t0 = os.clock()
		RunService.PreSimulation:Wait()
		wholeStep += (os.clock() - t0)
	end

	-- Stop and report BEFORE Destroy — a destroyed worker can't print. The
	-- disable travels as an actor message, so give it a frame to land.
	if isParallel then
		solver._Coordinator:SetProfilerEnabled(false)
		task.wait()
	else
		Profiler.Enabled = false
		Profiler.Report(("Vetra Serial [%s]"):format(label))
	end

	print(string.format("  [%s] active=%d  whole-frame avg=%.3f ms",
		label, #solver._ActiveCasts, wholeStep / SAMPLE_FRAMES * 1000))

	solver:Destroy()
	task.wait(0.5)
end

local function makeSerial()   return Vetra.new() end
local function makeParallel() 
	local vet = Vetra.newParallel({ ShardCount = 8 })
	task.wait(.1)
	return vet
end

print("═══ HF SERIAL ═══")
runPass("GRID OFF", false, makeSerial)
runPass("GRID ON",  true,  makeSerial)

print("═══ HF PARALLEL ═══")
runPass("GRID OFF", false, makeParallel)
runPass("GRID ON",  true,  makeParallel)

scene:Destroy()
print("[ProfileHFOccupancy] done")
