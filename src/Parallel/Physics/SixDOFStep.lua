--!strict
--!optimize 2
--!native


local SixDOFStep = {}

local ParallelPhysicsFolder = script.Parent
local Vetra                 = ParallelPhysicsFolder.Parent.Parent
local Core                  = Vetra.Core
local Physics               = Vetra.Physics
local Pure                  = Physics.Pure

local Constants  = require(Core.Constants)
local PureSixDOF = require(Pure.SixDOF)

local SPEED_OF_SOUND  = Constants.SPEED_OF_SOUND
local LerpMachTable   = Constants.MACH_TABLES.Lerp
local ANGULAR_SUBSTEP = Constants.ANGULAR_SUBSTEP

local function Resolve(Table: { { number } }?, Mach: number, Scalar: number): number
	if Table then return LerpMachTable(Table, Mach) end
	return Scalar
end

function SixDOFStep.StepAngularState(State: any, Velocity: Vector3, Delta: number): (Vector3, number)
	local Mach    = Velocity.Magnitude / SPEED_OF_SOUND
	local CLSlope = Resolve(State.CLAlphaMachTable, Mach, State.LiftCoefficientSlope)
	local CmSlope = Resolve(State.CmAlphaMachTable, Mach, State.PitchingMomentSlope)
	local CmqCoef = Resolve(State.CmqMachTable,     Mach, State.PitchDampingCoeff)
	local ClpCoef = Resolve(State.ClpMachTable,     Mach, State.RollDampingCoeff)

	local AoADragFactor = State.AoADragFactor
	local ReferenceArea = State.ReferenceArea
	local ReferenceLen  = State.ReferenceLength
	local AirDensity    = State.AirDensity
	local MOI           = State.MomentOfInertia
	local SpinMOI       = State.SpinMOI
	local MaxAngSpeed   = State.MaxAngularSpeed
	local BulletMass    = State.BulletMass

	State.SixDOFAccumulator = (State.SixDOFAccumulator or 0) + Delta

	local AccumLiftAccel = Vector3.zero
	local AccumDragMult  = 0
	local SubStepCount   = 0

	while State.SixDOFAccumulator >= ANGULAR_SUBSTEP do
		local NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA = PureSixDOF.Step(
			State.Orientation,
			State.AngularVelocity,
			Velocity,
			ANGULAR_SUBSTEP,
			CLSlope, CmSlope, CmqCoef, ClpCoef,
			AoADragFactor, ReferenceArea, ReferenceLen,
			AirDensity, MOI, SpinMOI, MaxAngSpeed, BulletMass
		)

		State.Orientation     = NewOrientation
		State.AngularVelocity = NewAngularVelocity
		State.AngleOfAttack   = AoA

		AccumLiftAccel += LiftAccel
		AccumDragMult  += DragMult
		SubStepCount   += 1

		State.SixDOFAccumulator -= ANGULAR_SUBSTEP
	end

	if SubStepCount == 0 then
		local NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA = PureSixDOF.Step(
			State.Orientation,
			State.AngularVelocity,
			Velocity,
			Delta,
			CLSlope, CmSlope, CmqCoef, ClpCoef,
			AoADragFactor, ReferenceArea, ReferenceLen,
			AirDensity, MOI, SpinMOI, MaxAngSpeed, BulletMass
		)
		State.Orientation     = NewOrientation
		State.AngularVelocity = NewAngularVelocity
		State.AngleOfAttack   = AoA
		return LiftAccel, DragMult
	end

	local InvCount = 1 / SubStepCount
	return AccumLiftAccel * InvCount, AccumDragMult * InvCount
end

function SixDOFStep.OnBounce(State: any, SurfaceNormal: Vector3, PostBounceVel: Vector3, Restitution: number)
	local Orientation = State.Orientation
	if not Orientation then return end

	local BodyForward = PureSixDOF.GetBodyForward(Orientation)
	local ReflectedForward = BodyForward - 2 * BodyForward:Dot(SurfaceNormal) * SurfaceNormal

	local VelMagSq = PostBounceVel:Dot(PostBounceVel)
	local UpHint
	if VelMagSq > 1e-6 then
		local Lateral = ReflectedForward:Cross(PostBounceVel.Unit)
		if Lateral:Dot(Lateral) > 1e-12 then
			UpHint = Lateral:Cross(ReflectedForward).Unit
		else
			UpHint = Vector3.new(0, 1, 0)
		end
	else
		UpHint = Vector3.new(0, 1, 0)
	end

	State.Orientation = CFrame.lookAt(Vector3.zero, ReflectedForward, UpHint)

	local OldOmega      = State.AngularVelocity
	local SpinComponent = BodyForward * BodyForward:Dot(OldOmega)
	local PitchYawOmega = OldOmega - SpinComponent
	local ReflectedPitchYaw = PitchYawOmega - 2 * PitchYawOmega:Dot(SurfaceNormal) * SurfaceNormal

	State.AngularVelocity = ReflectedPitchYaw + SpinComponent * Restitution
end

function SixDOFStep.GetBodyForward(State: any): Vector3
	return PureSixDOF.GetBodyForward(State.Orientation)
end

return table.freeze(SixDOFStep)
