--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local SixDOFBuilder = {}
SixDOFBuilder.__index = SixDOFBuilder

export type SixDOFBuilder = typeof(setmetatable({} :: {
	_Root   : Types.BehaviorBuilder,
	_Config : BuiltBehavior,
}, SixDOFBuilder))

function SixDOFBuilder.Enabled(self: SixDOFBuilder, Value: boolean): SixDOFBuilder
	assert(type(Value) == "boolean", "SixDOFBuilder:Enabled — expected boolean")
	self._Config.SixDOFEnabled = Value
	self._Dirty.SixDOFEnabled  = true
	return self
end

function SixDOFBuilder.LiftCoefficientSlope(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:LiftCoefficientSlope — expected number")
	self._Config.LiftCoefficientSlope = Value
	self._Dirty.LiftCoefficientSlope  = true
	return self
end

function SixDOFBuilder.PitchingMomentSlope(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:PitchingMomentSlope — expected number")
	self._Config.PitchingMomentSlope = Value
	self._Dirty.PitchingMomentSlope  = true
	return self
end

function SixDOFBuilder.PitchDampingCoeff(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:PitchDampingCoeff — expected number")
	self._Config.PitchDampingCoeff = Value
	self._Dirty.PitchDampingCoeff  = true
	return self
end

function SixDOFBuilder.RollDampingCoeff(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:RollDampingCoeff — expected number")
	self._Config.RollDampingCoeff = Value
	self._Dirty.RollDampingCoeff  = true
	return self
end

function SixDOFBuilder.AoADragFactor(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:AoADragFactor — expected number")
	self._Config.AoADragFactor = Value
	self._Dirty.AoADragFactor  = true
	return self
end

function SixDOFBuilder.ReferenceArea(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:ReferenceArea — expected number")
	self._Config.ReferenceArea = Value
	self._Dirty.ReferenceArea  = true
	return self
end

function SixDOFBuilder.ReferenceLength(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:ReferenceLength — expected number")
	self._Config.ReferenceLength = Value
	self._Dirty.ReferenceLength  = true
	return self
end

function SixDOFBuilder.AirDensity(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:AirDensity — expected number")
	self._Config.AirDensity = Value
	self._Dirty.AirDensity  = true
	return self
end

function SixDOFBuilder.MomentOfInertia(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:MomentOfInertia — expected number")
	self._Config.MomentOfInertia = Value
	self._Dirty.MomentOfInertia  = true
	return self
end

function SixDOFBuilder.SpinMOI(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:SpinMOI — expected number")
	self._Config.SpinMOI = Value
	self._Dirty.SpinMOI  = true
	return self
end

function SixDOFBuilder.MaxAngularSpeed(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:MaxAngularSpeed — expected number")
	self._Config.MaxAngularSpeed = Value
	self._Dirty.MaxAngularSpeed  = true
	return self
end

function SixDOFBuilder.InitialOrientation(self: SixDOFBuilder, Value: CFrame?): SixDOFBuilder
	assert(Value == nil or typeof(Value) == "CFrame", "SixDOFBuilder:InitialOrientation — expected CFrame or nil")
	self._Config.InitialOrientation = Value
	self._Dirty.InitialOrientation  = true
	return self
end

function SixDOFBuilder.InitialAngularVelocity(self: SixDOFBuilder, Value: Vector3?): SixDOFBuilder
	assert(Value == nil or t.Vector3(Value), "SixDOFBuilder:InitialAngularVelocity — expected Vector3 or nil")
	self._Config.InitialAngularVelocity = Value
	self._Dirty.InitialAngularVelocity  = true
	return self
end


function SixDOFBuilder.CLAlphaMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CLAlphaMachTable — expected table")
	self._Config.CLAlphaMachTable = Value
	self._Dirty.CLAlphaMachTable  = true
	return self
end

function SixDOFBuilder.CmAlphaMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CmAlphaMachTable — expected table")
	self._Config.CmAlphaMachTable = Value
	self._Dirty.CmAlphaMachTable  = true
	return self
end


function SixDOFBuilder.CmqMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CmqMachTable — expected table")
	self._Config.CmqMachTable = Value
	self._Dirty.CmqMachTable  = true
	return self
end


function SixDOFBuilder.ClpMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:ClpMachTable — expected table")
	self._Config.ClpMachTable = Value
	self._Dirty.ClpMachTable  = true
	return self
end

function SixDOFBuilder.Done(self: SixDOFBuilder): Types.BehaviorBuilder
	return self._Root
end

return SixDOFBuilder
