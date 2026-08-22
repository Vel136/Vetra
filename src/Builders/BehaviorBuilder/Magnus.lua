--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local MagnusBuilder = {}
MagnusBuilder.__index = MagnusBuilder

export type MagnusBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, MagnusBuilder))

function MagnusBuilder.SpinVector(self: MagnusBuilder, Value: Vector3): MagnusBuilder
    assert(t.Vector3(Value), "MagnusBuilder:SpinVector — expected Vector3")
    self._Config.SpinVector = Value
    self._Dirty.SpinVector  = true
    return self
end

function MagnusBuilder.Coefficient(self: MagnusBuilder, Value: number): MagnusBuilder
    assert(t.number(Value), "MagnusBuilder:Coefficient — expected number")
    self._Config.MagnusCoefficient = Value
    self._Dirty.MagnusCoefficient  = true
    return self
end

function MagnusBuilder.SpinDecayRate(self: MagnusBuilder, Value: number): MagnusBuilder
    assert(t.number(Value), "MagnusBuilder:SpinDecayRate — expected number")
    self._Config.SpinDecayRate = Value
    self._Dirty.SpinDecayRate  = true
    return self
end

function MagnusBuilder.Done(self: MagnusBuilder): Types.BehaviorBuilder
    return self._Root
end

return MagnusBuilder
