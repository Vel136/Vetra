--!strict
-- Diagnostic: is the parallel main-thread runtime clock advancing too fast?
-- Prints TotalRuntime vs wall-clock each 0.1s. ratio should be ≈ 1.0.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local Solver = Vetra.newParallel()
task.wait(1)

local ctx = Vetra.BulletContext.new({
	Origin    = Vector3.new(0, 500, 0),
	Direction = Vector3.new(1, 0, 0),
	Speed     = 200,
})
local Cast = Solver:Fire(ctx, {
	Gravity                 = Vector3.new(0, -0.0001, 0), -- nonzero so it's honored
	DragCoefficient         = 0,
	MaxDistance             = 1e6,
	MinSpeed                = 0,
	MaxBounces              = 0,
	BounceSpeedThreshold    = 1e9,
	HighFidelitySegmentSize = 0,
})

local t0  = os.clock()
local rt0 = Cast.Runtime.TotalRuntime
print(string.format("start: wall=0.000  TotalRuntime=%.4f", rt0))
for _ = 1, 5 do
	task.wait(0.1)
	local wall = os.clock() - t0
	local rt   = Cast.Runtime.TotalRuntime
	local traj = Cast.Runtime.ActiveTrajectory
	print(string.format(
		"t=%.3f  TotalRuntime=%.4f  ratio=%.2f  #Trajectories=%d  segStart=%.4f",
		wall, rt, rt / wall, #Cast.Runtime.Trajectories, traj.StartTime))
end
Cast:Terminate()
Solver:Destroy()
