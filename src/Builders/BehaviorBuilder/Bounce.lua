--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type BounceFilter  = Types.BounceFilter

local BounceBuilder = {}
BounceBuilder.__index = BounceBuilder

export type BounceBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, BounceBuilder))

-- Bounce gate. Return true to bounce; only evaluated if pierce did not occur.
function BounceBuilder.Filter(self: BounceBuilder, Callback: BounceFilter): BounceBuilder
    assert(type(Callback) == "function", "BounceBuilder:Filter — expected function")
    self._Config.CanBounceFunction = Callback
    return self
end

-- Lifetime bounce limit.
function BounceBuilder.Max(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:Max — expected number")
    self._Config.MaxBounces = Value
    return self
end

-- Min speed (studs/s) required to attempt a bounce.
function BounceBuilder.SpeedThreshold(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:SpeedThreshold — expected number")
    self._Config.BounceSpeedThreshold = Value
    return self
end

-- Base energy retention per bounce [0, 1].
function BounceBuilder.Restitution(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:Restitution — expected number")
    self._Config.Restitution = Value
    return self
end

-- Per-material restitution multipliers, combined with the base Restitution.
function BounceBuilder.MaterialRestitution(
    self: BounceBuilder,
    Value: { [Enum.Material]: number }
): BounceBuilder
    assert(type(Value) == "table", "BounceBuilder:MaterialRestitution — expected table")
    self._Config.MaterialRestitution = Value
    return self
end

-- Random surface-normal noise for rough surfaces. 0 = clean reflection.
function BounceBuilder.NormalPerturbation(self: BounceBuilder, Value: number): BounceBuilder
    assert(t.number(Value), "BounceBuilder:NormalPerturbation — expected number")
    self._Config.NormalPerturbation = Value
    return self
end

-- If true, pierce state resets after each confirmed bounce.
function BounceBuilder.ResetPierceOnBounce(self: BounceBuilder, Value: boolean): BounceBuilder
    assert(type(Value) == "boolean", "BounceBuilder:ResetPierceOnBounce — expected boolean")
    self._Config.ResetPierceOnBounce = Value
    return self
end

function BounceBuilder.Done(self: BounceBuilder): Types.BehaviorBuilder
    return self._Root
end

return BounceBuilder
