--!strict
--!optimize 2
--!native

local GyroDrift  = {}

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

local PureGyroDrift = require(Physics.Pure.GyroDrift)

function GyroDrift.ComputeForce(
	Velocity      : Vector3,
	DriftRate     : number,
	ReferenceAxis : Vector3?
): Vector3
	return PureGyroDrift.ComputeForce(Velocity, DriftRate, ReferenceAxis)
end

function GyroDrift.IsActive(Behavior: any): boolean
	return Behavior.GyroDriftRate ~= nil and Behavior.GyroDriftRate ~= 0
end

return table.freeze(GyroDrift)
