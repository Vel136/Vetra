--!strict
--!optimize 2
--!native

local PureMagnus   = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

local math_clamp = math.clamp

local ZERO_VECTOR        = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ   = Constants.MIN_MAGNITUDE_SQ
local MIN_SPIN_MAGNITUDE = Constants.MIN_SPIN_MAGNITUDE

function PureMagnus.ComputeForce(
	SpinVector        : Vector3,
	Velocity          : Vector3,
	MagnusCoefficient : number
): Vector3
	if SpinVector:Dot(SpinVector) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	if Velocity:Dot(Velocity)     < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	return SpinVector:Cross(Velocity) * MagnusCoefficient
end

function PureMagnus.ApplySpinDecay(
	SpinVector : Vector3,
	DecayRate  : number,
	Delta      : number
): Vector3
	if DecayRate <= 0 then return SpinVector end
	if SpinVector:Dot(SpinVector) < MIN_MAGNITUDE_SQ then return SpinVector end

	local Factor  = 1 - math_clamp(DecayRate * Delta, 0, 1)
	local NewSpin = SpinVector * Factor

	if NewSpin.Magnitude < MIN_SPIN_MAGNITUDE then
		return ZERO_VECTOR
	end
	return NewSpin
end

return table.freeze(PureMagnus)
