--!strict
--CosmeticTracker.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Reconciliation/CosmeticTracker.lua
    Tracks client-side cosmetic bullets by server cast ID.

    When the client receives a replicated fire event, it fires a cosmetic bullet
    on the local solver and registers it here. DriftCorrector and state sync
    callbacks look up the local cast by server cast ID to apply corrections.

    CLIENT-ONLY. Errors at require() time if loaded on the server.

    Why a separate tracker instead of querying the solver?
    The local solver has no concept of "server cast IDs" — it assigns its own
    IDs starting from 0. CosmeticTracker is the mapping layer between the
    server's authoritative ID space and the client's local simulation IDs.
    Without it, there is no way to match an incoming state update (server ID N)
    to the correct cosmetic bullet in the local solver.
]]

local Identity        = "CosmeticTracker"

local CosmeticTracker = {}
CosmeticTracker.__type = Identity

local CosmeticTrackerMetatable = table.freeze({
	__index = CosmeticTracker,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertClient("CosmeticTracker")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function CosmeticTracker.new(): any
	local self = setmetatable({
		-- [serverCastId: number] → localCast (VetraCast handle from client solver)
		_ServerToLocal = {},
	}, CosmeticTrackerMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Associate a server cast ID with the local cast handle produced by
-- the client solver's Fire() call. Called immediately after Fire().
function CosmeticTracker.Register(self: any, ServerCastId: number, LocalCast: any)
	if self._ServerToLocal[ServerCastId] then
		Logger:Warn(string_format(
			"CosmeticTracker.Register: serverCastId %d already registered — overwriting",
			ServerCastId
		))
	end
	self._ServerToLocal[ServerCastId] = LocalCast
end

-- Remove the mapping when the cosmetic bullet terminates.
-- Called from the client solver's OnTerminated signal or from the single-remote
-- hit decoder in ClientHooks after a hit confirmation is received.
function CosmeticTracker.Unregister(self: any, ServerCastId: number)
	self._ServerToLocal[ServerCastId] = nil
end

-- Look up the local cast for a given server cast ID.
-- Returns nil if no mapping exists (the cosmetic bullet was never spawned,
-- already terminated, or the fire event was never received by this client).
function CosmeticTracker.GetLocal(self: any, ServerCastId: number): any?
	return self._ServerToLocal[ServerCastId]
end

-- Return all current serverCastId → localCast mappings.
-- Used by DriftCorrector to iterate over all active cosmetics in one pass.
function CosmeticTracker.GetAll(self: any): { [number]: any }
	return self._ServerToLocal
end

-- Idempotent destroy.
function CosmeticTracker.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._ServerToLocal)
	self._ServerToLocal = nil
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(CosmeticTracker, {
	__index = function(_, Key)
		Logger:Warn(string_format("CosmeticTracker: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("CosmeticTracker: write to protected key '%s'", tostring(Key)))
	end,
}))
