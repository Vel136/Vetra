--!strict
--!optimize 2
--!native

local Session  = {}
Session.__index = Session

local Enums = require(script.Parent.Parent.Types.Enums)

local math_max    = math.max
local table_clear = table.clear

type SessionEntry = {
	_ActiveCastIds : { [number]: true },
	_CastCount     : number,
}

function Session.new(ResolvedConfig: any): any
	return setmetatable({
		_Config    = ResolvedConfig,
		_Destroyed = false,
		_Sessions  = {},
	}, Session)
end

function Session.Register(self: any, Player: Player)
	if self._Sessions[Player] then
		warn("Session.Register: '" .. Player.Name .. "' already has a session")
		return
	end
	self._Sessions[Player] = {
		_ActiveCastIds = {},
		_CastCount     = 0,
	}
end

function Session.Unregister(self: any, Player: Player)
	self._Sessions[Player] = nil
end

function Session.CanFire(self: any, Player: Player): string
	local Entry = self._Sessions[Player]
	if not Entry then
		return Enums.SessionStatus.Inactive
	end
	if Entry._CastCount >= self._Config.MaxConcurrentPerPlayer then
		return Enums.SessionStatus.AtLimit
	end
	return Enums.SessionStatus.Ready
end

function Session.AddCast(self: any, Player: Player, CastId: number)
	local Entry = self._Sessions[Player]
	if not Entry then
		warn("Session.AddCast: no session for '" .. Player.Name .. "' — creating lazily")
		self:Register(Player)
		Entry = self._Sessions[Player]
	end
	if Entry._ActiveCastIds[CastId] then
		warn(string.format("Session.AddCast: duplicate castId %d for '%s'", CastId, Player.Name))
		return
	end
	Entry._ActiveCastIds[CastId] = true
	Entry._CastCount += 1
end

function Session.RemoveCast(self: any, Player: Player, CastId: number)
	local Entry = self._Sessions[Player]
	if not Entry then return end
	if not Entry._ActiveCastIds[CastId] then return end
	Entry._ActiveCastIds[CastId] = nil
	Entry._CastCount = math_max(0, Entry._CastCount - 1)
end

function Session.GetActiveCasts(self: any, Player: Player): { number }
	local Entry = self._Sessions[Player]
	if not Entry then return {} end
	local CastIds = {}
	for CastId in Entry._ActiveCastIds do
		CastIds[#CastIds + 1] = CastId
	end
	return CastIds
end

function Session.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Sessions)
	self._Sessions = nil
	setmetatable(self, nil)
end

return table.freeze(Session)
