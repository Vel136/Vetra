--!strict
--RateLimiter.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Authority/RateLimiter.lua
    Per-player fire rate enforcement using a token bucket algorithm.

    Why token bucket instead of a hard per-second counter?
    A hard counter (e.g. "max 10 fires per second") feels punitive for
    legitimate rapid-fire patterns like auto-shotguns or burst rifles. If the
    player fires 9 shots in the first 100 ms, they are locked out for the
    remaining 900 ms even though their average rate is well within the limit.
    Token buckets allow short bursts up to BurstLimit while still enforcing
    the sustainable average rate via TokensPerSecond refill. A player who
    fires a full burst must wait for tokens to regenerate before firing again
    — this matches how real weapon mechanics feel.

    Each player has their own token count stored in _Tokens.
    Refill() is called once per frame by the init.lua frame loop and
    distributes regenerated tokens to all tracked players simultaneously.
    Never call Refill() per-request — that would over-refill players who fire
    frequently and under-refill those who fire rarely.
]]

local Identity    = "RateLimiter"

local RateLimiter = {}
RateLimiter.__type = Identity

local RateLimiterMetatable = table.freeze({
	__index = RateLimiter,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function RateLimiter.new(TokensPerSecond: number, BurstLimit: number): any
	local self = setmetatable({
		_TokensPerSecond = TokensPerSecond,
		_BurstLimit      = BurstLimit,
		-- [Player] → current token count (float)
		-- Starts at BurstLimit so new players can immediately fire up to burst.
		_Tokens = setmetatable({}, { __mode = "k" }),
	}, RateLimiterMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Attempt to consume one token for the given player.
-- Returns true if a token was available (fire permitted),
-- false if the bucket is empty (fire rate-limited).
function RateLimiter.Acquire(self: any, Player: Player): boolean
	local Current = self._Tokens[Player]
	if Current == nil then
		-- First time this player fires — seed at BurstLimit.
		Current = self._BurstLimit
	end

	if Current < 1 then
		Logger:Debug(string_format(
			"RateLimiter: player '%s' rate-limited (%.2f tokens remaining)",
			Player.Name, Current
		))
		return false
	end

	self._Tokens[Player] = Current - 1
	return true
end

-- Regenerate tokens for all tracked players proportionally to elapsed time.
-- Called once per Heartbeat frame from the server frame loop.
-- DeltaTime is the Heartbeat delta in seconds.
--
-- Tokens regenerate at TokensPerSecond per second and cap at BurstLimit.
-- Players who have not fired yet are not tracked — they get seeded lazily
-- on their first Acquire() call.
function RateLimiter.Refill(self: any, DeltaTime: number)
	local Gain       = self._TokensPerSecond * DeltaTime
	local BurstLimit = self._BurstLimit
	for Player, Current in self._Tokens do
		local New = Current + Gain
		if New > BurstLimit then
			self._Tokens[Player] = BurstLimit
		else
			self._Tokens[Player] = New
		end
	end
end

-- Remove a disconnected player's token entry to prevent the table from
-- growing indefinitely as players join and leave over the course of a server's
-- lifetime. The weak-key metatable provides a safety net, but explicit Reset
-- is cleaner.
function RateLimiter.Reset(self: any, Player: Player)
	self._Tokens[Player] = nil
end

-- Idempotent destroy.
function RateLimiter.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Tokens)
	self._Tokens = nil
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(RateLimiter, {
	__index = function(_, Key)
		Logger:Warn(string_format("RateLimiter: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("RateLimiter: write to protected key '%s'", tostring(Key)))
	end,
}))
