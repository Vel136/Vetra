--!strict
--!optimize 2
--!native

local Tumble   = {}

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

local PureTumble = require(Physics.Pure.Tumble)

function Tumble.IsConfigured(Behavior: any): boolean
	return (Behavior.TumbleSpeedThreshold ~= nil and Behavior.TumbleSpeedThreshold > 0)
		or Behavior.TumbleOnPierce == true
end

function Tumble.CheckRecovery(Cast: any, CurrentSpeed: number): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if not Runtime.IsTumbling then return false end

	if PureTumble.ShouldRecover(CurrentSpeed, Behavior.TumbleRecoverySpeed) then
		Runtime.IsTumbling   = false
		Runtime.TumbleRandom = nil
		return true
	end

	return false
end

function Tumble.CheckSpeedTrigger(Cast: any, CurrentSpeed: number): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.IsTumbling then return false end

	if PureTumble.ShouldBeginFromSpeed(CurrentSpeed, Behavior.TumbleSpeedThreshold) then
		Runtime.IsTumbling    = true
		Runtime.TumbleRandom  = PureTumble.CreateRandom(Cast.Id)
		return true
	end

	return false
end

function Tumble.CheckPierceTrigger(Cast: any): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.IsTumbling then return false end
	if not Behavior.TumbleOnPierce then return false end

	Runtime.IsTumbling   = true
	Runtime.TumbleRandom = PureTumble.CreateRandom(Cast.Id)
	return true
end

function Tumble.GetDragMultiplier(Cast: any): number
	return PureTumble.GetDragMultiplier(Cast.Runtime.IsTumbling, Cast.Behavior.TumbleDragMultiplier)
end

function Tumble.StepLateralForce(Cast: any, CurrentVelocity: Vector3): Vector3
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior
	if not Runtime.IsTumbling then return Vector3.zero end
	return PureTumble.StepLateralForce(
		CurrentVelocity,
		Behavior.TumbleLateralStrength,
		Runtime.TumbleRandom
	)
end

return table.freeze(Tumble)
