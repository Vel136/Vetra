--!strict
--!optimize 2
--!native

local SixDOF   = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local math_acos  = math.acos
local math_sin   = math.sin
local math_cos   = math.cos
local math_abs   = math.abs
local math_clamp = math.clamp
local cframe_new = CFrame.new
local ZERO_VEC   = Vector3.zero

local MIN_MAG_SQ = 1e-12

function SixDOF.AngleOfAttack(BodyForward: Vector3, Velocity: Vector3): number
	if Velocity:Dot(Velocity) < MIN_MAG_SQ then return 0 end
	local VelUnit = Velocity.Unit
	local Dot     = math_clamp(BodyForward:Dot(VelUnit), -1, 1)
	return math_acos(Dot)
end

function SixDOF.PitchPlaneAxis(BodyForward: Vector3, Velocity: Vector3): Vector3
	if Velocity:Dot(Velocity) < MIN_MAG_SQ then return ZERO_VEC end

	local VelUnit    = Velocity.Unit
	local Cross      = BodyForward:Cross(VelUnit)
	local CrossMagSq = Cross:Dot(Cross)

	if CrossMagSq > MIN_MAG_SQ then
		return Cross.Unit
	end

	local AbsX = math_abs(VelUnit.X)
	local AbsY = math_abs(VelUnit.Y)
	local AbsZ = math_abs(VelUnit.Z)

	local Fallback
	if AbsX <= AbsY and AbsX <= AbsZ then
		Fallback = Vector3.new(1, 0, 0)
	elseif AbsY <= AbsZ then
		Fallback = Vector3.new(0, 1, 0)
	else
		Fallback = Vector3.new(0, 0, 1)
	end

	local Perp = VelUnit:Cross(Fallback)
	if Perp:Dot(Perp) < MIN_MAG_SQ then return ZERO_VEC end
	return Perp.Unit
end

function SixDOF.ComputeLiftForce(
	Velocity            : Vector3,
	BodyForward         : Vector3,
	LiftCoefficientSlope: number,
	ReferenceArea       : number,
	AirDensity          : number
): Vector3
	local SpeedSq = Velocity:Dot(Velocity)
	if SpeedSq < MIN_MAG_SQ then return ZERO_VEC end

	local AoA = SixDOF.AngleOfAttack(BodyForward, Velocity)
	if AoA < 1e-6 then return ZERO_VEC end

	local LateralAxis = SixDOF.PitchPlaneAxis(BodyForward, Velocity)
	if LateralAxis:Dot(LateralAxis) < MIN_MAG_SQ then return ZERO_VEC end

	local LiftDir = Velocity.Unit:Cross(LateralAxis)
	if LiftDir:Dot(LiftDir) < MIN_MAG_SQ then return ZERO_VEC end
	LiftDir = LiftDir.Unit

	local CL      = LiftCoefficientSlope * math_sin(AoA)
	local DynPress = 0.5 * AirDensity * SpeedSq
	local LiftMag  = CL * DynPress * ReferenceArea

	return LiftDir * LiftMag
end

function SixDOF.DragMultiplier(
	BodyForward   : Vector3,
	Velocity      : Vector3,
	AoADragFactor : number
): number
	if AoADragFactor <= 0 then return 1.0 end

	local AoA  = SixDOF.AngleOfAttack(BodyForward, Velocity)
	local SinA = math_sin(AoA)
	return 1.0 + AoADragFactor * SinA * SinA
end

function SixDOF.ComputePitchingMoment(
	Velocity            : Vector3,
	BodyForward         : Vector3,
	PitchingMomentSlope : number,
	ReferenceArea       : number,
	ReferenceLength     : number,
	AirDensity          : number
): Vector3
	local SpeedSq = Velocity:Dot(Velocity)
	if SpeedSq < MIN_MAG_SQ then return ZERO_VEC end

	local AoA = SixDOF.AngleOfAttack(BodyForward, Velocity)
	if AoA < 1e-6 then return ZERO_VEC end

	local LateralAxis = SixDOF.PitchPlaneAxis(BodyForward, Velocity)
	if LateralAxis:Dot(LateralAxis) < MIN_MAG_SQ then return ZERO_VEC end

	local Cm        = PitchingMomentSlope * math_sin(AoA)
	local DynPress  = 0.5 * AirDensity * SpeedSq
	local MomentMag = Cm * DynPress * ReferenceArea * ReferenceLength

	return LateralAxis * MomentMag
