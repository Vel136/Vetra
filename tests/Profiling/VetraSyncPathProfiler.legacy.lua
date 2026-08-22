--!strict
-- VetraSyncPathProfiler.server.lua — isolates the cross-VM SYNC paths specifically,
-- as opposed to VetraMainThreadProfiler which only exercises the TravelLite fast
-- path (FireTravelEvents with no bounce/homing/provider/hit traffic).
--
-- This drives four cast populations, each forcing a different sync mechanism:
--   group A: plain FireTravelEvents            → TravelLite buffer path (baseline)
--   group B: HomingPositionProvider             → per-cast SendMessage("UpdateHoming") every frame
--   group C: TrajectoryPositionProvider          → per-cast SendMessage("UpdateProviderPositions"),
--                                                   3 pcalls/frame (last/current/+epsilon)
--   group D: bounce off a floor plane            → real Hit/Bounce events, worker-side
--                                                   task.synchronize() + HitInstanceEvent
--
-- Each group is profiled in isolation (one solver per group, same total cast count)
-- so the report attributes cost correctly instead of averaging distinct sync paths
-- together. Compare "main: event handler dispatch" and per-worker "write results to
-- state" / sync-only phases across groups to see the *marginal* cost of each path
-- over the group-A baseline.
--
-- Drop in ServerScriptService, edit the Vetra path, press Play.

local RunService    = game:GetService("RunService")
local Workspace     = game:GetService("Workspace")

local Vetra         = require(game.ReplicatedStorage:WaitForChild("src")) -- ← EDIT PATH
local BulletContext  = Vetra.BulletContext

local BULLETS        = 1000
local WARMUP_FRAMES  = 30
local SAMPLE_FRAMES  = 120
local ORIGIN         = Vector3.new(0, 200, 0)
local SHARD_COUNT    = 8
local SEED           = 90210

local function makeRandom(): Random
	return Random.new(SEED)
end

local function randomDir(rng: Random): Vector3
	return Vector3.new(rng:NextNumber() * 2 - 1, rng:NextNumber() * 0.5, rng:NextNumber() * 2 - 1).Unit
end

-- Shared floor plane for the bounce group. Placed well below the sample window so
-- casts have time to travel, hit, and bounce repeatedly within SAMPLE_FRAMES.
local Floor = Instance.new("Part")
Floor.Name = "VetraSyncProfilerFloor"
Floor.Anchored = true
Floor.Size = Vector3.new(4000, 4, 4000)
Floor.CFrame = CFrame.new(0, 0, 0)
Floor.Parent = Workspace

local function runGroup(label: string, buildBehavior: () -> any)
	local rng = makeRandom()
	local behavior = buildBehavior()
	local solver = Vetra.newParallel({ ShardCount = SHARD_COUNT })
	task.wait(0.1) -- let workers bind before firing

	solver:GetSignals().OnTravelBatch:Connect(function() end)
	solver:GetSignals().OnHit:Connect(function() end)
	solver:GetSignals().OnBounce:Connect(function() end)

	local function fire(n: number)
		for _ = 1, n do
			solver:Fire(BulletContext.new({
				Origin = ORIGIN, Direction = randomDir(rng), Speed = 200 + rng:NextNumber() * 150,
			}), behavior)
		end
	end

	local function topUp()
		local n = #solver._ActiveCasts
		if n < BULLETS then fire(BULLETS - n) end
	end

	print(string.format("[SyncPathProfile] %s: seeding %d bullets across %d shards…", label, BULLETS, SHARD_COUNT))
	fire(BULLETS)
	for _ = 1, WARMUP_FRAMES do topUp(); RunService.PreSimulation:Wait() end

	print(string.format("[SyncPathProfile] %s: sampling %d frames at ~%d active casts…",
		label, SAMPLE_FRAMES, #solver._ActiveCasts))

	solver._Coordinator:SetProfilerEnabled(true)

	local wholeStep = 0
	for _ = 1, SAMPLE_FRAMES do
		topUp()
		local t0 = os.clock()
		RunService.PreSimulation:Wait()
		wholeStep += (os.clock() - t0)
	end

	print(string.format("  [%s] whole PreSimulation frame avg: %.3f ms  (includes non-Vetra work)",
		label, wholeStep / SAMPLE_FRAMES * 1000))

	solver._Coordinator:SetProfilerEnabled(false)
	task.wait() -- let the worker disable messages land so they can print

	solver:Destroy()
	print(string.format("[SyncPathProfile] %s: done", label))
end

-- Group A: baseline — TravelLite only, no homing/provider/bounce.
runGroup("A_TravelLiteBaseline", function()
	local b = Vetra.BehaviorBuilder.new()
	b:Physics():MaxDistance(1e9):Done()
	b:HighFidelity():SegmentSize(0):Done()
	b:FireTravelEvents(true)
	b:BatchTravel(true)
	return b:Build()
end)

-- Group B: homing — forces per-cast SendMessage("UpdateHoming") every frame.
runGroup("B_HomingProvider", function()
	local b = Vetra.BehaviorBuilder.new()
	b:Physics():MaxDistance(1e9):Done()
	b:HighFidelity():SegmentSize(0):Done()
	b:FireTravelEvents(true)
	b:BatchTravel(true)
	b:Homing()
		:PositionProvider(function(_currentPos: Vector3, _currentVel: Vector3)
			return Vector3.new(500, 200, 500) -- fixed target; cost is in the round trip, not the math
		end)
		:Strength(2)
		:MaxDuration(1e9)
		:Done()
	return b:Build()
end)

-- Group C: trajectory provider — forces per-cast SendMessage("UpdateProviderPositions"),
-- with 3 provider pcalls/frame on the main thread (last/current/+epsilon for velocity).
runGroup("C_TrajectoryProvider", function()
	local b = Vetra.BehaviorBuilder.new()
	b:Physics():MaxDistance(1e9):Done()
	b:HighFidelity():SegmentSize(0):Done()
	b:FireTravelEvents(true)
	b:BatchTravel(true)
	b:Trajectory()
		:Provider(function(t: number)
			return ORIGIN + Vector3.new(math.sin(t) * 50, 0, math.cos(t) * 50)
		end)
		:Done()
	return b:Build()
end)

-- Group D: bounce off a floor — forces real Hit/Bounce events, i.e. the worker-side
-- task.synchronize() + HitInstanceEvent path (the only true synchronize call in the
-- whole pipeline), not just SharedTable/buffer traffic.
runGroup("D_BounceFloor", function()
	local b = Vetra.BehaviorBuilder.new()
	b:Physics():MaxDistance(1e9):Done()
	b:HighFidelity():SegmentSize(0):Done()
	b:FireTravelEvents(true)
	b:BatchTravel(true)
	b:Bounce()
		:Max(1e9)
		:SpeedThreshold(0)
		:Restitution(0.9)
		:Done()
	return b:Build()
end)

Floor:Destroy()
print("[SyncPathProfile] all groups done")
