--!strict
--BehaviorRegistry.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/BehaviorRegistry.lua
    Pre-registered behavior hash table.

    The core insight here is that full behavior tables are never sent over the
    network. Instead, both server and client register the same behaviors at
    startup with identical names. Fire payloads carry only the 2-byte u16 hash.
    The server resolves the full behavior by hash lookup — zero serialization
    cost, zero deserialization cost, and zero ability for the client to inject
    or modify a behavior by crafting a custom table.

    Hash assignment: behaviors are assigned sequential u16 IDs starting at 1
    in registration order. Hash 0 is reserved as UNKNOWN_BEHAVIOR_HASH (the
    sentinel for "not found" returns). This means the 65535-behavior cap is
    effectively infinite for any realistic game.

    Both server and client MUST register behaviors in the same order with the
    same names. If they diverge, hashes will not match and every fire request
    will be rejected as RejectedUnknownBehavior. This is a configuration error,
    not a runtime exploit — enforce it with shared module registration code.
]]

local Identity         = "BehaviorRegistry"

local BehaviorRegistry = {}
BehaviorRegistry.__type = Identity

local BehaviorRegistryMetatable = table.freeze({
	__index = BehaviorRegistry,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core  = script.Parent.Parent.Core
local Types = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Types.Constants)
local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_clear   = table.clear
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function BehaviorRegistry.new(): any
	local self = setmetatable({
		-- name → u16 hash
		_NameToHash     = {} :: { [string]: number },
		-- u16 hash → BuiltBehavior
		_HashToBehavior = {} :: { [number]: any },
		-- Monotonic counter; starts at 1 (0 is reserved as UNKNOWN_BEHAVIOR_HASH).
		_NextHash = 1,
	}, BehaviorRegistryMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Register a named behavior and return its assigned u16 hash.
-- Registering the same name twice is idempotent — the existing hash is
-- returned without creating a duplicate entry. Registering the same behavior
-- under a different name produces a separate hash, which is intentional
-- (weapon variants may share physics but carry different visual behaviors).
function BehaviorRegistry.Register(self: any, Name: string, Behavior: any): number
	if type(Name) ~= "string" or #Name == 0 then
		Logger:Warn("BehaviorRegistry.Register: Name must be a non-empty string")
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end
	if type(Behavior) ~= "table" then
		Logger:Warn(string_format(
			"BehaviorRegistry.Register: Behavior for '%s' must be a table, got %s",
			Name, typeof(Behavior)
			))
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end

	-- Idempotent — return the existing hash if already registered.
	local Existing = self._NameToHash[Name]
	if Existing then
		Logger:Warn(string_format(
			"BehaviorRegistry.Register: '%s' is already registered with hash %d — returning existing",
			Name, Existing
			))
		return Existing
	end

	-- Assign the next sequential hash.
	local Hash = self._NextHash
	if Hash > 65535 then
		-- u16 overflow — 65 535 behaviors exceeds any realistic game's weapon
		-- count by several orders of magnitude. Treat as fatal misconfiguration.
		Logger:Error("BehaviorRegistry: behavior hash space exhausted (>65535 registrations)")
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end

	-- Warn if MaxSpeed is not set. FireValidator uses Behavior.MaxSpeed to cap
	-- per-behavior fire speed — without it, the validator falls back to the
	-- global DEFAULT_MAX_SPEED constant, making per-weapon speed limits inert.
	if Behavior.MaxSpeed == nil then
		Logger:Warn(string_format(
			"BehaviorRegistry.Register: behavior '%s' has no MaxSpeed — " ..
				"speed validation will use the global default cap. " ..
				"Set MaxSpeed explicitly via BehaviorBuilder:Physics():MaxSpeed(n):Done() " ..
				"or add MaxSpeed to the behavior table.",
			Name
			))
	end
	self._NextHash += 1

	self._NameToHash[Name]     = Hash
	self._HashToBehavior[Hash] = Behavior

	Logger:Debug(string_format("BehaviorRegistry: registered '%s' → hash %d", Name, Hash))
	return Hash
end

-- Look up the BuiltBehavior for a given u16 hash.
-- Returns nil if the hash was never registered, which FireValidator treats
-- as RejectedUnknownBehavior and rejects the bullet server-side.
function BehaviorRegistry.Get(self: any, Hash: number): any?
	if Hash == Constants.UNKNOWN_BEHAVIOR_HASH then
		return nil
	end
	return self._HashToBehavior[Hash]
end

-- Look up the hash for a given name. Returns UNKNOWN_BEHAVIOR_HASH (0) if
-- the name has not been registered. Clients use this to fill the BehaviorHash
-- field in EncodeFire before sending.
function BehaviorRegistry.GetHash(self: any, Name: string): number
	return self._NameToHash[Name] or Constants.UNKNOWN_BEHAVIOR_HASH
end

-- Idempotent destroy.
function BehaviorRegistry.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._NameToHash)
	table_clear(self._HashToBehavior)
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(BehaviorRegistry, {
	__index = function(_, Key)
		Logger:Warn(string_format("BehaviorRegistry: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("BehaviorRegistry: write to protected key '%s'", tostring(Key)))
	end,
}))
