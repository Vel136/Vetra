--!native
--!optimize 2
--!strict

local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local DebugBuilder = {}
DebugBuilder.__index = DebugBuilder

export type DebugBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, DebugBuilder))

function DebugBuilder.Visualize(self: DebugBuilder, Value: boolean): DebugBuilder
    assert(type(Value) == "boolean", "DebugBuilder:Visualize — expected boolean")
    self._Config.VisualizeCasts = Value
    self._Dirty.VisualizeCasts  = true
    return self
end

function DebugBuilder.Done(self: DebugBuilder): Types.BehaviorBuilder
    return self._Root
end

return DebugBuilder
