--!strict

-- ─── AntiRewindGuard ─────────────────────────────────────────────────────────
--[[
    Server-side timestamp validation against rewind/clock drift attacks.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(script.Parent.Parent.Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("AntiRewindGuard", true)

-- ─── Module ──────────────────────────────────────────────────────────────────

local AntiRewindGuard = {}

function AntiRewindGuard.IsValid(
	ClaimedTimestamp  : number,
	ServerNow         : number,
	MaxRewindAge      : number
): (boolean, string?)
	local Age = ServerNow - ClaimedTimestamp

	if Age < 0 then
		return false, string.format("timestamp is %.3fs in the future", -Age)
	end

	if Age > MaxRewindAge then
		return false, string.format("timestamp is %.3fs old (max: %.3fs)", Age, MaxRewindAge)
	end

	return true, nil
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(AntiRewindGuard, {
	__index = function(_, Key)
		Logger:Warn(string.format("Vetra: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Vetra: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
		))
	end,
})
