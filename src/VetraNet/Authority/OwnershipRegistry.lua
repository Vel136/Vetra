--!strict
--!optimize 2
--!native

local OwnershipRegistry = {}
OwnershipRegistry.__index = OwnershipRegistry

local table_clear = table.clear

function OwnershipRegistry.new(): any
	return setmetatable({
		_CastToPlayer  = {},
		_PlayerToCasts = setmetatable({}, { __mode = "k" }),
	}, OwnershipRegistry)
end

function OwnershipRegistry.Register(self: any, CastId: number, Player: Player)
	if self._CastToPlayer[CastId] then
		warn(string.format("OwnershipRegistry.Register: castId %d already registered — overwriting", CastId))
	end
	self._CastToPlayer[CastId] = Player

	local PlayerCasts = self._PlayerToCasts[Player]
	if not PlayerCasts then
		PlayerCasts = {}
		self._PlayerToCasts[Player] = PlayerCasts
	end
	PlayerCasts[CastId] = true
end

function OwnershipRegistry.Unregister(self: any, CastId: number)
	local Owner = self._CastToPlayer[CastId]
	if Owner then
		local PlayerCasts = self._PlayerToCasts[Owner]
		if PlayerCasts then
			PlayerCasts[CastId] = nil
		end
	end
	self._CastToPlayer[CastId] = nil
end

function OwnershipRegistry.GetOwner(self: any, CastId: number): Player?
	return self._CastToPlayer[CastId]
end

function OwnershipRegistry.IsOwner(self: any, CastId: number, Player: Player): boolean
	return self._CastToPlayer[CastId] == Player
end

function OwnershipRegistry.GetCastsForPlayer(self: any, Player: Player): { number }
	local PlayerCasts = self._PlayerToCasts[Player]
	if not PlayerCasts then return {} end
	local Result = {}
	for CastId in PlayerCasts do
		Result[#Result + 1] = CastId
	end
	return Result
end

function OwnershipRegistry.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._CastToPlayer)
	table_clear(self._PlayerToCasts)
	self._CastToPlayer  = nil
	self._PlayerToCasts = nil
	setmetatable(self, nil)
end

return table.freeze(OwnershipRegistry)
