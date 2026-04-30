--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local CornerTrapBuilder = {}
CornerTrapBuilder.__index = CornerTrapBuilder

export type CornerTrapBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, CornerTrapBuilder))

-- Min seconds between successive bounces (Pass 1).
function CornerTrapBuilder.TimeThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:TimeThreshold — expected number")
    self._Config.CornerTimeThreshold = Value
    return self
end

-- Bounce contact point history size. Must be a positive integer (Pass 3 & 4).
function CornerTrapBuilder.PositionHistorySize(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:PositionHistorySize — expected number")
    self._Config.CornerPositionHistorySize = Value
    return self
end

-- Min stud distance between successive bounce contact points (Pass 3).
function CornerTrapBuilder.DisplacementThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:DisplacementThreshold — expected number")
    self._Config.CornerDisplacementThreshold = Value
    return self
end

-- EMA smoothing factor for velocity direction tracking (Pass 2). Must be in (0, 1).
-- Changing this requires updating EMAThreshold — :Build() enforces the constraint.
function CornerTrapBuilder.EMAAlpha(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:EMAAlpha — expected number")
    self._Config.CornerEMAAlpha = Value
    return self
end

-- Oscillation threshold (Pass 2). Must be > |1 - 2·EMAAlpha|.
function CornerTrapBuilder.EMAThreshold(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:EMAThreshold — expected number")
    self._Config.CornerEMAThreshold = Value
    return self
end

-- Min studs of progress per bounce over the history window (Pass 4). 0 disables Pass 4.
function CornerTrapBuilder.MinProgressPerBounce(self: CornerTrapBuilder, Value: number): CornerTrapBuilder
    assert(t.number(Value), "CornerTrapBuilder:MinProgressPerBounce — expected number >= 0")
    self._Config.CornerMinProgressPerBounce = Value
    return self
end

function CornerTrapBuilder.Done(self: CornerTrapBuilder): Types.BehaviorBuilder
    return self._Root
end

return CornerTrapBuilder
