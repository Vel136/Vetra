--!native
--!optimize 2
--!strict

-- ─── Kinematics ──────────────────────────────────────────────────────────────
--[[
    Analytic kinematic helpers — position/velocity at time, trajectory mutation.
]]

local Identity   = "Kinematics"
local Kinematics = {}
Kinematics.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_abs     = math.abs
local math_huge    = math.huge
local table_insert = table.insert

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local function IsFiniteVector3(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math_abs(v.X) ~= math_huge
		and math_abs(v.Y) ~= math_huge
		and math_abs(v.Z) ~= math_huge
end

-- ─── Module ──────────────────────────────────────────────────────────────────

function Kinematics.PositionAtTime(
	ElapsedTime     : number,
	Origin          : Vector3,
	InitialVelocity : Vector3,
	Acceleration    : Vector3
): Vector3
	return Origin + InitialVelocity * ElapsedTime + Acceleration * (ElapsedTime ^ 2 / 2)
end

function Kinematics.VelocityAtTime(
	ElapsedTime     : number,
	InitialVelocity : Vector3,
	Acceleration    : Vector3
): Vector3
	return InitialVelocity + Acceleration * ElapsedTime
end

function Kinematics.ModifyTrajectory(Cast: any, Velocity: Vector3?, Acceleration: Vector3?, Position: Vector3?)
	if Velocity     and not IsFiniteVector3(Velocity)     then return end
	if Acceleration and not IsFiniteVector3(Acceleration) then return end
	if Position     and not IsFiniteVector3(Position)     then return end

	local Runtime = Cast.Runtime
	local Last    = Runtime.ActiveTrajectory

	if Last.StartTime == Runtime.TotalRuntime then
		Last.Origin          = Position     or Last.Origin
		Last.InitialVelocity = Velocity     or Last.InitialVelocity
		Last.Acceleration    = Acceleration or Last.Acceleration
	else
		Last.EndTime = Runtime.TotalRuntime

		local Elapsed  = Runtime.TotalRuntime - Last.StartTime
		local EndPos   = Kinematics.PositionAtTime(Elapsed, Last.Origin, Last.InitialVelocity, Last.Acceleration)
		local EndVel   = Kinematics.VelocityAtTime(Elapsed, Last.InitialVelocity, Last.Acceleration)
		local NewAccel = Acceleration or Last.Acceleration

		local NewTrajectory = {
			StartTime       = Runtime.TotalRuntime,
			EndTime         = -1,
			Origin          = Position or EndPos,
			InitialVelocity = Velocity or EndVel,
			Acceleration    = NewAccel,
			IsSampled       = false,
			SampledFn       = nil,
		}

		table_insert(Runtime.Trajectories, NewTrajectory)
		Runtime.ActiveTrajectory   = NewTrajectory
		Runtime.CancelResimulation = true
	end
end

function Kinematics.OpenFreshSegment(Cast: any, Origin: Vector3, Velocity: Vector3, Acceleration: Vector3)
	if not IsFiniteVector3(Origin)       then return nil end
	if not IsFiniteVector3(Velocity)     then return nil end
	if not IsFiniteVector3(Acceleration) then return nil end

	local Runtime = Cast.Runtime
	local Last    = Runtime.ActiveTrajectory
	Last.EndTime  = Runtime.TotalRuntime

	local NewTrajectory = {
		StartTime       = Runtime.TotalRuntime,
		EndTime         = -1,
		Origin          = Origin,
		InitialVelocity = Velocity,
		Acceleration    = Acceleration,
		IsSampled       = false,
		SampledFn       = nil,
	}

	table_insert(Runtime.Trajectories, NewTrajectory)
	Runtime.ActiveTrajectory   = NewTrajectory
	Runtime.CancelResimulation = true

	return NewTrajectory
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local KinematicsMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Kinematics: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Kinematics: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Kinematics, KinematicsMetatable)