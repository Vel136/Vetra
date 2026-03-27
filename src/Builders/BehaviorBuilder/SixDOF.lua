--!native
--!optimize 2
--!strict

local t     = require(script.Parent.Parent.Parent.Core.TypeCheck)
local Types = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior

local SixDOFBuilder = {}
SixDOFBuilder.__index = SixDOFBuilder

export type SixDOFBuilder = typeof(setmetatable({} :: {
	_Root   : any,
	_Config : BuiltBehavior,
}, SixDOFBuilder))

-- Enables or disables the 6DOF aerodynamics system for this cast.
-- When false (the default), no 6DOF code runs and all fields below are ignored.
function SixDOFBuilder.Enabled(self: SixDOFBuilder, Value: boolean): SixDOFBuilder
	assert(type(Value) == "boolean", "SixDOFBuilder:Enabled — expected boolean")
	self._Config.SixDOFEnabled = Value
	return self
end

-- dCL/dα — lift coefficient slope. Scales aerodynamic lift with angle of attack.
-- Typical range: 1.0–4.0. 0 disables lift.
function SixDOFBuilder.LiftCoefficientSlope(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:LiftCoefficientSlope — expected number")
	self._Config.LiftCoefficientSlope = Value
	return self
end

-- dCm/dα — pitching moment slope. Negative = statically stable (restoring torque).
-- Typical range: -1.0 to -0.1. 0 = neutrally stable.
function SixDOFBuilder.PitchingMomentSlope(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:PitchingMomentSlope — expected number")
	self._Config.PitchingMomentSlope = Value
	return self
end

-- Cmq — pitch/yaw damping coefficient. Damps wobble and coning motion.
-- Typical range: 0.005–0.05. 0 = no damping.
function SixDOFBuilder.PitchDampingCoeff(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:PitchDampingCoeff — expected number")
	self._Config.PitchDampingCoeff = Value
	return self
end

-- Clp — roll damping coefficient. Controls how quickly spin rate decays.
-- Typical range: 0.001–0.02. 0 = no spin decay.
function SixDOFBuilder.RollDampingCoeff(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:RollDampingCoeff — expected number")
	self._Config.RollDampingCoeff = Value
	return self
end

-- sin²α drag multiplier. Extra drag at high angles of attack.
-- 3.0 triples drag at 90° AoA. 0 = no AoA-dependent drag.
function SixDOFBuilder.AoADragFactor(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:AoADragFactor — expected number")
	self._Config.AoADragFactor = Value
	return self
end

-- Reference cross-sectional area in studs². Used for all aerodynamic force scaling.
-- Typical value for a rifle bullet: 0.005–0.02.
function SixDOFBuilder.ReferenceArea(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:ReferenceArea — expected number")
	self._Config.ReferenceArea = Value
	return self
end

-- Reference length (caliber) in studs. Used for pitching moment and damping torques.
-- Typical value for a rifle bullet: 0.03–0.1.
function SixDOFBuilder.ReferenceLength(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:ReferenceLength — expected number")
	self._Config.ReferenceLength = Value
	return self
end

-- Air density in kg/m³. Scales all aerodynamic forces.
-- Default: 1.225 (sea level). Use lower values for high-altitude simulation.
function SixDOFBuilder.AirDensity(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:AirDensity — expected number")
	self._Config.AirDensity = Value
	return self
end

-- Transverse moment of inertia. Governs pitch/yaw angular acceleration from torques.
-- Typical value for a rifle bullet: 0.0005–0.005.
function SixDOFBuilder.MomentOfInertia(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:MomentOfInertia — expected number")
	self._Config.MomentOfInertia = Value
	return self
end

-- Axial (spin) moment of inertia. Required for gyroscopic precession.
-- Typical value for a rifle bullet: 0.0001–0.001. 0 disables precession.
function SixDOFBuilder.SpinMOI(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:SpinMOI — expected number")
	self._Config.SpinMOI = Value
	return self
end

-- Angular speed ceiling in rad/s. Prevents divergence under extreme torques.
-- Default: ~628 rad/s (≈6000 RPM).
function SixDOFBuilder.MaxAngularSpeed(self: SixDOFBuilder, Value: number): SixDOFBuilder
	assert(t.number(Value), "SixDOFBuilder:MaxAngularSpeed — expected number")
	self._Config.MaxAngularSpeed = Value
	return self
end

-- Initial body-frame orientation as a CFrame. nil = derived from velocity look-at.
function SixDOFBuilder.InitialOrientation(self: SixDOFBuilder, Value: CFrame?): SixDOFBuilder
	assert(Value == nil or typeof(Value) == "CFrame", "SixDOFBuilder:InitialOrientation — expected CFrame or nil")
	self._Config.InitialOrientation = Value
	return self
end

-- Initial angular velocity in rad/s (world frame). nil = seeded from Magnus SpinVector if set.
function SixDOFBuilder.InitialAngularVelocity(self: SixDOFBuilder, Value: Vector3?): SixDOFBuilder
	assert(Value == nil or t.Vector3(Value), "SixDOFBuilder:InitialAngularVelocity — expected Vector3 or nil")
	self._Config.InitialAngularVelocity = Value
	return self
end

-- Mach-indexed CLα table. Overrides LiftCoefficientSlope when set.
-- Table format: { {mach, cl_alpha}, ... } sorted ascending by Mach number.
function SixDOFBuilder.CLAlphaMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CLAlphaMachTable — expected table")
	self._Config.CLAlphaMachTable = Value
	return self
end

-- Mach-indexed Cmα table. Overrides PitchingMomentSlope when set.
-- Table format: { {mach, cm_alpha}, ... } sorted ascending by Mach number.
function SixDOFBuilder.CmAlphaMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CmAlphaMachTable — expected table")
	self._Config.CmAlphaMachTable = Value
	return self
end

-- Mach-indexed Cmq table. Overrides PitchDampingCoeff when set.
-- Table format: { {mach, cmq}, ... } sorted ascending by Mach number.
function SixDOFBuilder.CmqMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:CmqMachTable — expected table")
	self._Config.CmqMachTable = Value
	return self
end

-- Mach-indexed Clp table. Overrides RollDampingCoeff when set.
-- Table format: { {mach, clp}, ... } sorted ascending by Mach number.
function SixDOFBuilder.ClpMachTable(self: SixDOFBuilder, Value: { { number } }): SixDOFBuilder
	assert(type(Value) == "table", "SixDOFBuilder:ClpMachTable — expected table")
	self._Config.ClpMachTable = Value
	return self
end

function SixDOFBuilder.Done(self: SixDOFBuilder): any
	return self._Root
end

return SixDOFBuilder
