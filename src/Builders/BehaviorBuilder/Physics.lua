--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local PhysicsBuilder = {}
PhysicsBuilder.__index = PhysicsBuilder

export type PhysicsBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, PhysicsBuilder))

function PhysicsBuilder.MaxDistance(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MaxDistance — expected number")
    self._Config.MaxDistance = Value
    return self
end

function PhysicsBuilder.MinSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MinSpeed — expected number")
    self._Config.MinSpeed = Value
    return self
end

function PhysicsBuilder.MaxSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MaxSpeed — expected number")
    self._Config.MaxSpeed = Value
    return self
end

function PhysicsBuilder.Gravity(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
    assert(t.Vector3(Value), "PhysicsBuilder:Gravity — expected Vector3")
    self._Config.Gravity = Value
    return self
end

function PhysicsBuilder.Acceleration(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
    assert(t.Vector3(Value), "PhysicsBuilder:Acceleration — expected Vector3")
    self._Config.Acceleration = Value
    return self
end

function PhysicsBuilder.RaycastParams(self: PhysicsBuilder, Value: RaycastParams): PhysicsBuilder
    assert(typeof(Value) == "RaycastParams", "PhysicsBuilder:RaycastParams — expected RaycastParams")
    self._Config.RaycastParams = Value
    return self
end

-- Serial solver only — silently ignored by Vetra.newParallel().
-- fn(origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?
function PhysicsBuilder.CastFunction(
    self: PhysicsBuilder,
    Value: (Vector3, Vector3, RaycastParams) -> RaycastResult?
): PhysicsBuilder
    assert(type(Value) == "function", "PhysicsBuilder:CastFunction — expected function")
    self._Config.CastFunction = Value
    return self
end

function PhysicsBuilder.BulletMass(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:BulletMass — expected number")
    self._Config.BulletMass = Value
    return self
end

function PhysicsBuilder.Done(self: PhysicsBuilder): Types.BehaviorBuilder
    return self._Root
end

return PhysicsBuilder
