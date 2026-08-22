--!strict
--!optimize 2
--!native

local Types = script.Parent.Parent.Types

local Constants = require(Types.Constants)

local string_format = string.format

local _NameToHash     : { [string]: number } = {}
local _HashToBehavior : { [number]: any }    = {}
local _NextHash = 1

local BehaviorRegistry = {}

function BehaviorRegistry.Register(Name: string, Behavior: any): number
	if type(Name) ~= "string" or #Name == 0 then
		warn("BehaviorRegistry.Register: Name must be a non-empty string")
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end
	if type(Behavior) ~= "table" then
		warn(string_format("BehaviorRegistry.Register: Behavior for '%s' must be a table, got %s", Name, typeof(Behavior)))
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end

	local Existing = _NameToHash[Name]
	if Existing then
		warn(string_format("BehaviorRegistry.Register: '%s' already registered with hash %d — returning existing", Name, Existing))
		return Existing
	end

	local Hash = _NextHash
	if Hash > 65535 then
		error("BehaviorRegistry: hash space exhausted (>65535 registrations)", 2)
		return Constants.UNKNOWN_BEHAVIOR_HASH
	end
	_NextHash += 1

	_NameToHash[Name]     = Hash
	_HashToBehavior[Hash] = Behavior

	if Behavior.MaxSpeed == nil then
		warn(string_format("BehaviorRegistry.Register: behavior '%s' has no MaxSpeed", Name))
	end

	return Hash
end

function BehaviorRegistry.Get(Hash: number): any?
	if Hash == Constants.UNKNOWN_BEHAVIOR_HASH then return nil end
	return _HashToBehavior[Hash]
end

function BehaviorRegistry.GetHash(Name: string): number
	return _NameToHash[Name] or Constants.UNKNOWN_BEHAVIOR_HASH
end

return table.freeze(BehaviorRegistry)
