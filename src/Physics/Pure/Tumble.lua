--!strict
--!optimize 2
--!native

local PureTumble  = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local UP_VECTOR        = Constants.UP_VECTOR
local RIGHT_VECTOR     = Constants.RIGHT_VECTOR

function PureTumble.ShouldBeginFromSpeed(
	Speed                : number,
	TumbleSpeedThreshold : number?
): boolean
	return TumbleSpeedThreshold ~= nil and Speed < TumbleSpeedThreshold
end

function PureTumble.ShouldRecover(
	Speed               : number,
	TumbleRecoverySpeed : number?
): boolean
	return TumbleRecoverySpeed ~= nil and Speed >= TumbleRecoverySpeed
end

function PureTumble.CreateRandom(CastId: number): Random
	return Random.new(CastId)
end

function PureTumble.GetDragMultiplier(
	IsTumbling           : boolean,
	TumbleDragMultiplier : number?
): number
	if not IsTumbling then return 1.0 end
	return TumbleDragMultiplier or 3.0
end

function PureTumble.StepLateralForce(
	Velocity              : Vector3,
	TumbleLateralStrength : number?,
	TumbleRandom          : Random?
): Vector3
	if not TumbleLateralStrength or TumbleLateralStrength == 0 then return ZERO_VECTOR end
	if not TumbleRandom then return ZERO_VECTOR end
	if Velocity:Dot(Velocity) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end

	local VUnit   = Velocity.Unit
	local RefAxis = math.abs(VUnit:Dot(UP_VECTOR)) < Constants.PERPENDICULAR_AXIS_THRESHOLD
		and UP_VECTOR or RIGHT_VECTOR

	local Perp1 = VUnit:Cross(RefAxis).Unit
	local Perp2 = VUnit:Cross(Perp1).Unit

	local Angle  = TumbleRandom:NextNumber(0, math.pi * 2)
	local CosA   = math.cos(Angle)
	local SinA   = math.sin(Angle)

	local LateralDir = Perp1 * CosA + Perp2 * SinA

	return LateralDir * TumbleLateralStrength
end

return table.freeze(PureTumble)
