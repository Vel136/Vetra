--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type PierceFilter  = Types.PierceFilter

local PierceBuilder = {}
PierceBuilder.__index = PierceBuilder

export type PierceBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, PierceBuilder))

function PierceBuilder.Filter(self: PierceBuilder, Callback: PierceFilter): PierceBuilder
    assert(type(Callback) == "function", "PierceBuilder:Filter — expected function")
    self._Config.CanPierceFunction = Callback
    self._Dirty.CanPierceFunction  = true
    return self
end

function PierceBuilder.Max(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:Max — expected number")
    self._Config.MaxPierceCount = Value
    self._Dirty.MaxPierceCount  = true
    return self
end

function PierceBuilder.SpeedThreshold(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:SpeedThreshold — expected number")
    self._Config.PierceSpeedThreshold = Value
    self._Dirty.PierceSpeedThreshold  = true
    return self
end

function PierceBuilder.SpeedRetention(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:SpeedRetention — expected number")
    self._Config.PierceSpeedRetention = Value
    self._Dirty.PierceSpeedRetention  = true
    return self
end

function PierceBuilder.NormalBias(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:NormalBias — expected number")
    self._Config.PierceNormalBias = Value
    self._Dirty.PierceNormalBias  = true
    return self
end

function PierceBuilder.PierceDepth(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:PierceDepth — expected number")
    self._Config.PierceDepth = Value
    self._Dirty.PierceDepth  = true
    return self
end

function PierceBuilder.PierceForce(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:PierceForce — expected number")
    self._Config.PierceForce = Value
    self._Dirty.PierceForce  = true
    return self
end

function PierceBuilder.ThicknessLimit(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value) and Value > 0, "PierceBuilder:ThicknessLimit — expected number > 0")
    self._Config.PierceThicknessLimit = Value
    self._Dirty.PierceThicknessLimit  = true
    return self
end

function PierceBuilder.Done(self: PierceBuilder): Types.BehaviorBuilder
    return self._Root
end

return PierceBuilder
