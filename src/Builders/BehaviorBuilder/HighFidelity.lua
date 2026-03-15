--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local HighFidelityBuilder = {}
HighFidelityBuilder.__index = HighFidelityBuilder

export type HighFidelityBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, HighFidelityBuilder))

-- Sub-segment length in studs (starting value, may shrink adaptively).
function HighFidelityBuilder.SegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:SegmentSize — expected number")
    self._Config.HighFidelitySegmentSize = Value
    return self
end

-- Millisecond budget per cast per frame for sub-segment raycasts.
function HighFidelityBuilder.FrameBudget(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:FrameBudget — expected number")
    self._Config.HighFidelityFrameBudget = Value
    return self
end

-- Adaptive sizing multiplier. Must be > 1.
function HighFidelityBuilder.AdaptiveScale(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:AdaptiveScale — expected number")
    self._Config.AdaptiveScaleFactor = Value
    return self
end

-- Hard floor for adaptive segment size. Must be <= SegmentSize.
function HighFidelityBuilder.MinSegmentSize(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:MinSegmentSize — expected number")
    self._Config.MinSegmentSize = Value
    return self
end

-- Per-frame bounce cap across all sub-segments.
function HighFidelityBuilder.MaxBouncesPerFrame(self: HighFidelityBuilder, Value: number): HighFidelityBuilder
    assert(t.number(Value), "HighFidelityBuilder:MaxBouncesPerFrame — expected number")
    self._Config.MaxBouncesPerFrame = Value
    return self
end

function HighFidelityBuilder.Done(self: HighFidelityBuilder): any
    return self._Root
end

return HighFidelityBuilder
