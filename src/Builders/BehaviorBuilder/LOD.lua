--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local LODBuilder = {}
LODBuilder.__index = LODBuilder

export type LODBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, LODBuilder))

function LODBuilder.Distance(self: LODBuilder, Value: number): LODBuilder
    assert(t.number(Value), "LODBuilder:Distance — expected number")
    self._Config.LODDistance = Value
    self._Dirty.LODDistance  = true
    return self
end

function LODBuilder.Interval(self: LODBuilder, Value: number): LODBuilder
    assert(t.number(Value), "LODBuilder:Interval — expected number")
    assert(Value >= 1, "LODBuilder:Interval — must be >= 1 (1 = step every frame)")
    self._Config.LODInterval = math.floor(Value)
    self._Dirty.LODInterval  = true
    return self
end

function LODBuilder.Done(self: LODBuilder): Types.BehaviorBuilder
    return self._Root
end

return LODBuilder
