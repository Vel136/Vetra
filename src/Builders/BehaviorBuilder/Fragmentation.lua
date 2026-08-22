--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local FragmentationBuilder = {}
FragmentationBuilder.__index = FragmentationBuilder

export type FragmentationBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, FragmentationBuilder))

function FragmentationBuilder.OnPierce(self: FragmentationBuilder, Value: boolean): FragmentationBuilder
    assert(type(Value) == "boolean", "FragmentationBuilder:OnPierce — expected boolean")
    self._Config.FragmentOnPierce = Value
    self._Dirty.FragmentOnPierce  = true
    return self
end

function FragmentationBuilder.Count(self: FragmentationBuilder, Value: number): FragmentationBuilder
    assert(t.number(Value), "FragmentationBuilder:Count — expected number")
    self._Config.FragmentCount = Value
    self._Dirty.FragmentCount  = true
    return self
end

function FragmentationBuilder.Deviation(self: FragmentationBuilder, Value: number): FragmentationBuilder
    assert(t.number(Value), "FragmentationBuilder:Deviation — expected number")
    self._Config.FragmentDeviation = Value
    self._Dirty.FragmentDeviation  = true
    return self
end

function FragmentationBuilder.Done(self: FragmentationBuilder): Types.BehaviorBuilder
    return self._Root
end

return FragmentationBuilder
