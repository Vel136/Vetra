--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior  = Types.BuiltBehavior
type HomingFilter   = Types.HomingFilter
type HomingProvider = Types.HomingProvider

local HomingBuilder = {}
HomingBuilder.__index = HomingBuilder

export type HomingBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, HomingBuilder))

-- Gate callback — return false to disengage homing and fire OnHomingDisengaged.
function HomingBuilder.Filter(self: HomingBuilder, Callback: HomingFilter): HomingBuilder
    assert(type(Callback) == "function", "HomingBuilder:Filter — expected function")
    self._Config.CanHomeFunction = Callback
    return self
end

-- Called every frame for target position. Return nil to disengage.
function HomingBuilder.PositionProvider(self: HomingBuilder, Callback: HomingProvider): HomingBuilder
    assert(type(Callback) == "function", "HomingBuilder:PositionProvider — expected function")
    self._Config.HomingPositionProvider = Callback
    return self
end

-- Steering force in degrees per second.
function HomingBuilder.Strength(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:Strength — expected number")
    self._Config.HomingStrength = Value
    return self
end

-- Max seconds of active homing before OnHomingDisengaged fires.
function HomingBuilder.MaxDuration(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:MaxDuration — expected number")
    self._Config.HomingMaxDuration = Value
    return self
end

-- Min target distance in studs to engage. 0 = engage immediately on fire.
function HomingBuilder.AcquisitionRadius(self: HomingBuilder, Value: number): HomingBuilder
    assert(t.number(Value), "HomingBuilder:AcquisitionRadius — expected number")
    self._Config.HomingAcquisitionRadius = Value
    return self
end

function HomingBuilder.Done(self: HomingBuilder): any
    return self._Root
end

return HomingBuilder
