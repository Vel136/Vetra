--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Parent.Parent.Core.Enums)

type BuiltBehavior = Types.BuiltBehavior
type DirtySet      = Types.DirtySet
type SpeedProfile  = Types.SpeedProfile
type DragModel     = Types.DragModel

local function IsValidDragModel(Value: any): boolean
    if type(Value) ~= "number" then return false end
    for _, v in Enums.DragModel do
        if v == Value then return true end
    end
    return false
end

-- ─── SpeedProfileBuilder (inner) ─────────────────────────────────────────────
--[[
    Builds a single SpeedProfile table (supersonic or subsonic regime).
    Returned by SpeedProfilesBuilder:Supersonic() and :Subsonic().
    :Done() commits the profile to _Config[_Key], marks the root _Dirty, and
    returns the parent SpeedProfilesBuilder.
]]

local SpeedProfileBuilder = {}
SpeedProfileBuilder.__index = SpeedProfileBuilder

export type SpeedProfileBuilder = typeof(setmetatable({} :: {
    _Parent      : any,        -- SpeedProfilesBuilder
    _Config      : BuiltBehavior,
    _RootDirty   : DirtySet,   -- the root builder's _Dirty, for marking on commit
    _Profile     : SpeedProfile,
    _Key         : string,     -- "SupersonicProfile" | "SubsonicProfile"
}, SpeedProfileBuilder))

function SpeedProfileBuilder.DragCoefficient(self: SpeedProfileBuilder, Value: number): SpeedProfileBuilder
    assert(t.number(Value), "SpeedProfileBuilder:DragCoefficient — expected number")
    self._Profile.DragCoefficient = Value
    return self
end

function SpeedProfileBuilder.DragModel(self: SpeedProfileBuilder, Value: DragModel): SpeedProfileBuilder
    assert(
        type(Value) == "string" and IsValidDragModel(Value),
        "SpeedProfileBuilder:DragModel — expected a BehaviorBuilder.DragModel enum value"
    )
    self._Profile.DragModel = Value
    return self
end

function SpeedProfileBuilder.NormalPerturbation(self: SpeedProfileBuilder, Value: number): SpeedProfileBuilder
    assert(t.number(Value), "SpeedProfileBuilder:NormalPerturbation — expected number")
    self._Profile.NormalPerturbation = Value
    return self
end

function SpeedProfileBuilder.Restitution(self: SpeedProfileBuilder, Value: number): SpeedProfileBuilder
    assert(t.number(Value), "SpeedProfileBuilder:Restitution — expected number")
    self._Profile.Restitution = Value
    return self
end

function SpeedProfileBuilder.MaterialRestitution(
    self: SpeedProfileBuilder,
    Value: { [Enum.Material]: number }
): SpeedProfileBuilder
    assert(type(Value) == "table", "SpeedProfileBuilder:MaterialRestitution — expected table")
    self._Profile.MaterialRestitution = Value
    return self
end

-- Commits the profile to _Config[_Key], marks it dirty on the root builder,
-- and returns the parent SpeedProfilesBuilder.
function SpeedProfileBuilder.Done(self: SpeedProfileBuilder): any
    (self._Config :: any)[self._Key] = self._Profile
    self._RootDirty[self._Key]       = true
    return self._Parent
end

-- ─── SpeedProfilesBuilder (outer) ────────────────────────────────────────────

local SpeedProfilesBuilder = {}
SpeedProfilesBuilder.__index = SpeedProfilesBuilder

export type SpeedProfilesBuilder = typeof(setmetatable({} :: {
    _Root      : any,
    _Config    : BuiltBehavior,
    _Dirty     : DirtySet,
}, SpeedProfilesBuilder))

function SpeedProfilesBuilder.Thresholds(self: SpeedProfilesBuilder, Value: { number }): SpeedProfilesBuilder
    assert(type(Value) == "table", "SpeedProfilesBuilder:Thresholds — expected array of numbers")
    self._Config.SpeedThresholds = Value
    self._Dirty.SpeedThresholds  = true
    return self
end

function SpeedProfilesBuilder.Supersonic(self: SpeedProfilesBuilder): SpeedProfileBuilder
    return setmetatable({
        _Parent    = self,
        _Config    = self._Config,
        _RootDirty = self._Dirty,
        _Profile   = {} :: SpeedProfile,
        _Key       = "SupersonicProfile",
    }, SpeedProfileBuilder)
end

function SpeedProfilesBuilder.Subsonic(self: SpeedProfilesBuilder): SpeedProfileBuilder
    return setmetatable({
        _Parent    = self,
        _Config    = self._Config,
        _RootDirty = self._Dirty,
        _Profile   = {} :: SpeedProfile,
        _Key       = "SubsonicProfile",
    }, SpeedProfileBuilder)
end

function SpeedProfilesBuilder.Done(self: SpeedProfilesBuilder): any
    return self._Root
end

return {
    SpeedProfileBuilder  = SpeedProfileBuilder,
    SpeedProfilesBuilder = SpeedProfilesBuilder,
}