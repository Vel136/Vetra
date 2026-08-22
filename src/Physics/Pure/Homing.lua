--!strict
--!optimize 2
--!native

local PureHoming  = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

local math_rad   = math.rad
local math_clamp = math.clamp
local math_acos  = math.acos
local math_cos   = math.cos
local math_sin   = math.sin
local math_min   = math.min

local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MIN_ANGLE_RAD    = Constants.MIN_ANGLE_RAD

local function PositionAt(
	ElapsedTime:     number,
	Origin:          Vector3,
	InitialVelocity: Vector3,
	Acceleration:    Vector3
): Vector3
	return Origin + InitialVelocity * ElapsedTime + Acceleration * (ElapsedTime * ElapsedTime * 0.5)
end

function PureHoming.Step(
	HomingDisengaged           : boolean,
	HomingTarget               : Vector3?,
	HomingElapsed              : number,
	HomingMaxDuration          : number,
	HomingStrength             : number,
	CurrentVelocity            : Vector3,
	CurrentPosition            : Vector3,
	Delta                      : number,
	TrajectoryOrigin           : Vector3,
	TrajectoryInitialVelocity  : Vector3,
	TrajectoryAcceleration     : Vector3,
	TrajectoryStartTime        : number,
	TotalRuntime               : number
): (Vector3, boolean, { Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3, StartTime: number }?, number, boolean)

	if HomingDisengaged then
		return CurrentVelocity, false, nil, HomingElapsed, true
	end

	if not HomingTarget then
		return CurrentVelocity, false, nil, HomingElapsed, HomingDisengaged
	end

	local NewHomingElapsed = HomingElapsed + Delta

	if HomingMaxDuration > 0 and NewHomingElapsed >= HomingMaxDuration then
		return CurrentVelocity, false, nil, NewHomingElapsed, true
	end

	local ToTarget = HomingTarget - CurrentPosition
	if ToTarget:Dot(ToTarget) < 1e-8 then
		return CurrentVelocity, false, nil, NewHomingElapsed, HomingDisengaged
	end

	local TargetDirection = ToTarget.Unit
	local Speed           = CurrentVelocity.Magnitude
	local CurrentDir      = (CurrentVelocity:Dot(CurrentVelocity) > MIN_MAGNITUDE_SQ)
		and CurrentVelocity.Unit
		or TargetDirection

	local MaxTurnRadians = math_rad(HomingStrength) * Delta
	local DotProduct     = math_clamp(CurrentDir:Dot(TargetDirection), -1, 1)
	local AngleToTarget  = math_acos(DotProduct)
	local TurnAmount     = math_min(AngleToTarget, MaxTurnRadians)

	local NewDirection: Vector3
	if AngleToTarget < MIN_ANGLE_RAD then
		NewDirection = TargetDirection
	else
		local RotationAxis = CurrentDir:Cross(TargetDirection)
		if RotationAxis:Dot(RotationAxis) < MIN_MAGNITUDE_SQ then
			NewDirection = TargetDirection
		else
			RotationAxis = RotationAxis.Unit
			local CosAngle = math_cos(TurnAmount)
			local SinAngle = math_sin(TurnAmount)
			NewDirection   = (
				CurrentDir * CosAngle
					+ RotationAxis:Cross(CurrentDir) * SinAngle
					+ RotationAxis * (RotationAxis:Dot(CurrentDir)) * (1 - CosAngle)
			).Unit
		end
	end

	local NewVelocity = NewDirection * Speed
	local Elapsed     = TotalRuntime - TrajectoryStartTime
	local NewOrigin   = PositionAt(Elapsed, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)

	local NewTrajectory = {
		Origin          = NewOrigin,
		InitialVelocity = NewVelocity,
		Acceleration    = TrajectoryAcceleration,
		StartTime       = TotalRuntime,
	}

	return NewVelocity, true, NewTrajectory, NewHomingElapsed, HomingDisengaged
end

return table.freeze(PureHoming)
