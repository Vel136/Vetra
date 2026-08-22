--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local TumbleBuilder = {}
TumbleBuilder.__index = TumbleBuilder

export type TumbleBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, TumbleBuilder))

function TumbleBuilder.SpeedThreshold(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:SpeedThreshold — expected number")
    self._Config.TumbleSpeedThreshold = Value
    self._Dirty.TumbleSpeedThreshold  = true
    return self
end

function TumbleBuilder.DragMultiplier(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:DragMultiplier — expected number")
    self._Config.TumbleDragMultiplier = Value
    self._Dirty.TumbleDragMultiplier  = true
    return self
end

function TumbleBuilder.LateralStrength(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:LateralStrength — expected number")
    self._Config.TumbleLateralStrength = Value
    self._Dirty.TumbleLateralStrength  = true
    return self
end

function TumbleBuilder.OnPierce(self: TumbleBuilder, Value: boolean): TumbleBuilder
    assert(type(Value) == "boolean", "TumbleBuilder:OnPierce — expected boolean")
    self._Config.TumbleOnPierce = Value
    self._Dirty.TumbleOnPierce  = true
    return self
end

function TumbleBuilder.RecoverySpeed(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:RecoverySpeed — expected number")
    self._Config.TumbleRecoverySpeed = Value
    self._Dirty.TumbleRecoverySpeed  = true
    return self
end

function TumbleBuilder.Done(self: TumbleBuilder): Types.BehaviorBuilder
    return self._Root
end

return TumbleBuilder
