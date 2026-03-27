--!native
--!optimize 2
--!strict

-- ─── DragRecalc ──────────────────────────────────────────────────────────────
--[[
    Combined drag + Magnus recalculation step.

    Returns whether a recalculation occurred and the new trajectory segment
    parameters. Both Step and StepHighFidelity call this so the two paths
    cannot silently diverge in drag / magnus / wind / gyro handling.

    LastDragRecalcTime is passed explicitly because StepHighFidelity tracks it
    as a mutable local across sub-segments rather than reading Snapshot each time.
]]

local Identity   = "DragRecalc"
local DragRecalc = {}
DragRecalc.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent.Parent
local Core    = Vetra.Core
local Physics = Vetra.Physics
local Pure    = Physics.Pure

-- ─── Module References ───────────────────────────────────────────────────────

local Constants      = require(Core.Constants)
local TypeDefinition = require(Core.TypeDefinition)
local Kinematics     = require(Physics.Kinematics)
local PureDrag       = require(Pure.Drag)
local PureMagnus     = require(Pure.Magnus)
local PureGyroDrift  = require(Pure.GyroDrift)
local PureTumble     = require(Pure.Tumble)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

-- ─── Types ───────────────────────────────────────────────────────────────────

type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Computes new acceleration (and spin vector) when drag/magnus needs to be
    re-evaluated.

    Returns: Recalculated, NewAcceleration, DragOrigin, DragVelocity, NewSpinVector
]]
function DragRecalc.Step(
	Snapshot           : CastSnapshot,
	TotalRuntime       : number,
	LastDragRecalcTime : number,
	Trajectory         : TrajectorySegment,
	SpinVector         : Vector3
): (boolean, Vector3, Vector3, Vector3, Vector3)

	local HasDrag   = Snapshot.DragCoefficient > 0
	local HasMagnus = Snapshot.MagnusCoefficient ~= 0
		and SpinVector:Dot(SpinVector) > MIN_MAGNITUDE_SQ

	if not (HasDrag or HasMagnus) then
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

	if HasDrag then
		local Coeff, Model = PureDrag.GetEffectiveDragParameters(
			Snapshot.IsSupersonic,
			Snapshot.SupersonicDragCoefficient, Snapshot.SupersonicDragModel,
			Snapshot.SubsonicDragCoefficient,   Snapshot.SubsonicDragModel,
			Snapshot.DragCoefficient,           Snapshot.DragModel
		)
		local TumbleMult = PureTumble.GetDragMultiplier(Snapshot.IsTumbling, Snapshot.TumbleDragMultiplier)
		NewAcceleration += PureDrag.ComputeDragDeceleration(DragVelocity, Coeff * TumbleMult, Model, Snapshot.CustomMachTable)
	end

	if HasMagnus then
		NewSpinVector   = PureMagnus.ApplySpinDecay(SpinVector, Snapshot.SpinDecayRate, Snapshot.DragSegmentInterval)
		NewAcceleration += PureMagnus.ComputeForce(NewSpinVector, DragVelocity, Snapshot.MagnusCoefficient)
	end

	-- Wind and GyroDrift applied once after both force branches so neither
	-- can accidentally omit them.
	if Snapshot.Wind:Dot(Snapshot.Wind) > MIN_MAGNITUDE_SQ then
		NewAcceleration += Snapshot.Wind * Snapshot.WindResponse
	end

	if Snapshot.GyroDriftRate then
		NewAcceleration += PureGyroDrift.ComputeForce(DragVelocity, Snapshot.GyroDriftRate, Snapshot.GyroDriftAxis)
	end

	-- Tumble lateral force — seeded PRNG advances once per interval.
	-- TumbleRandom lives on the snapshot so both serial and parallel paths
	-- share the same Random instance and advance in lockstep.
	if Snapshot.IsTumbling then
		NewAcceleration += PureTumble.StepLateralForce(
			DragVelocity,
			Snapshot.TumbleLateralStrength,
			Snapshot.TumbleRandom
		)
	end

	return true, NewAcceleration, DragOrigin, DragVelocity, NewSpinVector
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(DragRecalc)