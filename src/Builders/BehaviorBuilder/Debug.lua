--!native
--!optimize 2
--!strict

local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local DebugBuilder = {}
DebugBuilder.__index = DebugBuilder

export type DebugBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, DebugBuilder))

-- Enables the trajectory visualizer. Zero runtime cost when false.
function DebugBuilder.Visualize(self: DebugBuilder, Value: boolean): DebugBuilder
    assert(type(Value) == "boolean", "DebugBuilder:Visualize — expected boolean")
    self._Config.VisualizeCasts = Value
    return self
end

function DebugBuilder.Done(self: DebugBuilder): any
    return self._Root
end

return DebugBuilder
