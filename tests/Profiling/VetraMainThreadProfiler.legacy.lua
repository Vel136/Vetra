--!strict
-- VetraMainThreadProfiler.server.lua — where does parallel + FireTravelEvents
-- spend its frame? The worker profiler already showed the shards are ~idle
-- (raycasts fully collapsed by occupancy), so the frametime must live on the
-- MAIN thread: Coordinator:Step unpacking the event buffer and dispatching a
-- handler per cast per frame.
--
-- This drives the parallel solver and enables the MAIN-VM Profiler (distinct
-- from each Actor's own instance) so the coordinator's new phases show up:
--   coord_unpack   — ResultBuffer.UnpackEvent (alloc + field writes)
--   coord_dispatch — EventHandlers[...] (HandleTravel etc. + signal fire)
--   coord_cosmetic — workspace:BulkMoveTo
--   coord_flush    — FlushTravelBatch
--
-- Drop in ServerScriptService, edit the Vetra path, press Play.

local RunService = game:GetService("RunService")

local Vetra    = require(game.ReplicatedStorage:WaitForChild("src")) -- ← EDIT PATH
local Profiler = Vetra.Profiler
local BulletContext = Vetra.BulletContext

local BULLETS       = 5000
local WARMUP_FRAMES = 30
local SAMPLE_FRAMES = 120
local ORIGIN        = Vector3.new(0, 200, 0)
local SHARD_COUNT   = 16
local USE_BATCH_TRAVEL = true -- true: fire OnTravelBatch once/frame; false: OnTravel per cast

local function randomDir(): Vector3
	return Vector3.new(math.random() * 2 - 1, math.random() * 0.5, math.random() * 2 - 1).Unit
end

local Behavior = Vetra.BehaviorBuilder.new()
Behavior:Physics()
	:MaxDistance(1e9)
	:Done()

Behavior:HighFidelity():SegmentSize(0):Done()

Behavior:FireTravelEvents(true) -- the whole point: force every cast to sync
Behavior:BatchTravel(USE_BATCH_TRAVEL)
local behavior = Behavior:Build()

local solver = Vetra.newParallel({ ShardCount = SHARD_COUNT })
task.wait(0.1) -- let workers bind before firing

-- A no-op listener so dispatch actually runs (with batching off, FireOnTravel
-- early-outs unless OnTravel has a listener; with batching on, the work is the
-- per-event append plus a single OnTravelBatch fire per frame).
if USE_BATCH_TRAVEL then
	solver:GetSignals().OnTravelBatch:Connect(function() end)
else
	solver:GetSignals().OnTravel:Connect(function() end)
end

local function fire(n: number)
	for _ = 1, n do
		solver:Fire(BulletContext.new({
			Origin = ORIGIN, Direction = randomDir(), Speed = 200 + math.random() * 150,
		}), behavior)
	end
end

local function topUp()
	local n = #solver._ActiveCasts
	if n < BULLETS then fire(BULLETS - n) end
end

print(string.format("[MainThreadProfile] seeding %d bullets across %d shards…", BULLETS, SHARD_COUNT))
fire(BULLETS)
for _ = 1, WARMUP_FRAMES do topUp(); RunService.PreSimulation:Wait() end

print(string.format("[MainThreadProfile] sampling %d frames at ~%d active casts…",
	SAMPLE_FRAMES, #solver._ActiveCasts))

-- One call now enables BOTH the worker VMs (pack cost, via broadcast) and the main
-- VM (unpack/dispatch). Workers report on disable; the coordinator reports the main
-- thread on disable too.
solver._Coordinator:SetProfilerEnabled(true)

local wholeStep = 0
for _ = 1, SAMPLE_FRAMES do
	topUp()
	local t0 = os.clock()
	RunService.PreSimulation:Wait()
	wholeStep += (os.clock() - t0)
end

print(string.format("  whole PreSimulation frame avg: %.3f ms  (includes non-Vetra work)",
	wholeStep / SAMPLE_FRAMES * 1000))

solver._Coordinator:SetProfilerEnabled(false)
task.wait() -- let the worker disable messages land so they can print

solver:Destroy()
print("[MainThreadProfile] done")
