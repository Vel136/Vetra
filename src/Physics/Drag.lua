--!native
--!optimize 2
--!strict

-- ─── Drag ────────────────────────────────────────────────────────────────────
--[[
    Aerodynamic drag and supersonic/subsonic profile switching.
]]

local Identity = "Drag"
local Drag     = {}
Drag.__type    = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)

local Kinematics    = require(Physics.Kinematics)
local PureDrag      = require(Physics.Pure.Drag)
local PureGyroDrift = require(Physics.Pure.GyroDrift)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local ZERO_VECTOR    = Constants.ZERO_VECTOR
local PositionAtTime = Kinematics.PositionAtTime

-- ─── Module ──────────────────────────────────────────────────────────────────

-- Thin delegations — pure math lives in Physics/Pure/Drag.
function Drag.ComputeDragDeceleration(Velocity: Vector3, DragCoefficient: number, DragModel: number, CustomMachTable: { { number } }?): Vector3
	return PureDrag.ComputeDragDeceleration(Velocity, DragCoefficient, DragModel, CustomMachTable)
end

function Drag.ShouldRecalculate(Runtime: any, CurrentTime: number, Interval: number): boolean
	return PureDrag.ShouldRecalculate(Runtime.LastDragRecalculateTime, CurrentTime, Interval)
end

function Drag.GetEffectiveDragCoefficient(Cast: any): (number, number)
	local Behavior = Cast.Behavior
	local Runtime  = Cast.Runtime
	return PureDrag.GetEffectiveDragParameters(
		Runtime.IsSupersonic,
		Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragCoefficient or nil,
		Behavior.SupersonicProfile and Behavior.SupersonicProfile.DragModel       or nil,
		Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragCoefficient   or nil,
		Behavior.SubsonicProfile   and Behavior.SubsonicProfile.DragModel         or nil,
		Behavior.DragCoefficient,
		Behavior.DragModel
	)
end

-- RecalculateSegment is Cast-specific (opens a new trajectory segment via
-- Kinematics) and stays in the wrapper rather than the pure layer.
function Drag.RecalculateSegment(Cast: any, CurrentVelocity: Vector3, BaseAcceleration: Vector3, Wind: Vector3?)
	local Behavior = Cast.Behavior
	local Runtime  = Cast.Runtime

	local EffectiveDragCoefficient, EffectiveDragModel = Drag.GetEffectiveDragCoefficient(Cast)
	local DragAcceleration = PureDrag.ComputeDragDeceleration(CurrentVelocity, EffectiveDragCoefficient, EffectiveDragModel, Behavior.CustomMachTable)

	local WindEffect = (Wind and Behavior.WindResponse > 0) and (Wind * Behavior.WindResponse) or ZERO_VECTOR

	local NewAcceleration = BaseAcceleration + DragAcceleration + WindEffect

	if Behavior.GyroDriftRate then
		NewAcceleration = NewAcceleration + PureGyroDrift.ComputeForce(CurrentVelocity, Behavior.GyroDriftRate, Behavior.GyroDriftAxis)
	end

	local ActiveTrajectory = Runtime.ActiveTrajectory
	local ElapsedTime      = Runtime.TotalRuntime - ActiveTrajectory.StartTime
	local NewOrigin        = PositionAtTime(ElapsedTime, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)

	Kinematics.OpenFreshSegment(Cast, NewOrigin, CurrentVelocity, NewAcceleration)
	Runtime.LastDragRecalculateTime = Runtime.TotalRuntime
end


-- ─── Module Return ───────────────────────────────────────────────────────────

local DragMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Drag: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Drag: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Drag, DragMetatable)