end

function SixDOF.ComputePitchDamping(
	AngularVelocity   : Vector3,
	BodyForward       : Vector3,
	PitchDampingCoeff : number,
	Speed             : number,
	ReferenceArea     : number,
	ReferenceLength   : number,
	AirDensity        : number
): Vector3
	if PitchDampingCoeff <= 0 then return ZERO_VEC end

	local SpinComponent = BodyForward * BodyForward:Dot(AngularVelocity)
	local PitchYawOmega = AngularVelocity - SpinComponent
	local PitchYawMagSq = PitchYawOmega:Dot(PitchYawOmega)

	if PitchYawMagSq < MIN_MAG_SQ then return ZERO_VEC end
	if Speed < 1e-3 then return ZERO_VEC end

	local DynPress  = 0.5 * AirDensity * Speed * Speed
	local DampScale = PitchDampingCoeff * (ReferenceLength / (2 * Speed)) * DynPress * ReferenceArea * ReferenceLength

	return -PitchYawOmega * DampScale
end

function SixDOF.ComputeRollDamping(
	AngularVelocity  : Vector3,
	BodyForward      : Vector3,
	RollDampingCoeff : number,
	Speed            : number,
	ReferenceArea    : number,
	ReferenceLength  : number,
	AirDensity       : number
): Vector3
	if RollDampingCoeff <= 0 then return ZERO_VEC end

	local RollRate = BodyForward:Dot(AngularVelocity)
	if math_abs(RollRate) < 1e-6 then return ZERO_VEC end
	if Speed < 1e-3 then return ZERO_VEC end

	local DynPress  = 0.5 * AirDensity * Speed * Speed
	local DampScale = RollDampingCoeff * (ReferenceLength / (2 * Speed)) * DynPress * ReferenceArea * ReferenceLength

	return BodyForward * (-RollRate * DampScale)
end

function SixDOF.IntegrateAngularVelocity(
	AngularVelocity : Vector3,
	TotalTorque     : Vector3,
	MomentOfInertia : number,
	MaxAngularSpeed : number,
	Delta           : number,
	BodyForward     : Vector3?,
	SpinMOI         : number?
): Vector3
	if MomentOfInertia <= 0 then return AngularVelocity end

	local NewOmega: Vector3

	if BodyForward and SpinMOI and SpinMOI > 0 then
		local SpinRate      = BodyForward:Dot(AngularVelocity)
		local TransverseVel = AngularVelocity - BodyForward * SpinRate

		local SpinTorque       = BodyForward:Dot(TotalTorque)
		local TransverseTorque = TotalTorque - BodyForward * SpinTorque

		local PrecessionRate = ((MomentOfInertia - SpinMOI) / MomentOfInertia) * SpinRate
		local PrecessAngle   = -PrecessionRate * Delta

		if math_abs(PrecessAngle) > 1e-12 and TransverseVel:Dot(TransverseVel) > MIN_MAG_SQ then
			local CosA = math_cos(PrecessAngle)
			local SinA = math_sin(PrecessAngle)
			TransverseVel = TransverseVel * CosA + BodyForward:Cross(TransverseVel) * SinA
		end

		TransverseVel = TransverseVel + (TransverseTorque / MomentOfInertia) * Delta
		SpinRate      = SpinRate + (SpinTorque / SpinMOI) * Delta

		NewOmega = TransverseVel + BodyForward * SpinRate
	else
		NewOmega = AngularVelocity + (TotalTorque / MomentOfInertia) * Delta
	end

	if BodyForward then
		local SpinRate      = BodyForward:Dot(NewOmega)
		local TransverseVel = NewOmega - BodyForward * SpinRate

		local ClampedSpin = math_clamp(SpinRate, -MaxAngularSpeed, MaxAngularSpeed)

		local TransverseMagSq = TransverseVel:Dot(TransverseVel)
		if TransverseMagSq > MaxAngularSpeed * MaxAngularSpeed then
			TransverseVel = TransverseVel.Unit * MaxAngularSpeed
		end

		NewOmega = TransverseVel + BodyForward * ClampedSpin
	else
		local OmegaMagSq = NewOmega:Dot(NewOmega)
		if OmegaMagSq > MaxAngularSpeed * MaxAngularSpeed then
			NewOmega = NewOmega.Unit * MaxAngularSpeed
		end
	end

	return NewOmega
