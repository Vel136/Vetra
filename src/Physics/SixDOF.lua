--!strict
--!optimize 2
--!native

local SixDOF   = {}

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

local Constants  = require(Core.Constants)
local PureSixDOF = require(Physics.Pure.SixDOF)

local SPEED_OF_SOUND  = Constants.SPEED_OF_SOUND
local LerpMachTable   = Constants.MACH_TABLES.Lerp
local ANGULAR_SUBSTEP = Constants.ANGULAR_SUBSTEP

local function Resolve(Table: { { number } }?, Mach: number, Scalar: number): number
	if Table then return LerpMachTable(Table, Mach) end
	return Scalar
end

function SixDOF.IsEnabled(Behavior: any): boolean
	return Behavior.SixDOFEnabled == true
end

function SixDOF.StepAngularState(
	Cast     : any,
	Velocity : Vector3,
	Delta    : number
): (Vector3, number)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local Mach    = Velocity.Magnitude / SPEED_OF_SOUND
	local CLSlope = Resolve(Behavior.CLAlphaMachTable, Mach, Behavior.LiftCoefficientSlope)
	local CmSlope = Resolve(Behavior.CmAlphaMachTable, Mach, Behavior.PitchingMomentSlope)
	local CmqCoef = Resolve(Behavior.CmqMachTable,     Mach, Behavior.PitchDampingCoeff)
	local ClpCoef = Resolve(Behavior.ClpMachTable,     Mach, Behavior.RollDampingCoeff)

	local AoADragFactor = Behavior.AoADragFactor
	local ReferenceArea = Behavior.ReferenceArea
	local ReferenceLen  = Behavior.ReferenceLength
	local AirDensity    = Behavior.AirDensity
	local MOI           = Behavior.MomentOfInertia
	local SpinMOI       = Behavior.SpinMOI
	local MaxAngSpeed   = Behavior.MaxAngularSpeed
	local BulletMass    = Behavior.BulletMass

	Runtime.SixDOFAccumulator = (Runtime.SixDOFAccumulator or 0) + Delta

	local AccumLiftAccel = Vector3.zero
	local AccumDragMult  = 0
	local SubStepCount   = 0

	while Runtime.SixDOFAccumulator >= ANGULAR_SUBSTEP do
		local NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA = PureSixDOF.Step(
			Runtime.Orientation,
			Runtime.AngularVelocity,
			Velocity,
			ANGULAR_SUBSTEP,
			CLSlope, CmSlope, CmqCoef, ClpCoef,
			AoADragFactor, ReferenceArea, ReferenceLen,
			AirDensity, MOI, SpinMOI, MaxAngSpeed, BulletMass
		)

		Runtime.Orientation     = NewOrientation
		Runtime.AngularVelocity = NewAngularVelocity
		Runtime.AngleOfAttack   = AoA

		AccumLiftAccel += LiftAccel
		AccumDragMult  += DragMult
		SubStepCount   += 1

		Runtime.SixDOFAccumulator -= ANGULAR_SUBSTEP
	end

	if SubStepCount == 0 then
		local NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA = PureSixDOF.Step(
			Runtime.Orientation,
			Runtime.AngularVelocity,
			Velocity,
			Delta,
			CLSlope, CmSlope, CmqCoef, ClpCoef,
			AoADragFactor, ReferenceArea, ReferenceLen,
			AirDensity, MOI, SpinMOI, MaxAngSpeed, BulletMass
		)
		Runtime.Orientation     = NewOrientation
		Runtime.AngularVelocity = NewAngularVelocity
		Runtime.AngleOfAttack   = AoA
		return LiftAccel, DragMult
	end

	local InvCount = 1 / SubStepCount
	return AccumLiftAccel * InvCount, AccumDragMult * InvCount
end

function SixDOF.GetBodyForward(Cast: any): Vector3
	return PureSixDOF.GetBodyForward(Cast.Runtime.Orientation)
end

function SixDOF.ComposeCosmeticCFrame(Position: Vector3, Orientation: CFrame): CFrame
	return CFrame.new(Position) * (Orientation - Orientation.Position)
end

function SixDOF.OnBounce(
	Cast           : any,
	SurfaceNormal  : Vector3,
	PostBounceVel  : Vector3,
	Restitution    : number
)
	local Runtime = Cast.Runtime
	if not Runtime.Orientation then return end

	local BodyForward = PureSixDOF.GetBodyForward(Runtime.Orientation)
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

	Runtime.Orientation = CFrame.lookAt(Vector3.zero, ReflectedForward, UpHint)

	local OldOmega      = Runtime.AngularVelocity
	local SpinComponent = BodyForward * BodyForward:Dot(OldOmega)
	local PitchYawOmega = OldOmega - SpinComponent
	local ReflectedPitchYaw = PitchYawOmega - 2 * PitchYawOmega:Dot(SurfaceNormal) * SurfaceNormal

	Runtime.AngularVelocity = ReflectedPitchYaw + SpinComponent * Restitution
end

return table.freeze(SixDOF)
