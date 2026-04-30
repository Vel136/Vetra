--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local GyroDriftBuilder = {}
GyroDriftBuilder.__index = GyroDriftBuilder

export type GyroDriftBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, GyroDriftBuilder))

-- Lateral drift acceleration magnitude in studs/s². Setting this enables drift.
function GyroDriftBuilder.Rate(self: GyroDriftBuilder, Value: number): GyroDriftBuilder
    assert(t.number(Value), "GyroDriftBuilder:Rate — expected number")
    self._Config.GyroDriftRate = Value
    return self
end

-- Reference axis for drift direction. nil = world UP (standard right-hand rifling).
function GyroDriftBuilder.Axis(self: GyroDriftBuilder, Value: Vector3): GyroDriftBuilder
    assert(t.Vector3(Value), "GyroDriftBuilder:Axis — expected Vector3")
    self._Config.GyroDriftAxis = Value
    return self
end

function GyroDriftBuilder.Done(self: GyroDriftBuilder): Types.BehaviorBuilder
    return self._Root
end

return GyroDriftBuilder
