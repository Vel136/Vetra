--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type SpeedProfile  = Types.SpeedProfile
type DragModel     = Types.DragModel

local IsValidDragModel = Types.IsValidDragModel

-- ─── SpeedProfileBuilder (inner) ─────────────────────────────────────────────
--[[
    Builds a single SpeedProfile table (supersonic or subsonic regime).
    Returned by SpeedProfilesBuilder:Supersonic() and :Subsonic().
    :Done() writes the completed profile back to the parent config and
    returns the parent SpeedProfilesBuilder, not the root BehaviorBuilder.
    Call :Done() a second time on SpeedProfilesBuilder to reach the root.
]]

local SpeedProfileBuilder = {}
SpeedProfileBuilder.__index = SpeedProfileBuilder

export type SpeedProfileBuilder = typeof(setmetatable({} :: {
    _Parent  : any,        -- SpeedProfilesBuilder
    _Config  : BuiltBehavior,
    _Profile : SpeedProfile,
    _Key     : string,     -- "SupersonicProfile" | "SubsonicProfile"
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

-- Commits the profile and returns the parent SpeedProfilesBuilder.
function SpeedProfileBuilder.Done(self: SpeedProfileBuilder): any
    (self._Config :: any)[self._Key] = self._Profile
    return self._Parent
end

-- ─── SpeedProfilesBuilder (outer) ────────────────────────────────────────────

local SpeedProfilesBuilder = {}
SpeedProfilesBuilder.__index = SpeedProfilesBuilder

export type SpeedProfilesBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, SpeedProfilesBuilder))

-- Sorted list of speeds (studs/s) that fire OnSpeedThresholdCrossed.
function SpeedProfilesBuilder.Thresholds(self: SpeedProfilesBuilder, Value: { number }): SpeedProfilesBuilder
    assert(type(Value) == "table", "SpeedProfilesBuilder:Thresholds — expected array of numbers")
    self._Config.SpeedThresholds = Value
    return self
end

-- Opens a SpeedProfileBuilder for the supersonic regime (speed >= 343 studs/s).
function SpeedProfilesBuilder.Supersonic(self: SpeedProfilesBuilder): SpeedProfileBuilder
    return setmetatable({
        _Parent  = self,
        _Config  = self._Config,
        _Profile = {} :: SpeedProfile,
        _Key     = "SupersonicProfile",
    }, SpeedProfileBuilder)
end

-- Opens a SpeedProfileBuilder for the subsonic regime (speed < 343 studs/s).
function SpeedProfilesBuilder.Subsonic(self: SpeedProfilesBuilder): SpeedProfileBuilder
    return setmetatable({
        _Parent  = self,
        _Config  = self._Config,
        _Profile = {} :: SpeedProfile,
        _Key     = "SubsonicProfile",
    }, SpeedProfileBuilder)
end

-- Returns the root BehaviorBuilder.
function SpeedProfilesBuilder.Done(self: SpeedProfilesBuilder): any
    return self._Root
end

return {
    SpeedProfileBuilder  = SpeedProfileBuilder,
    SpeedProfilesBuilder = SpeedProfilesBuilder,
}
