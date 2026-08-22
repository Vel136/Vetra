--!strict
-- ProfileStep.server.lua — per-phase breakdown of the projectile cast-step.
-- Drop in ServerScriptService, edit the Vetra path, press Play.
--
-- Answers "where does the ~16ms floor go?" by timing each phase of
-- SimulateCast.StepProjectile: dragRecalc / kinematics / occupancy / raycast /
-- signals. Runs a fixed heavy bullet load with keep-alive so the count is stable.

local RunService = game:GetService("RunService")

local Vetra    = require(game.ReplicatedStorage:WaitForChild("src")) -- ← EDIT PATH
local Profiler = Vetra.Profiler
local BulletContext = Vetra.BulletContext

-- ── Config ────────────────────────────────────────────────────────────────────
local BULLETS       = 3000
local WARMUP_FRAMES = 30
local SAMPLE_FRAMES = 120
local ORIGIN        = Vector3.new(0, 200, 0)

-- Wrap raycast so raycast time is captured under the "raycast" phase (the probe
-- already brackets CastFunction; this just makes the call real + counted).
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude

local behavior = {
	MaxDistance             = 4000,
	MinSpeed                = 1,
	BounceSpeedThreshold    = 9999,
	MaxBounces              = 0,
	Gravity                 = Vector3.new(0, -50, 0),
	RaycastParams           = rp,
	HighFidelitySegmentSize = 0, -- profile the base per-frame step, not HF substeps
}

local function randomDir(): Vector3
	return Vector3.new(
		math.random() * 2 - 1,
		math.random() * 0.5,
		math.random() * 2 - 1
	).Unit
end

local solver = Vetra.new()

local function fire(n: number)
	for _ = 1, n do
		solver:Fire(BulletContext.new({
			Origin = ORIGIN, Direction = randomDir(), Speed = 200 + math.random() * 150,
		}), behavior)
	end
end

-- Keep the active count near BULLETS for the whole sample.
solver:GetSignals().OnTerminated:Connect(function()
	task.defer(function()
		if #solver._ActiveCasts < BULLETS then fire(1) end
	end)
end)

print(string.format("[ProfileStep] seeding %d bullets…", BULLETS))
fire(BULLETS)

for _ = 1, WARMUP_FRAMES do RunService.PreSimulation:Wait() end
local deficit = BULLETS - #solver._ActiveCasts
if deficit > 0 then fire(deficit) end

print(string.format("[ProfileStep] sampling %d frames at ~%d active casts…",
	SAMPLE_FRAMES, #solver._ActiveCasts))

-- Also measure whole-step wall time so we can compare "sum of phases" to the
-- true step cost (the difference = unmeasured hit logic + loop overhead).
local wholeStep = 0
Profiler.Reset()
Profiler.Enabled = true
for _ = 1, SAMPLE_FRAMES do
	local t0 = os.clock()
	RunService.PreSimulation:Wait()
	wholeStep += (os.clock() - t0)
end
Profiler.Enabled = false

print(string.format("  whole PreSimulation frame avg: %.3f ms  (includes non-Vetra work)",
	wholeStep / SAMPLE_FRAMES * 1000))
Profiler.Report()

solver:Destroy()
print("[ProfileStep] done")
