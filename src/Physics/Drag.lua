--!strict
--!optimize 2
--!native

local Drag     = {}

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

local Constants  = require(Core.Constants)
local Kinematics    = require(Physics.Kinematics)
local PureDrag      = require(Physics.Pure.Drag)
local PureGyroDrift = require(Physics.Pure.GyroDrift)

local ZERO_VECTOR    = Constants.ZERO_VECTOR
local PositionAtTime = Kinematics.PositionAtTime

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

return table.freeze(Drag)
