--!strict
--LatencyBuffer.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Reconciliation/LatencyBuffer.lua
    Delays cosmetic bullet spawn by an estimated half-RTT.

    The goal is temporal alignment: the server bullet and the cosmetic bullet
    should arrive at their target at approximately the same time. Without a
    delay, the cosmetic bullet spawns immediately on the client at the moment
    the replicated fire event arrives. By that point the server bullet has
    already been flying for one full RTT / 2 — the cosmetic starts one RTT / 2
    behind and never closes the gap.

    By delaying the cosmetic spawn by half-RTT, both bullets start their journey
    at approximately the same "real" time and arrive at their target together.
    This produces visually accurate hit markers and bullet trails.

    CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity      = "LatencyBuffer"

local LatencyBuffer = {}
LatencyBuffer.__type = Identity

local LatencyBufferMetatable = table.freeze({
	__index = LatencyBuffer,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core  = script.Parent.Parent.Core
local Types = script.Parent.Parent.Types

local Players = game:GetService("Players")

local Player  = Players.LocalPlayer
-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local Constants  = require(Types.Constants)
local LogService = require(Core.Logger)

Authority.AssertClient("LatencyBuffer")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Returns the current estimated round-trip time in seconds.
-- Players.LocalPlayer:GetNetworkPing() returns RTT directly in seconds,
-- so no unit conversion is needed.
function LatencyBuffer.GetRTT(): number
	return Player:GetNetworkPing()
end

-- Returns the estimated one-way (server→client) delay in seconds.
-- Halving RTT is an approximation assuming symmetric paths — asymmetric
-- connections are common in practice but the error is typically < 20 ms,
-- which is imperceptible for bullet visual alignment purposes.
function LatencyBuffer.GetDelay(): number
	return LatencyBuffer.GetRTT() / Constants.RTT_HALF_DIVISOR
end

-- Returns false when LatencyBuffer should be skipped entirely.
-- If the consumer configured LatencyBuffer = 0 in NetworkConfig, or if the
-- delay would be negligible (< 1 ms), skipping the delay avoids unnecessary
-- task.delay calls.
function LatencyBuffer.ShouldBuffer(ConfigOverride: number): boolean
	if ConfigOverride ~= 0 then
		-- Consumer explicitly set a delay — always honour it.
		return ConfigOverride > 0.001
	end
	return LatencyBuffer.GetDelay() > 0.001
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(LatencyBuffer, {
	__index = function(_, Key)
		Logger:Warn(string_format("LatencyBuffer: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("LatencyBuffer: write to protected key '%s'", tostring(Key)))
	end,
}))