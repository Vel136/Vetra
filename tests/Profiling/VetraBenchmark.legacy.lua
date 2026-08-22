local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Benchmarker       = require(script.Benchmarker)

local Bench = Benchmarker.new()

Bench:RunOccupancyRealistic(2000)
