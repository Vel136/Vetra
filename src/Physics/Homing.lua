--!native
--!optimize 2
--!strict

-- ─── Homing ──────────────────────────────────────────────────────────────────
--[[
    Homing guidance — acquisition, turn-rate clamping, and disengagement.
]]

local Identity = "Homing"
local Homing   = {}
Homing.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core
local Signals = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)
local t          = require(Core.TypeCheck)
local FireHelpers = require(Signals.FireHelpers)
local PureHoming  = require(script.Parent.Pure.Homing)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_rad   = math.rad
local math_clamp = math.clamp
local math_acos  = math.acos
local math_min   = math.min
local math_cos   = math.cos
local math_sin   = math.sin

local MIN_MAGNITUDE_SQ               = Constants.MIN_MAGNITUDE_SQ
local MIN_HOMING_ARRIVAL_DISTANCE_SQ = Constants.MIN_HOMING_ARRIVAL_DISTANCE_SQ
local MIN_ANGLE_RAD                  = Constants.MIN_ANGLE_RAD

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local function IsThreadHanging(Thread: thread?): boolean
	return Thread ~= nil and Thread ~= coroutine.running()
end

-- ─── Module ──────────────────────────────────────────────────────────────────

local function IsHomingAcquired(Cast: any): boolean
	return Cast.Runtime.HomingAcquired
end

function Homing.IsActive(Cast: any): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.HomingDisengaged then return false end
	if not Behavior.HomingPositionProvider then return false end
	if Behavior.HomingMaxDuration > 0 and Runtime.HomingElapsed >= Behavior.HomingMaxDuration then
		return false
	end

	return true
end

function Homing.TryAcquire(Cast: any, CurrentPosition: Vector3, CurrentVelocity: Vector3, IsSubSegment: boolean): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior
	if not Behavior.HomingPositionProvider then return false end
	if IsHomingAcquired(Cast) then return true end

	-- Yield guard
	local HasHanging = IsThreadHanging(Runtime.HomingProviderThread)
	if not IsSubSegment and HasHanging then
		Runtime.HomingDisengaged         = true
		Runtime.HomingProviderThread     = nil
		Logger:Error("Homing: HomingPositionProvider yielded in TryAcquire")
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

	-- CanHomeFunction guard — allows consumers to temporarily block homing
	-- without permanently disengaging (unlike HomingDisengaged = true).
	-- Called every step so the consumer can re-enable homing dynamically.
	if Behavior.CanHomeFunction then
		local HasHanging = IsThreadHanging(Runtime.CanHomeCallbackThread)
		if HasHanging then
			Runtime.CanHomeCallbackThread = nil
			Logger:Error("Homing: CanHomeFunction yielded")
			return CurrentVelocity, false
		end
		Runtime.CanHomeCallbackThread = coroutine.running()
		local LinkedBulletContext = Solver._CastToBulletContext[Cast]
		local CanHome = Behavior.CanHomeFunction(LinkedBulletContext, CurrentPosition, CurrentVelocity)
		Runtime.CanHomeCallbackThread = nil
		if not CanHome then
			return CurrentVelocity, false
		end
	end

	if Behavior.HomingMaxDuration > 0 and Runtime.HomingElapsed >= Behavior.HomingMaxDuration then
		Runtime.HomingDisengaged = true
		FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		return CurrentVelocity, false
	end

	if not Runtime.HomingAcquired then
		if not Homing.TryAcquire(Cast, CurrentPosition, CurrentVelocity, IsSubSegment) then
			return CurrentVelocity, false
		end
	end

	-- Yield guard
	local HasHanging = IsThreadHanging(Runtime.HomingProviderThread)
	if not IsSubSegment and HasHanging then
		Runtime.HomingDisengaged     = true
		Runtime.HomingProviderThread = nil
		FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		Logger:Error("Homing: HomingPositionProvider yielded in StepHoming")
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
	
	Runtime.HomingElapsed += Delta
	local ToTarget = (TargetPosition - CurrentPosition)
	if ToTarget:Dot(ToTarget) < MIN_HOMING_ARRIVAL_DISTANCE_SQ then
		return CurrentVelocity, true
	end

	-- Delegate steering math to the pure layer so both serial and parallel
	-- paths share a single Rodrigues-rotation implementation.
	local ActiveTrajectory = Runtime.ActiveTrajectory
	local NewVelocity, HomingApplied, NewTrajectory, _, _ = PureHoming.Step(
		false,                             -- not disengaged (checked above)
		TargetPosition,                    -- already-resolved target
		Runtime.HomingElapsed,             -- already incremented above
		0,                                 -- max duration already checked above
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

-- ─── Module Return ───────────────────────────────────────────────────────────

local HomingMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Homing: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Homing: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Homing, HomingMetatable)