end

function SixDOF.IntegrateOrientation(
	Orientation     : CFrame,
	AngularVelocity : Vector3,
	Delta           : number
): CFrame
	local ThetaVec = AngularVelocity * Delta
	local ThetaSq  = ThetaVec:Dot(ThetaVec)

	if ThetaSq < MIN_MAG_SQ then return Orientation end

	local Theta = ThetaSq ^ 0.5
	local Axis  = ThetaVec / Theta

	local RotationCFrame  = CFrame.fromAxisAngle(Axis, Theta)
	local PureOrientation = Orientation - Orientation.Position
	local NewOrientation  = RotationCFrame * PureOrientation

	return NewOrientation
end

function SixDOF.GetBodyForward(Orientation: CFrame): Vector3
	return Orientation.LookVector
end

function SixDOF.Step(
	Orientation          : CFrame,
	AngularVelocity      : Vector3,
	Velocity             : Vector3,
	Delta                : number,
	LiftCoefficientSlope : number,
	PitchingMomentSlope  : number,
	PitchDampingCoeff    : number,
	RollDampingCoeff     : number,
	AoADragFactor        : number,
	ReferenceArea        : number,
	ReferenceLength      : number,
	AirDensity           : number,
	MomentOfInertia      : number,
	SpinMOI              : number,
	MaxAngularSpeed      : number,
	BulletMass           : number
): (CFrame, Vector3, Vector3, number, number)
	local BodyForward = SixDOF.GetBodyForward(Orientation)
	local Speed       = Velocity.Magnitude
	local AoA         = SixDOF.AngleOfAttack(BodyForward, Velocity)

	local LiftForce = SixDOF.ComputeLiftForce(
		Velocity, BodyForward, LiftCoefficientSlope, ReferenceArea, AirDensity
	)

	local LiftAccel
	if BulletMass > 0 then
		LiftAccel = LiftForce / BulletMass
	else
		LiftAccel = LiftForce
	end

	local DragMult = SixDOF.DragMultiplier(BodyForward, Velocity, AoADragFactor)

	local PitchMoment = SixDOF.ComputePitchingMoment(
		Velocity, BodyForward, PitchingMomentSlope, ReferenceArea, ReferenceLength, AirDensity
	)

	local PitchDamp = SixDOF.ComputePitchDamping(
		AngularVelocity, BodyForward, PitchDampingCoeff, Speed, ReferenceArea, ReferenceLength, AirDensity
	)

	local RollDamp = SixDOF.ComputeRollDamping(
		AngularVelocity, BodyForward, RollDampingCoeff, Speed, ReferenceArea, ReferenceLength, AirDensity
	)

	local TotalTorque = PitchMoment + PitchDamp + RollDamp

	local NewAngularVelocity = SixDOF.IntegrateAngularVelocity(
		AngularVelocity, TotalTorque, MomentOfInertia, MaxAngularSpeed, Delta,
		BodyForward, SpinMOI
	)

	local MeanOmega      = (AngularVelocity + NewAngularVelocity) * 0.5
	local NewOrientation = SixDOF.IntegrateOrientation(Orientation, MeanOmega, Delta)

	return NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA
end

return table.freeze(SixDOF)
