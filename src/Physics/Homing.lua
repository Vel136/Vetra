--!strict
--!optimize 2
--!native

local Homing   = {}

local Vetra   = script.Parent.Parent
local Core    = Vetra.Core
local Signals = Vetra.Signals

local Constants   = require(Core.Constants)
local t           = require(Core.TypeCheck)
local FireHelpers = require(Signals.FireHelpers)
local PureHoming  = require(script.Parent.Pure.Homing)

local math_rad   = math.rad
local math_clamp = math.clamp
local math_acos  = math.acos
local math_min   = math.min
local math_cos   = math.cos
local math_sin   = math.sin

local MIN_MAGNITUDE_SQ               = Constants.MIN_MAGNITUDE_SQ
local MIN_HOMING_ARRIVAL_DISTANCE_SQ = Constants.MIN_HOMING_ARRIVAL_DISTANCE_SQ
local MIN_ANGLE_RAD                  = Constants.MIN_ANGLE_RAD

local function IsThreadHanging(Thread: thread?): boolean
	return Thread ~= nil and Thread ~= coroutine.running()
end

local function IsHomingAcquired(Cast: any): boolean
	return Cast.Runtime.HomingAcquired
end

function Homing.IsActive(Cast: any): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.HomingDisengaged then return false end
	if not Behavior.HomingPositionProvider then return false end

	return true
end

function Homing.EvaluateFrameGate(Cast: any, Solver: any, CurrentPosition: Vector3, CurrentVelocity: Vector3)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if not Behavior.CanHomeFunction then
		Runtime.CanHomeThisFrame = true
		return
	end

	if IsThreadHanging(Runtime.CanHomeCallbackThread) then
		Runtime.CanHomeCallbackThread = nil
		Runtime.CanHomeThisFrame      = false
		error("Homing: CanHomeFunction yielded")
		return
	end

	Runtime.CanHomeCallbackThread = coroutine.running()
	local LinkedBulletContext     = Solver._CastToBulletContext[Cast]
	local CanHome                 = Behavior.CanHomeFunction(LinkedBulletContext, CurrentPosition, CurrentVelocity)
	Runtime.CanHomeCallbackThread = nil

	Runtime.CanHomeThisFrame = CanHome == true
end

function Homing.TryAcquire(Cast: any, CurrentPosition: Vector3, CurrentVelocity: Vector3, IsSubSegment: boolean): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior
	if not Behavior.HomingPositionProvider then return false end
	if IsHomingAcquired(Cast) then return true end

	local HasHanging = IsThreadHanging(Runtime.HomingProviderThread)
	if not IsSubSegment and HasHanging then
		Runtime.HomingDisengaged         = true
		Runtime.HomingProviderThread     = nil
		error("Homing: HomingPositionProvider yielded in TryAcquire")
		return false
	end

	Runtime.HomingProviderThread = coroutine.running()
	local TargetPosition = Behavior.HomingPositionProvider(CurrentPosition, CurrentVelocity)
	Runtime.HomingProviderThread = nil
	if not TargetPosition then return false end

	local AcquisitionRadius = Behavior.HomingAcquisitionRadius
	if AcquisitionRadius <= 0 then
		Cast.Runtime.HomingAcquired = true
		return true
	end

	local ToTarget = TargetPosition - CurrentPosition
	if ToTarget:Dot(ToTarget) <= AcquisitionRadius * AcquisitionRadius then
		Cast.Runtime.HomingAcquired = true
		return true
	end

	return false
end

function Homing.StepHoming(
	Cast            : any,
	CurrentVelocity : Vector3,
	CurrentPosition : Vector3,
	Delta           : number,
	Kinematics      : any,
	Solver          : any,
	IsSubSegment    : boolean
): (Vector3, boolean)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.HomingDisengaged then
		return CurrentVelocity, false
	end

	if not Behavior.HomingPositionProvider then
		return CurrentVelocity, false
	end

	if Behavior.CanHomeFunction and not Runtime.CanHomeThisFrame then
		return CurrentVelocity, false
	end


	if not Runtime.HomingAcquired then
		if not Homing.TryAcquire(Cast, CurrentPosition, CurrentVelocity, IsSubSegment) then
			return CurrentVelocity, false
		end
	end

	local HasHanging = IsThreadHanging(Runtime.HomingProviderThread)
	if not IsSubSegment and HasHanging then
		Runtime.HomingDisengaged     = true
		Runtime.HomingProviderThread = nil
		FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		error("Homing: HomingPositionProvider yielded in StepHoming")
		return CurrentVelocity, false
	end

	Runtime.HomingProviderThread = coroutine.running()
	local TargetPosition = Behavior.HomingPositionProvider(CurrentPosition, CurrentVelocity)
	Runtime.HomingProviderThread = nil
	if not TargetPosition then
		Runtime.HomingDisengaged = true
		FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		return CurrentVelocity, false
	end

	local ToTarget = (TargetPosition - CurrentPosition)
	if ToTarget:Dot(ToTarget) < MIN_HOMING_ARRIVAL_DISTANCE_SQ then
		return CurrentVelocity, true
	end

	local ActiveTrajectory = Runtime.ActiveTrajectory
	local NewVelocity, HomingApplied, NewTrajectory, NewElapsed, NewDisengaged = PureHoming.Step(
		false,
		TargetPosition,
		Runtime.HomingElapsed,
		Behavior.HomingMaxDuration,
		Behavior.HomingStrength,
		CurrentVelocity,
		CurrentPosition,
		Delta,
		ActiveTrajectory.Origin,
		ActiveTrajectory.InitialVelocity,
		ActiveTrajectory.Acceleration,
		ActiveTrajectory.StartTime,
		Runtime.TotalRuntime
	)

	Runtime.HomingElapsed = NewElapsed

	if NewDisengaged and not Runtime.HomingDisengaged then
		Runtime.HomingDisengaged = true
		FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		return CurrentVelocity, false
	end

	if HomingApplied and NewTrajectory then
		Kinematics.OpenFreshSegment(
			Cast,
			NewTrajectory.Origin,
			NewTrajectory.InitialVelocity,
			NewTrajectory.Acceleration
		)
	end

	return NewVelocity, HomingApplied
end

return table.freeze(Homing)
