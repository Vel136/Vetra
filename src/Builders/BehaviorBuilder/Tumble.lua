--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local TumbleBuilder = {}
TumbleBuilder.__index = TumbleBuilder

export type TumbleBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, TumbleBuilder))

-- Speed (studs/s) below which tumbling begins. Setting this enables tumble.
function TumbleBuilder.SpeedThreshold(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:SpeedThreshold — expected number")
    self._Config.TumbleSpeedThreshold = Value
    return self
end

-- Drag multiplied by this factor while tumbling. Must be >= 1.
function TumbleBuilder.DragMultiplier(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:DragMultiplier — expected number")
    self._Config.TumbleDragMultiplier = Value
    return self
end

-- Chaotic lateral acceleration magnitude in studs/s² applied while tumbling.
function TumbleBuilder.LateralStrength(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:LateralStrength — expected number")
    self._Config.TumbleLateralStrength = Value
    return self
end

-- If true, bullet begins tumbling on first pierce regardless of speed.
function TumbleBuilder.OnPierce(self: TumbleBuilder, Value: boolean): TumbleBuilder
    assert(type(Value) == "boolean", "TumbleBuilder:OnPierce — expected boolean")
    self._Config.TumbleOnPierce = Value
    return self
end

-- Speed above which tumbling ends. nil = permanent once triggered.
-- Must be > SpeedThreshold — :Build() enforces this.
function TumbleBuilder.RecoverySpeed(self: TumbleBuilder, Value: number): TumbleBuilder
    assert(t.number(Value), "TumbleBuilder:RecoverySpeed — expected number")
    self._Config.TumbleRecoverySpeed = Value
    return self
end

function TumbleBuilder.Done(self: TumbleBuilder): any
    return self._Root
end

return TumbleBuilder
