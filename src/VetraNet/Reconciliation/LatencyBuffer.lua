--!strict
--!optimize 2
--!native

local LatencyBuffer = {}

local Types = script.Parent.Parent.Types

local Players = game:GetService("Players")
local Player  = Players.LocalPlayer

local Constants = require(Types.Constants)

function LatencyBuffer.GetRTT(): number
	return Player:GetNetworkPing()
end

function LatencyBuffer.GetDelay(): number
	return LatencyBuffer.GetRTT() / Constants.RTT_HALF_DIVISOR
end

function LatencyBuffer.ShouldBuffer(ConfigOverride: number): boolean
	if ConfigOverride ~= 0 then
		return ConfigOverride > 0.001
	end
	return LatencyBuffer.GetDelay() > 0.001
end

return table.freeze(LatencyBuffer)
