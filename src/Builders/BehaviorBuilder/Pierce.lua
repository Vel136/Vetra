--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type PierceFilter  = Types.PierceFilter

local PierceBuilder = {}
PierceBuilder.__index = PierceBuilder

export type PierceBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, PierceBuilder))

-- Pierce gate. Return true to pierce; false treats the hit as a terminal impact.
function PierceBuilder.Filter(self: PierceBuilder, Callback: PierceFilter): PierceBuilder
    assert(type(Callback) == "function", "PierceBuilder:Filter — expected function")
    self._Config.CanPierceFunction = Callback
    return self
end

-- Lifetime pierce limit.
function PierceBuilder.Max(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:Max — expected number")
    self._Config.MaxPierceCount = Value
    return self
end

-- Min speed (studs/s) required to attempt a pierce.
function PierceBuilder.SpeedThreshold(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:SpeedThreshold — expected number")
    self._Config.PierceSpeedThreshold = Value
    return self
end

-- Fraction of speed retained per pierce [0, 1].
function PierceBuilder.SpeedRetention(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:SpeedRetention — expected number")
    self._Config.PierceSpeedRetention = Value
    return self
end

-- Min approach angle [0, 1]. 1.0 = all angles; 0.0 = perpendicular only.
function PierceBuilder.NormalBias(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:NormalBias — expected number")
    self._Config.PierceNormalBias = Value
    return self
end

-- Max wall thickness per pierce in studs. 0 = no per-pierce limit.
function PierceBuilder.PierceDepth(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:PierceDepth — expected number")
    self._Config.PierceDepth = Value
    return self
end

-- Total momentum force budget. 0 = disabled.
function PierceBuilder.PierceForce(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value), "PierceBuilder:PierceForce — expected number")
    self._Config.PierceForce = Value
    return self
end

-- Hard cap on wall thickness for the exit-point raycast in studs.
function PierceBuilder.ThicknessLimit(self: PierceBuilder, Value: number): PierceBuilder
    assert(t.number(Value) and Value > 0, "PierceBuilder:ThicknessLimit — expected number > 0")
    self._Config.PierceThicknessLimit = Value
    return self
end

function PierceBuilder.Done(self: PierceBuilder): any
    return self._Root
end

return PierceBuilder
