--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local HighFidelityBuilder = {}
HighFidelityBuilder.__index = HighFidelityBuilder

export type HighFidelityBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, HighFidelityBuilder))

function HighFidelityBuilder.SegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:SegmentSize — expected number")
    self._Config.HighFidelitySegmentSize = Value
    self._Dirty.HighFidelitySegmentSize  = true
    return self
end

function HighFidelityBuilder.FrameBudget(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:FrameBudget — expected number")
    self._Config.HighFidelityFrameBudget = Value
    self._Dirty.HighFidelityFrameBudget  = true
    return self
end

function HighFidelityBuilder.AdaptiveScale(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:AdaptiveScale — expected number")
    self._Config.AdaptiveScaleFactor = Value
    self._Dirty.AdaptiveScaleFactor  = true
    return self
end

function HighFidelityBuilder.MinSegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:MinSegmentSize — expected number")
    self._Config.MinSegmentSize = Value
    self._Dirty.MinSegmentSize  = true
    return self
end

function HighFidelityBuilder.MaxBouncesPerFrame(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:MaxBouncesPerFrame — expected number")
    self._Config.MaxBouncesPerFrame = Value
    self._Dirty.MaxBouncesPerFrame  = true
    return self
end

function HighFidelityBuilder.Done(self: HighFidelityBuilder): Types.BehaviorBuilder
    return self._Root
end

return HighFidelityBuilder
