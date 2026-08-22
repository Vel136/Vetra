--!strict
--!optimize 2
--!native

local Magnus   = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local Constants  = require(Core.Constants)
local PureMagnus = require(script.Parent.Pure.Magnus)

local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

function Magnus.ComputeForce(
	SpinVector        : Vector3,
	Velocity          : Vector3,
	MagnusCoefficient : number
): Vector3
	return PureMagnus.ComputeForce(SpinVector, Velocity, MagnusCoefficient)
end

function Magnus.StepSpinDecay(Behavior: any, Delta: number)
	local DecayRate = Behavior.SpinDecayRate
	if not DecayRate or DecayRate <= 0 then return end
	Behavior.SpinVector = PureMagnus.ApplySpinDecay(Behavior.SpinVector, DecayRate, Delta)
end

function Magnus.IsActive(Behavior: any): boolean
	return Behavior.MagnusCoefficient ~= nil
		and Behavior.MagnusCoefficient > 0
		and Behavior.SpinVector ~= nil
		and Behavior.SpinVector:Dot(Behavior.SpinVector) > MIN_MAGNITUDE_SQ
end

return table.freeze(Magnus)
