--!native
--!optimize 2
--!strict

-- ─── CastRegistry ────────────────────────────────────────────────────────────
--[[
    O(1) swap-remove registry for active VetraCast objects.
]]

local Identity      = "CastRegistry"
local CastRegistry  = {}
CastRegistry.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local t          = require(Core.TypeCheck)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

-- NextCastId has been removed from module scope.
-- IDs are now tracked per-solver (Solver._NextCastId) so that two concurrent
-- Solver instances cannot share the same ID namespace.

function CastRegistry.Register(Solver: any, Cast: any, RegistryLogger: any): boolean
	if not t.table(Cast) then
		RegistryLogger:Warn("CastRegistry.Register: Cast must be a table")
		return false
	end
	if Cast._registryIndex then
		RegistryLogger:Warn("CastRegistry.Register: cast already registered")
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
		RegistryLogger:Warn("CastRegistry.Remove: Cast must be a table")
		return false
	end

	local ActiveCasts = Solver._ActiveCasts
	if #ActiveCasts == 0 then
		RegistryLogger:Warn("CastRegistry.Remove: no active casts")
		return false
	end
	if not Cast._registryIndex then
		RegistryLogger:Warn("CastRegistry.Remove: cast has no _registryIndex")
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

-- ─── Module Return ───────────────────────────────────────────────────────────

local CastRegistryMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("CastRegistry: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"CastRegistry: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(CastRegistry, CastRegistryMetatable)