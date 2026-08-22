--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type BounceFilter  = Types.BounceFilter

local BounceBuilder = {}
BounceBuilder.__index = BounceBuilder

export type BounceBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, BounceBuilder))

function BounceBuilder.Filter(self: BounceBuilder, Callback: BounceFilter): BounceBuilder
    assert(type(Callback) == "function", "BounceBuilder:Filter — expected function")
    self._Config.CanBounceFunction = Callback
    self._Dirty.CanBounceFunction  = true
    return self
end

function BounceBuilder.Max(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:Max — expected number")
    self._Config.MaxBounces = Value
    self._Dirty.MaxBounces  = true
    return self
end

function BounceBuilder.SpeedThreshold(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:SpeedThreshold — expected number")
    self._Config.BounceSpeedThreshold = Value
    self._Dirty.BounceSpeedThreshold  = true
    return self
end

function BounceBuilder.Restitution(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:Restitution — expected number")
    self._Config.Restitution = Value
    self._Dirty.Restitution  = true
    return self
end

function BounceBuilder.MaterialRestitution(
    self: BounceBuilder,
    Value: { [Enum.Material]: number }
): BounceBuilder
    assert(type(Value) == "table", "BounceBuilder:MaterialRestitution — expected table")
    self._Config.MaterialRestitution = Value
    self._Dirty.MaterialRestitution  = true
    return self
end

function BounceBuilder.NormalPerturbation(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:NormalPerturbation — expected number")
    self._Config.NormalPerturbation = Value
    self._Dirty.NormalPerturbation  = true
    return self
end

function BounceBuilder.ResetPierceOnBounce(self: BounceBuilder, Value: boolean): BounceBuilder
    assert(type(Value) == "boolean", "BounceBuilder:ResetPierceOnBounce — expected boolean")
    self._Config.ResetPierceOnBounce = Value
    self._Dirty.ResetPierceOnBounce  = true
    return self
end

function BounceBuilder.Done(self: BounceBuilder): Types.BehaviorBuilder
    return self._Root
end

return BounceBuilder
