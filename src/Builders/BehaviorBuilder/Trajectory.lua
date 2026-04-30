--!native
--!optimize 2
--!strict

local Types  = require(script.Parent.Types)

type BuiltBehavior     = Types.BuiltBehavior
type TrajectoryProvider = Types.TrajectoryProvider

local TrajectoryBuilder = {}
TrajectoryBuilder.__index = TrajectoryBuilder

export type TrajectoryBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, TrajectoryBuilder))

-- Override bullet position each frame with a sampled curve.
-- Return nil to end the override and terminate the cast.
-- Signature: (elapsed: number) -> Vector3?
function TrajectoryBuilder.Provider(self: TrajectoryBuilder, Value: TrajectoryProvider): TrajectoryBuilder
    assert(type(Value) == "function", "TrajectoryBuilder:Provider — expected function")
    self._Config.TrajectoryPositionProvider = Value
    return self
end

function TrajectoryBuilder.Done(self: TrajectoryBuilder): Types.BehaviorBuilder
    return self._Root
end

return TrajectoryBuilder
