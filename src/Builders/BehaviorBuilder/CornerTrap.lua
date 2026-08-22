--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local CornerTrapBuilder = {}
CornerTrapBuilder.__index = CornerTrapBuilder

export type CornerTrapBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, CornerTrapBuilder))

function CornerTrapBuilder.TimeThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:TimeThreshold — expected number")
    self._Config.CornerTimeThreshold = Value
    self._Dirty.CornerTimeThreshold  = true
    return self
end

function CornerTrapBuilder.PositionHistorySize(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:PositionHistorySize — expected number")
    self._Config.CornerPositionHistorySize = Value
    self._Dirty.CornerPositionHistorySize  = true
    return self
end

function CornerTrapBuilder.DisplacementThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:DisplacementThreshold — expected number")
    self._Config.CornerDisplacementThreshold = Value
    self._Dirty.CornerDisplacementThreshold  = true
    return self
end

function CornerTrapBuilder.EMAAlpha(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:EMAAlpha — expected number")
    self._Config.CornerEMAAlpha = Value
    self._Dirty.CornerEMAAlpha  = true
    return self
end

function CornerTrapBuilder.EMAThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:EMAThreshold — expected number")
    self._Config.CornerEMAThreshold = Value
    self._Dirty.CornerEMAThreshold  = true
    return self
end

function CornerTrapBuilder.MinProgressPerBounce(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:MinProgressPerBounce — expected number >= 0")
    self._Config.CornerMinProgressPerBounce = Value
    self._Dirty.CornerMinProgressPerBounce  = true
    return self
end

function CornerTrapBuilder.Done(self: CornerTrapBuilder): Types.BehaviorBuilder
    return self._Root
end

return CornerTrapBuilder
