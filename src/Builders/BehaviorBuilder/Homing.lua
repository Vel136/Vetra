--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior  = Types.BuiltBehavior
type HomingFilter   = Types.HomingFilter
type HomingProvider = Types.HomingProvider

local HomingBuilder = {}
HomingBuilder.__index = HomingBuilder

export type HomingBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, HomingBuilder))

function HomingBuilder.Filter(self: HomingBuilder, Callback: HomingFilter): HomingBuilder
    assert(type(Callback) == "function", "HomingBuilder:Filter — expected function")
    self._Config.CanHomeFunction = Callback
    self._Dirty.CanHomeFunction  = true
    return self
end

function HomingBuilder.PositionProvider(self: HomingBuilder, Callback: HomingProvider): HomingBuilder
    assert(type(Callback) == "function", "HomingBuilder:PositionProvider — expected function")
    self._Config.HomingPositionProvider = Callback
    self._Dirty.HomingPositionProvider  = true
    return self
end

function HomingBuilder.Strength(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:Strength — expected number")
    self._Config.HomingStrength = Value
    self._Dirty.HomingStrength  = true
    return self
end

function HomingBuilder.MaxDuration(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:MaxDuration — expected number")
    self._Config.HomingMaxDuration = Value
    self._Dirty.HomingMaxDuration  = true
    return self
end

function HomingBuilder.AcquisitionRadius(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:AcquisitionRadius — expected number")
    self._Config.HomingAcquisitionRadius = Value
    self._Dirty.HomingAcquisitionRadius  = true
    return self
end

function HomingBuilder.Done(self: HomingBuilder): Types.BehaviorBuilder
    return self._Root
end

return HomingBuilder
