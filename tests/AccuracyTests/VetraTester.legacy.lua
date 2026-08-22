
local Vetra = require(game.ReplicatedStorage.src)

local Solver = Vetra.newParallel()
Solver:GetSignals().OnPreTermination:Connect(function(bullet, reason, mutate)
	print((bullet.Position - bullet.Origin).Magnitude)
end)
task.wait(1)

for i = 1, 10 do
	local ctx = Vetra.BulletContext.new({
		Origin = workspace.Start.Position,
		Direction = workspace.End.Position - workspace.Start.Position,
		Speed = 150,
	})

	local c = Solver:Fire(ctx,{
		MaxDistance             = 4000,
		MinSpeed                = 1,
		BounceSpeedThreshold    = 9999,
		MaxBounces              = 0,
		Gravity                 = Vector3.new(0, -50, 0),
		CanBounceFunction		= function()
			return false
		end,
		MaxDisplacement			= 10,
		HighFidelitySegmentSize = 0,
		HighFidelityFrameBudget = 4,
		OccupancyGrid           = useGrid and grid or nil,
	})
end
