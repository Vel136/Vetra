--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local FragmentationBuilder = {}
FragmentationBuilder.__index = FragmentationBuilder

export type FragmentationBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, FragmentationBuilder))

-- Enable or disable fragment child bullet spawning on pierce.
function FragmentationBuilder.OnPierce(self: FragmentationBuilder, Value: boolean): FragmentationBuilder
    assert(type(Value) == "boolean", "FragmentationBuilder:OnPierce — expected boolean")
    self._Config.FragmentOnPierce = Value
    return self
end

-- Number of fragment child bullets spawned per pierce.
function FragmentationBuilder.Count(self: FragmentationBuilder, Value: number): FragmentationBuilder
    assert(t.number(Value), "FragmentationBuilder:Count — expected number")
    self._Config.FragmentCount = Value
    return self
end

-- Angular half-angle spread of the fragment cone in degrees. Must be in [0, 180].
function FragmentationBuilder.Deviation(self: FragmentationBuilder, Value: number): FragmentationBuilder
    assert(t.number(Value), "FragmentationBuilder:Deviation — expected number")
    self._Config.FragmentDeviation = Value
    return self
end

function FragmentationBuilder.Done(self: FragmentationBuilder): Types.BehaviorBuilder
    return self._Root
end

return FragmentationBuilder
