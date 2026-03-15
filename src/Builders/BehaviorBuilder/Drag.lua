--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type DragModel     = Types.DragModel

local IsValidDragModel = Types.IsValidDragModel

local DragBuilder = {}
DragBuilder.__index = DragBuilder

export type DragBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
}, DragBuilder))

-- Drag coefficient. 0 = no drag.
function DragBuilder.Coefficient(self: DragBuilder, Value: number): DragBuilder
    assert(t.number(Value), "DragBuilder:Coefficient — expected number")
    self._Config.DragCoefficient = Value
    return self
end

-- Use BehaviorBuilder.DragModel.G7 etc. rather than raw strings.
function DragBuilder.Model(self: DragBuilder, Value: DragModel): DragBuilder
    assert(
        type(Value) == "string" and IsValidDragModel(Value),
        "DragBuilder:Model — expected a BehaviorBuilder.DragModel enum value (e.g. BehaviorBuilder.DragModel.G7)"
    )
    self._Config.DragModel = Value
    return self
end

-- Seconds between drag + Magnus recalculation steps.
function DragBuilder.SegmentInterval(self: DragBuilder, Value: number): DragBuilder
    assert(t.number(Value), "DragBuilder:SegmentInterval — expected number")
    self._Config.DragSegmentInterval = Value
    return self
end

-- Required when DragModel = BehaviorBuilder.DragModel.Custom.
-- Table of {mach, cd} pairs, sorted ascending by Mach number.
function DragBuilder.CustomMachTable(self: DragBuilder, Value: { { number } }): DragBuilder
    assert(type(Value) == "table", "DragBuilder:CustomMachTable — expected table of {mach, cd} pairs")
    self._Config.CustomMachTable = Value
    return self
end

function DragBuilder.Done(self: DragBuilder): any
    return self._Root
end

return DragBuilder
