--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

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
    self._Dirty.MaxDistance  = true
    return self
end

function PhysicsBuilder.MaxDisplacement(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MaxDisplacement — expected number")
    self._Config.MaxDisplacement = Value
    self._Dirty.MaxDisplacement  = true
    return self
end

function PhysicsBuilder.MinSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MinSpeed — expected number")
    self._Config.MinSpeed = Value
    self._Dirty.MinSpeed  = true
    return self
end

function PhysicsBuilder.MaxSpeed(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:MaxSpeed — expected number")
    self._Config.MaxSpeed = Value
    self._Dirty.MaxSpeed  = true
    return self
end

function PhysicsBuilder.Gravity(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
    assert(t.Vector3(Value), "PhysicsBuilder:Gravity — expected Vector3")
    self._Config.Gravity = Value
    self._Dirty.Gravity  = true
    return self
end

function PhysicsBuilder.Acceleration(self: PhysicsBuilder, Value: Vector3): PhysicsBuilder
    assert(t.Vector3(Value), "PhysicsBuilder:Acceleration — expected Vector3")
    self._Config.Acceleration = Value
    self._Dirty.Acceleration  = true
    return self
end

function PhysicsBuilder.RaycastParams(self: PhysicsBuilder, Value: RaycastParams): PhysicsBuilder
    assert(typeof(Value) == "RaycastParams", "PhysicsBuilder:RaycastParams — expected RaycastParams")
    self._Config.RaycastParams = Value
    self._Dirty.RaycastParams  = true
    return self
end

function PhysicsBuilder.CastFunction(
    self: PhysicsBuilder,
    Value: (Vector3, Vector3, RaycastParams) -> RaycastResult?
): PhysicsBuilder
    assert(type(Value) == "function", "PhysicsBuilder:CastFunction — expected function")
    self._Config.CastFunction = Value
    self._Dirty.CastFunction  = true
    return self
end

function PhysicsBuilder.BulletMass(self: PhysicsBuilder, Value: number): PhysicsBuilder
    assert(t.number(Value), "PhysicsBuilder:BulletMass — expected number")
    self._Config.BulletMass = Value
    self._Dirty.BulletMass  = true
    return self
end

function PhysicsBuilder.Done(self: PhysicsBuilder): Types.BehaviorBuilder
    return self._Root
end

return PhysicsBuilder
