--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local LODBuilder = {}
LODBuilder.__index = LODBuilder

export type LODBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, LODBuilder))

-- Studs from the LOD origin beyond which this bullet steps at reduced frequency.
-- 0 = always full frequency (LOD disabled for this cast).
function LODBuilder.Distance(self: LODBuilder, Value: number): LODBuilder
    assert(t.number(Value), "LODBuilder:Distance — expected number")
    self._Config.LODDistance = Value
    return self
end

function LODBuilder.Done(self: LODBuilder): any
    return self._Root
end

return LODBuilder
