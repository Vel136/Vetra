--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local WindBuilder = {}
WindBuilder.__index = WindBuilder

export type WindBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, WindBuilder))

-- Multiplier on the solver's global wind vector (Vetra:SetWind).
-- 1.0 = fully affected, 0.0 = immune.
function WindBuilder.Response(self: WindBuilder, Value: number): WindBuilder
    assert(t.number(Value), "WindBuilder:Response — expected number")
    self._Config.WindResponse = Value
    return self
end

function WindBuilder.Done(self: WindBuilder): Types.BehaviorBuilder
    return self._Root
end

return WindBuilder
