--!strict
--!optimize 2
--!native

local PureGyroDrift  = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local UP_VECTOR        = Constants.UP_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

function PureGyroDrift.ComputeForce(
	Velocity      : Vector3,
	DriftRate     : number,
	ReferenceAxis : Vector3?
): Vector3
	local SpeedSq = Velocity:Dot(Velocity)
	if SpeedSq < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	if DriftRate == 0 then return ZERO_VECTOR end

	local Axis    = ReferenceAxis or UP_VECTOR
	local DriftDir = Axis:Cross(Velocity.Unit)

	if DriftDir:Dot(DriftDir) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end

	return DriftDir.Unit * (DriftRate * SpeedSq ^ 0.5)
end

return table.freeze(PureGyroDrift)
