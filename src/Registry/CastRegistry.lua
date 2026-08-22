--!strict
--!optimize 2
--!native

local CastRegistry  = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local t = require(Core.TypeCheck)

function CastRegistry.Register(Solver: any, Cast: any, RegistryLogger: any): boolean
	if not t.table(Cast) then
		warn("CastRegistry.Register: Cast must be a table")
		return false
	end
	if Cast._registryIndex then
		warn("CastRegistry.Register: cast already registered")
		return false
	end

	local ActiveCasts   = Solver._ActiveCasts
	local RegistryIndex = #ActiveCasts + 1
	Cast._registryIndex        = RegistryIndex
	ActiveCasts[RegistryIndex] = Cast
	return true
end

function CastRegistry.Remove(Solver: any, Cast: any, RegistryLogger: any): boolean
	if not t.table(Cast) then
		warn("CastRegistry.Remove: Cast must be a table")
		return false
	end

	local ActiveCasts = Solver._ActiveCasts
	if #ActiveCasts == 0 then
		warn("CastRegistry.Remove: no active casts")
		return false
	end
	if not Cast._registryIndex then
		warn("CastRegistry.Remove: cast has no _registryIndex")
		return false
	end

	local RemoveIndex = Cast._registryIndex
	local LastIndex   = #ActiveCasts
	local LastCast    = ActiveCasts[LastIndex]

	if RemoveIndex == LastIndex then
		ActiveCasts[LastIndex] = nil
		Cast._registryIndex    = nil
		return true
	end

	ActiveCasts[RemoveIndex]  = LastCast
	LastCast._registryIndex   = RemoveIndex
	ActiveCasts[LastIndex]    = nil
	Cast._registryIndex       = nil
	return true
end

return table.freeze(CastRegistry)
