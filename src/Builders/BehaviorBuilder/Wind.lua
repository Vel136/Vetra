--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local WindBuilder = {}
WindBuilder.__index = WindBuilder

export type WindBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, WindBuilder))


function WindBuilder.Response(self: WindBuilder, Value: number): WindBuilder
    assert(t.number(Value), "WindBuilder:Response — expected number")
    self._Config.WindResponse = Value
    self._Dirty.WindResponse  = true
    return self
end

function WindBuilder.Done(self: WindBuilder): Types.BehaviorBuilder
    return self._Root
end

return WindBuilder
