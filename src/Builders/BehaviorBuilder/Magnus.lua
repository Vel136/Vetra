--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local MagnusBuilder = {}
MagnusBuilder.__index = MagnusBuilder

export type MagnusBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, MagnusBuilder))

-- Spin axis x angular velocity in rad/s. Vector3.zero disables Magnus effect.
function MagnusBuilder.SpinVector(self: MagnusBuilder, Value: Vector3): MagnusBuilder
    assert(t.Vector3(Value), "MagnusBuilder:SpinVector — expected Vector3")
    self._Config.SpinVector = Value
    return self
end

-- Magnus lift coefficient. Typical range: 0.00005–0.001.
function MagnusBuilder.Coefficient(self: MagnusBuilder, Value: number): MagnusBuilder
    assert(t.number(Value), "MagnusBuilder:Coefficient — expected number")
    self._Config.MagnusCoefficient = Value
    return self
end

-- Rate at which SpinVector magnitude decreases per second. 0 = no decay.
function MagnusBuilder.SpinDecayRate(self: MagnusBuilder, Value: number): MagnusBuilder
    assert(t.number(Value), "MagnusBuilder:SpinDecayRate — expected number")
    self._Config.SpinDecayRate = Value
    return self
end

function MagnusBuilder.Done(self: MagnusBuilder): any
    return self._Root
end

return MagnusBuilder
