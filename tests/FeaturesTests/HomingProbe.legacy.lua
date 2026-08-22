--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Serial homing disengage — probe, not a test
--
-- Round 1 established: homing runs (acquired, provider called 193x), but
-- HomingElapsed only reached 0.088 in 1.9s — roughly 22x too slow. So the expiry
-- check at Homing.lua:121 is never reachable within a bullet's lifetime, and the
-- accumulator at line 151 is where the truth is.
--
-- Reading the source hasn't settled WHY (sub-segment deltas sum correctly, the
-- call sites look right), so this round instruments the accumulator itself via
-- _G.__VETRA_HOMING_PROBE — a temporary hook in Homing.lua:151 — and reports the
-- actual Delta values being added.
--
-- WHAT THE OUTPUT MEANS
--   · avg Delta ≈ frame time (~0.016) and call count ≈ frame count
--        -> the accumulator is correct and the elapsed total should be right;
--           something else is resetting HomingElapsed.
--   · avg Delta ≈ frame time / N and call count ≈ frame count * N
--        -> sub-segments: each adds its slice, which SHOULD still sum to real time.
--           If the total still lags, slices are being dropped.
--   · avg Delta far below frame time with call count ≈ frame count
--        -> the Delta reaching StepHoming is not the frame delta at all.
--
-- REMEMBER: delete the _G hook in Homing.lua:151 when done.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 72)

local Scene = Instance.new("Folder")
Scene.Name   = "VetraHomingProbeScene"
Scene.Parent = workspace

local Params = RaycastParams.new()
Params.FilterType = Enum.RaycastFilterType.Include
Params.FilterDescendantsInstances = { Scene }

-- ── Accumulator hook ─────────────────────────────────────────────────────────
local Adds        = 0
local SubAdds     = 0
local DeltaSum    = 0
local DeltaMin    = math.huge
local DeltaMax    = 0
local ResetSeen   = 0
local LastElapsed = 0

_G.__VETRA_HOMING_PROBE = function(Delta: number, Elapsed: number, IsSubSegment: boolean)
	Adds     += 1
	DeltaSum += Delta
	if Delta < DeltaMin then DeltaMin = Delta end
	if Delta > DeltaMax then DeltaMax = Delta end
	if IsSubSegment then SubAdds += 1 end
	-- Elapsed going DOWN means something reset it behind our back.
	if Elapsed < LastElapsed then
		ResetSeen += 1
		print(string.format("  >>> HomingElapsed RESET: %.4f -> %.4f", LastElapsed, Elapsed))
	end
	LastElapsed = Elapsed
end

print("")
print(BAR)
print("  Serial homing accumulator probe  (HomingMaxDuration = 1.0)")
print(BAR)

local Solver = Vetra.new({})

local Disengaged = 0
Solver:GetSignals().OnHomingDisengaged:Connect(function()
	Disengaged += 1
	print(string.format("  >>> OnHomingDisengaged FIRED (count=%d)", Disengaged))
end)

local Target = Vector3.new(0, 4000, 500)
local Ctx = Vetra.BulletContext.new({
	Origin    = Vector3.new(-1200, 4000, 500),
	Direction = Vector3.new(0, 0, 1),
	Speed     = 300,
})

local Cast = Solver:Fire(Ctx, {
	MaxDistance            = 1e5,
	MinSpeed               = 0,
	Gravity                = Vector3.new(0, -0.001, 0),
	RaycastParams          = Params,
	MaxBounces             = 0,
	HomingMaxDuration      = 1.0,
	HomingPositionProvider = function() return Target end,
})

-- Count real frames over the same window, so call-count vs frame-count is
-- comparable.
local Frames = 0
local FrameConn = RunService.Heartbeat:Connect(function() Frames += 1 end)

local Start = os.clock()
task.wait(2.0)
local Wall = os.clock() - Start
FrameConn:Disconnect()

local R = Cast.Runtime
print("")
print(string.format("  wall clock          : %.3f s", Wall))
print(string.format("  frames elapsed      : %d  (avg frame %.4f s)", Frames, Wall / math.max(Frames, 1)))
print(string.format("  accumulator calls   : %d  (of which sub-segment: %d)", Adds, SubAdds))
print(string.format("  calls per frame     : %.2f", Adds / math.max(Frames, 1)))
print(string.format("  Delta added: avg=%.6f  min=%.6f  max=%.6f", DeltaSum / math.max(Adds, 1), DeltaMin, DeltaMax))
print(string.format("  sum of all Deltas   : %.4f   <- should track wall clock", DeltaSum))
print(string.format("  HomingElapsed final : %.4f   <- should equal the sum above", R.HomingElapsed))
print(string.format("  resets observed     : %d", ResetSeen))
print(string.format("  Disengaged=%s  SignalFired=%d", tostring(R.HomingDisengaged), Disengaged))
print(BAR)

if ResetSeen > 0 then
	print("  -> HomingElapsed is being RESET mid-flight. Find the writer:")
	print("     grep for 'HomingElapsed' assignments outside Homing.lua:151.")
elseif math.abs(DeltaSum - R.HomingElapsed) > 0.01 then
	print("  -> The accumulator's own sum doesn't match the stored Elapsed, so the")
	print("     field is being overwritten (not just added to) somewhere else.")
elseif DeltaSum < Wall * 0.5 then
	print(string.format("  -> Deltas sum to %.3f over %.3f s of wall clock. The Delta reaching", DeltaSum, Wall))
	print("     StepHoming is NOT real frame time — trace what SimulateCast passes in.")
else
	print("  -> Accumulator looks correct. If Elapsed still never hits the duration,")
	print("     the cast isn't living long enough — re-check the test's flight time.")
end
print("")

Solver:Destroy()
Scene:Destroy()
_G.__VETRA_HOMING_PROBE = nil
