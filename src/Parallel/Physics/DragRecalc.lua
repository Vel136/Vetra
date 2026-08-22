--!native
--!optimize 2
--!strict

local DragRecalc = {}


local Vetra   = script.Parent.Parent.Parent
local Core    = Vetra.Core
local Physics = Vetra.Physics
local Pure    = Physics.Pure

local Constants      = require(Core.Constants)
local TypeDefinition = require(Vetra.Types)
local Kinematics     = require(Physics.Kinematics)
local PureDrag       = require(Pure.Drag)
local PureMagnus     = require(Pure.Magnus)
local PureGyroDrift  = require(Pure.GyroDrift)
local PureTumble     = require(Pure.Tumble)
local SixDOFStep     = require(script.Parent.SixDOFStep)

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot

function DragRecalc.Step(
	Snapshot           : CastSnapshot,
	TotalRuntime       : number,
	LastDragRecalcTime : number,
	Trajectory         : TrajectorySegment,
	SpinVector         : Vector3
): (boolean, Vector3, Vector3, Vector3, Vector3)

	local HasDrag   = Snapshot.DragCoefficient > 0
	local HasMagnus = Snapshot.MagnusCoefficient > 0
		and SpinVector:Dot(SpinVector) > MIN_MAGNITUDE_SQ
	local Has6DOF   = Snapshot.SixDOFEnabled == true

	if not (HasDrag or HasMagnus or Has6DOF) then
		return false, Trajectory.Acceleration, Trajectory.Origin, ZERO_VECTOR, SpinVector
	end
	if not PureDrag.ShouldRecalculate(LastDragRecalcTime, TotalRuntime, Snapshot.DragSegmentInterval) then
		return false, Trajectory.Acceleration, Trajectory.Origin, ZERO_VECTOR, SpinVector
	end

	local Elapsed      = TotalRuntime - Trajectory.StartTime
	local DragVelocity = VelocityAtTime(Elapsed, Trajectory.InitialVelocity, Trajectory.Acceleration)
	local DragOrigin   = PositionAtTime(Elapsed, Trajectory.Origin, Trajectory.InitialVelocity, Trajectory.Acceleration)
	local NewAcceleration = Snapshot.BaseAcceleration
	local NewSpinVector   = SpinVector

	local SixDOFDragMult = 1.0
	if Has6DOF then
		local LiftAccel, DragMult = SixDOFStep.StepAngularState(
			Snapshot, DragVelocity, Snapshot.DragSegmentInterval
		)
		NewAcceleration += LiftAccel
		SixDOFDragMult   = DragMult
	end

	if HasDrag then
		local Coeff, Model = PureDrag.GetEffectiveDragParameters(
			Snapshot.IsSupersonic,
			Snapshot.SupersonicDragCoefficient, Snapshot.SupersonicDragModel,
			Snapshot.SubsonicDragCoefficient,   Snapshot.SubsonicDragModel,
			Snapshot.DragCoefficient,           Snapshot.DragModel
		)
		local TumbleMult = PureTumble.GetDragMultiplier(Snapshot.IsTumbling, Snapshot.TumbleDragMultiplier)
		NewAcceleration += PureDrag.ComputeDragDeceleration(DragVelocity, Coeff * TumbleMult * SixDOFDragMult, Model, Snapshot.CustomMachTable)
	end

	if HasMagnus then
		local MagnusSpin
		if Has6DOF then
			local BodyFwd  = SixDOFStep.GetBodyForward(Snapshot)
			local SpinRate = BodyFwd:Dot(Snapshot.AngularVelocity)
			MagnusSpin     = BodyFwd * SpinRate
		else
			NewSpinVector = PureMagnus.ApplySpinDecay(SpinVector, Snapshot.SpinDecayRate, Snapshot.DragSegmentInterval)
			MagnusSpin    = NewSpinVector
		end
		NewAcceleration += PureMagnus.ComputeForce(MagnusSpin, DragVelocity, Snapshot.MagnusCoefficient)
	end

	if Snapshot.Wind:Dot(Snapshot.Wind) > 0 then
		NewAcceleration += Snapshot.Wind * Snapshot.WindResponse
	end

	if Snapshot.GyroDriftRate then
		NewAcceleration += PureGyroDrift.ComputeForce(DragVelocity, Snapshot.GyroDriftRate, Snapshot.GyroDriftAxis)
	end

	if Snapshot.IsTumbling then
		NewAcceleration += PureTumble.StepLateralForce(
			DragVelocity,
			Snapshot.TumbleLateralStrength,
			Snapshot.TumbleRandom
		)
	end

	return true, NewAcceleration, DragOrigin, DragVelocity, NewSpinVector
end


return table.freeze(DragRecalc)
