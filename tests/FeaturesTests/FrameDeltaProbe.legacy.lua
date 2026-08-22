--!strict
-- Diagnostic: WHERE does the 2.24s first-Step FrameDelta come from?
-- Logs every Heartbeat delta with a wall timestamp from the moment we connect,
-- and marks the lifecycle points (connect / after newParallel / after wait / fire)
-- so we can see exactly which frame carries the giant delta and what it lines up with.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local T0 = os.clock()
local function stamp(): string
	return string.format("%.4f", os.clock() - T0)
end

-- Raw Heartbeat probe, connected BEFORE the solver so we see the baseline cadence
-- through the whole startup window (its own delta is independent of the solver's).
local frame = 0
local conn: RBXScriptConnection
conn = RunService.Heartbeat:Connect(function(dt: number)
	frame += 1
	-- Only print notable frames: the first few, and any hitch (> 0.05s).
	if frame <= 3 or dt > 0.05 then
		print(string.format("[HB] wall=%s  frame=%d  dt=%.4f%s",
			stamp(), frame, dt, dt > 0.05 and "   <== HITCH" or ""))
	end
end)

print(string.format("[MARK] wall=%s  Heartbeat connected", stamp()))

local Solver = Vetra.newParallel()
print(string.format("[MARK] wall=%s  newParallel() returned", stamp()))

task.wait(1)
print(string.format("[MARK] wall=%s  task.wait(1) returned", stamp()))

local ctx = Vetra.BulletContext.new({
	Origin    = Vector3.new(0, 500, 0),
	Direction = Vector3.new(1, 0, 0),
	Speed     = 200,
})
Solver:Fire(ctx, {
	Gravity = Vector3.new(0, -0.0001, 0),
	DragCoefficient = 0, MaxDistance = 1e6, MinSpeed = 0,
	MaxBounces = 0, BounceSpeedThreshold = 1e9, HighFidelitySegmentSize = 0,
})
print(string.format("[MARK] wall=%s  Fire() returned", stamp()))

task.wait(0.5)
print(string.format("[MARK] wall=%s  done", stamp()))

conn:Disconnect()
Solver:Destroy()
