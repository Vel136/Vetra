--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Parent.Parent.Core.Enums)

type BuiltBehavior = Types.BuiltBehavior
type DirtySet      = Types.DirtySet
type DragModel     = Types.DragModel

local function IsValidDragModel(Value: any): boolean
    if type(Value) ~= "number" then return false end
    for _, v in Enums.DragModel do
        if v == Value then return true end
    end
    return false
end

local DragBuilder = {}
DragBuilder.__index = DragBuilder

export type DragBuilder = typeof(setmetatable({} :: {
    _Root   : any,
    _Config : BuiltBehavior,
    _Dirty  : DirtySet,
}, DragBuilder))

function DragBuilder.Coefficient(self: DragBuilder, Value: number): DragBuilder
    assert(t.number(Value), "DragBuilder:Coefficient — expected number")
    self._Config.DragCoefficient = Value
    self._Dirty.DragCoefficient  = true
    return self
end

function DragBuilder.Model(self: DragBuilder, Value: DragModel): DragBuilder
    assert(
        IsValidDragModel(Value),
        "DragBuilder:Model — expected a BehaviorBuilder.DragModel enum value (e.g. BehaviorBuilder.DragModel.G7)"
    )
    self._Config.DragModel = Value
    self._Dirty.DragModel  = true
    return self
end

function DragBuilder.SegmentInterval(self: DragBuilder, Value: number): DragBuilder
    assert(t.number(Value), "DragBuilder:SegmentInterval — expected number")
    self._Config.DragSegmentInterval = Value
    self._Dirty.DragSegmentInterval  = true
    return self
end

function DragBuilder.CustomMachTable(self: DragBuilder, Value: { { number } }): DragBuilder
    assert(type(Value) == "table", "DragBuilder:CustomMachTable — expected table of {mach, cd} pairs")
    self._Config.CustomMachTable = Value
    self._Dirty.CustomMachTable  = true
    return self
end

function DragBuilder.Done(self: DragBuilder): any
    return self._Root
end

return DragBuilder