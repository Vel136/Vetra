--!strict
--!optimize 2
--!native

local CosmeticTracker = {}
CosmeticTracker.__index = CosmeticTracker

local table_clear = table.clear

function CosmeticTracker.new(): any
	return setmetatable({
		_ServerToLocal = {},
	}, CosmeticTracker)
end

function CosmeticTracker.Register(self: any, ServerCastId: number, LocalCast: any)
	if self._ServerToLocal[ServerCastId] then
		warn(string.format("CosmeticTracker.Register: serverCastId %d already registered — overwriting", ServerCastId))
	end
	self._ServerToLocal[ServerCastId] = LocalCast
end

function CosmeticTracker.Unregister(self: any, ServerCastId: number)
	self._ServerToLocal[ServerCastId] = nil
end

function CosmeticTracker.GetLocal(self: any, ServerCastId: number): any?
	return self._ServerToLocal[ServerCastId]
end

function CosmeticTracker.GetAll(self: any): { [number]: any }
	return self._ServerToLocal
end

function CosmeticTracker.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._ServerToLocal)
	self._ServerToLocal = nil
	setmetatable(self, nil)
end

return table.freeze(CosmeticTracker)
