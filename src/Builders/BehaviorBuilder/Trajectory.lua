--!native
--!optimize 2
--!strict

local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior     = Types.BuiltBehavior
type TrajectoryProvider = Types.TrajectoryProvider

local TrajectoryBuilder = {}
TrajectoryBuilder.__index = TrajectoryBuilder

export type TrajectoryBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, TrajectoryBuilder))

function TrajectoryBuilder.Provider(self: TrajectoryBuilder, Value: TrajectoryProvider): TrajectoryBuilder
    assert(type(Value) == "function", "TrajectoryBuilder:Provider — expected function")
    self._Config.TrajectoryPositionProvider = Value
    self._Dirty.TrajectoryPositionProvider  = true
    return self
end

function TrajectoryBuilder.Done(self: TrajectoryBuilder): Types.BehaviorBuilder
    return self._Root
end

return TrajectoryBuilder
