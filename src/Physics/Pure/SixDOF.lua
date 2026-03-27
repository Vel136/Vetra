--!native
--!optimize 2
--!strict

-- ─── SixDOF ──────────────────────────────────────────────────────────────────
--[[
    Pure 6DOF aerodynamic math — stateless, signal-free, allocation-minimal.

    Adds three rotational degrees of freedom (pitch, yaw, roll) to the existing
    three translational DOF. The projectile's body-frame orientation is tracked
    as a CFrame, and angular velocity as a Vector3 (rad/s in body axes).

    Physics model (simplified axisymmetric projectile):
        • Angle of attack (α) = arccos(bodyForward · velocityUnit)
        • Lift force ∝ CLα · α · ½ρv² · Sref, perpendicular to velocity in
          the pitch plane defined by bodyForward and velocity.
        • Orientation-dependent drag multiplier: Cd(α) = Cd0 · (1 + AoADragFactor · sin²α)
        • Pitching moment ∝ Cmα · α — restoring torque about the lateral axis.
        • Pitch damping ∝ −Cq · angularVelocity — dissipates oscillation.
        • Roll damping ∝ −Cp · rollRate — spin decay through aerodynamic friction.
        • Gyroscopic precession: ω_prec = (spinAxis × M_aero) / (I_spin · spinRate)

    Integration:
        Orientation is updated via Rodrigues rotation of the current CFrame by
        the angular velocity vector scaled by Δt. This avoids gimbal lock and
        the cost of full quaternion slerp while remaining accurate for the
        small-angle rotations typical of a single simulation step.

    All functions are pure — they accept values and return values. The
    Cast-aware wrapper (Physics/SixDOF.lua) handles reading/writing state.
]]

local Identity = "Pure.SixDOF"
local SixDOF   = {}
SixDOF.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_acos  = math.acos
local math_sin   = math.sin
local math_cos   = math.cos
local math_abs   = math.abs
local math_clamp = math.clamp
local math_pi    = math.pi
local cframe_new = CFrame.new
local ZERO_VEC   = Vector3.zero

-- Minimum squared magnitude before a vector is considered degenerate.
local MIN_MAG_SQ = 1e-12

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Compute angle of attack between the projectile's body-frame forward axis
    and the velocity vector.

    Returns α in radians ∈ [0, π]. Returns 0 when velocity is degenerate.
]]
function SixDOF.AngleOfAttack(BodyForward: Vector3, Velocity: Vector3): number
	if Velocity:Dot(Velocity) < MIN_MAG_SQ then return 0 end
	local VelUnit = Velocity.Unit
	local Dot     = math_clamp(BodyForward:Dot(VelUnit), -1, 1)
	return math_acos(Dot)
end

--[[
    Compute the "pitch plane" normal — the axis about which angle of attack
    is measured. This is the cross product of bodyForward and velocity,
    normalised. When the two vectors are nearly parallel (α ≈ 0 or π),
    the cross product degenerates; in that case we return a fallback axis
    perpendicular to velocity.

    Returns a unit Vector3 (the lateral axis), or Vector3.zero if velocity
    is degenerate.
]]
function SixDOF.PitchPlaneAxis(BodyForward: Vector3, Velocity: Vector3): Vector3
	if Velocity:Dot(Velocity) < MIN_MAG_SQ then return ZERO_VEC end

	local VelUnit = Velocity.Unit
	local Cross   = BodyForward:Cross(VelUnit)
	local CrossMagSq = Cross:Dot(Cross)

	if CrossMagSq > MIN_MAG_SQ then
		return Cross.Unit
	end

	-- BodyForward and Velocity are nearly parallel — pick a perpendicular.
	-- Choose the world axis least aligned with velocity.
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

--[[
    Compute aerodynamic lift force.

    Lift acts perpendicular to velocity in the pitch plane, pushing the
    projectile "nose-first" back toward the velocity vector. The magnitude
    is proportional to α and v².

    Parameters:
        Velocity            : current velocity vector
        BodyForward         : projectile's longitudinal axis (unit vector)
        LiftCoefficientSlope: dCL/dα — lift coefficient per radian of AoA
        ReferenceArea       : aerodynamic reference area (studs²)
        AirDensity          : ρ, air density (kg/stud³ equivalent)

    Returns the lift force vector (studs/s² when divided by mass later, or
    as an acceleration directly if LiftCoefficientSlope already incorporates
    1/(2m)).
]]
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

	-- Lift direction: perpendicular to velocity, in the pitch plane,
	-- pointing from the velocity vector toward the body axis.
	local LateralAxis = SixDOF.PitchPlaneAxis(BodyForward, Velocity)
	if LateralAxis:Dot(LateralAxis) < MIN_MAG_SQ then return ZERO_VEC end

	-- Lift direction is velocity × lateralAxis (into the pitch plane, toward body axis)
	local LiftDir = Velocity.Unit:Cross(LateralAxis)
	if LiftDir:Dot(LiftDir) < MIN_MAG_SQ then return ZERO_VEC end
	LiftDir = LiftDir.Unit

	-- F_lift = CL(α) · ½ρv² · S_ref
	-- CL(α) = CLα · sin(α)  — valid for small α where sin(α)≈α, naturally
	-- caps at 90° and returns to zero at 180° (no unphysical lift at high AoA).
	local CL        = LiftCoefficientSlope * math_sin(AoA)
	local DynPress   = 0.5 * AirDensity * SpeedSq
	local LiftMag    = CL * DynPress * ReferenceArea

	return LiftDir * LiftMag
end

--[[
    Compute the AoA-dependent drag multiplier.

    Drag increases with angle of attack because the effective cross-section
    grows. This returns a multiplier ≥ 1.0 that should be applied on top of
    the existing DragCoefficient.

    Model: Multiplier = 1 + AoADragFactor · sin²(α)

    AoADragFactor = 0 means no AoA effect on drag (pure 3DOF behaviour).
    Typical values: 2–8 depending on projectile shape.
]]
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

--[[
    Compute aerodynamic pitching moment (restoring torque).

    A statically stable projectile has a negative Cmα — when the nose
    points away from the velocity vector, aerodynamic pressure creates a
    torque that pushes it back. An unstable projectile (positive Cmα)
    diverges.

    Parameters:
        Velocity              : current velocity
        BodyForward           : projectile's longitudinal axis
        PitchingMomentSlope   : Cmα — moment coefficient per radian (negative = stable)
        ReferenceArea         : aerodynamic reference area
        ReferenceLength       : reference length (caliber or diameter)
        AirDensity            : ρ

    Returns the torque vector about the pitch-plane lateral axis.
    The caller divides by moment of inertia to get angular acceleration.
]]
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

	-- M = Cmα · sin(α) · ½ρv² · S · d
	local Cm       = PitchingMomentSlope * math_sin(AoA)
	local DynPress = 0.5 * AirDensity * SpeedSq
	local MomentMag = Cm * DynPress * ReferenceArea * ReferenceLength

	return LateralAxis * MomentMag
end

--[[
    Compute pitch damping torque.

    Opposes angular velocity in the pitch/yaw plane (all components
    perpendicular to the body forward axis). This is the primary mechanism
    that prevents eternal nutation.

    Parameters:
        AngularVelocity       : current angular velocity (rad/s)
        BodyForward           : projectile's longitudinal axis
        PitchDampingCoeff     : Cmq — pitch damping coefficient (positive)
        Speed                 : |v|
        ReferenceArea         : S_ref
        ReferenceLength       : d_ref
        AirDensity            : ρ

    Returns the damping torque vector.
]]
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

	-- Extract the component of angular velocity perpendicular to the spin axis.
	-- This is the pitch/yaw rate that damping opposes.
	local SpinComponent    = BodyForward * BodyForward:Dot(AngularVelocity)
	local PitchYawOmega    = AngularVelocity - SpinComponent
	local PitchYawMagSq    = PitchYawOmega:Dot(PitchYawOmega)

	if PitchYawMagSq < MIN_MAG_SQ then return ZERO_VEC end

	-- Damping torque = -Cmq · (d/(2v)) · ωpitch · ½ρv²Sd
	-- The (d/(2v)) term makes damping scale with the non-dimensional pitch rate.
	if Speed < 1e-3 then return ZERO_VEC end

	local DynPress  = 0.5 * AirDensity * Speed * Speed
	local DampScale = PitchDampingCoeff * (ReferenceLength / (2 * Speed)) * DynPress * ReferenceArea * ReferenceLength

	return -PitchYawOmega * DampScale
end

--[[
    Compute roll damping torque.

    Opposes the spin (roll) component of angular velocity about the body
    forward axis. This models aerodynamic friction slowing the barrel spin.

    Returns the roll damping torque vector.
]]
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

	local RollRate    = BodyForward:Dot(AngularVelocity)
	if math_abs(RollRate) < 1e-6 then return ZERO_VEC end

	if Speed < 1e-3 then return ZERO_VEC end

	local DynPress  = 0.5 * AirDensity * Speed * Speed
	local DampScale = RollDampingCoeff * (ReferenceLength / (2 * Speed)) * DynPress * ReferenceArea * ReferenceLength

	return BodyForward * (-RollRate * DampScale)
end

--[[
    Integrate angular velocity by applying torques over Δt.

    ω_new = ω_old + (Torque / MomentOfInertia) * Δt

    MomentOfInertia is treated as a scalar (axisymmetric projectile where
    transverse MOI ≈ axial MOI for game purposes).

    The AngularVelocity is clamped to MaxAngularSpeed to prevent divergence
    from improperly tuned coefficients.
]]
function SixDOF.IntegrateAngularVelocity(
	AngularVelocity : Vector3,
	TotalTorque     : Vector3,
	MomentOfInertia : number,
	MaxAngularSpeed : number,
	Delta           : number
): Vector3
	if MomentOfInertia <= 0 then return AngularVelocity end

	local AngularAccel = TotalTorque / MomentOfInertia
	local NewOmega     = AngularVelocity + AngularAccel * Delta

	-- Clamp to MaxAngularSpeed to prevent divergence.
	local OmegaMagSq = NewOmega:Dot(NewOmega)
	if OmegaMagSq > MaxAngularSpeed * MaxAngularSpeed then
		NewOmega = NewOmega.Unit * MaxAngularSpeed
	end

	return NewOmega
end

--[[
    Integrate orientation by rotating the current CFrame by the angular
    velocity vector over Δt using Rodrigues rotation.

    For the small angles typical of a single simulation step (ω·Δt < 0.1 rad)
    this is both faster and more numerically stable than quaternion slerp.
    For large rotations (tumbling projectile at >1000 rad/s with big Δt) the
    error is bounded because we normalise the rotation axis.

    Parameters:
        Orientation     : current body-frame CFrame (position component ignored)
        AngularVelocity : current ω in world-frame (rad/s)
        Delta           : time step (seconds)

    Returns the new orientation CFrame (position zeroed — caller composites
    with the projectile's world position).
]]
function SixDOF.IntegrateOrientation(
	Orientation     : CFrame,
	AngularVelocity : Vector3,
	Delta           : number
): CFrame
	local ThetaVec  = AngularVelocity * Delta
	local ThetaSq   = ThetaVec:Dot(ThetaVec)

	-- No rotation this frame — return unchanged.
	if ThetaSq < MIN_MAG_SQ then return Orientation end

	local Theta = ThetaSq ^ 0.5
	local Axis  = ThetaVec / Theta

	-- Rodrigues rotation: R = I·cos(θ) + (1-cos(θ))·(k⊗k) + sin(θ)·K
	-- Expressed as CFrame.fromAxisAngle.
	local RotationCFrame = CFrame.fromAxisAngle(Axis, Theta)

	-- Apply rotation in world frame: new = R * old
	-- Strip position from both so we get a pure rotation result.
	local PureOrientation = Orientation - Orientation.Position
	local NewOrientation  = RotationCFrame * PureOrientation

	return NewOrientation
end

--[[
    Extract the body-frame forward vector from a CFrame.
    Convention: -Z is forward (Roblox standard).
]]
function SixDOF.GetBodyForward(Orientation: CFrame): Vector3
	return Orientation.LookVector
end

--[[
    Compute gyroscopic precession torque.

    A spinning projectile acts as a gyroscope. When an external torque
    (pitching moment) acts on it, the response is a precession — the spin
    axis slowly rotates perpendicular to the applied torque.

    τ_precession = (AeroTorque × SpinAxis) / (I_spin · SpinRate)

    This is a simplified model that produces realistic coning motion without
    requiring the full Euler rigid-body solver.
]]
function SixDOF.ComputeGyroscopicPrecession(
	AeroTorque      : Vector3,
	BodyForward     : Vector3,
	AngularVelocity : Vector3,
	SpinMOI         : number
): Vector3
	-- SpinRate is the angular velocity component along the body axis.
	local SpinRate = BodyForward:Dot(AngularVelocity)
	if math_abs(SpinRate) < 1e-3 then return ZERO_VEC end
	if SpinMOI <= 0 then return ZERO_VEC end

	local AngularMomentum = SpinMOI * SpinRate

	-- Precession: ω_prec = spinAxis × τ / H  where H = I·ω_spin
	-- Derived from dH/dt = τ → I·SpinRate · d(spinAxis)/dt = τ → ω_prec × spinAxis = τ/H
	return BodyForward:Cross(AeroTorque) / AngularMomentum
end

--[[
    Full 6DOF step — computes all aerodynamic forces and torques, integrates
    angular velocity and orientation, and returns the results.

    This is the primary entry point called by the Cast-aware wrapper each
    drag-recalculation interval.

    Parameters (all scalar/vector — no tables, no state):
        Orientation           : current CFrame (rotation only)
        AngularVelocity       : current ω (rad/s, world frame)
        Velocity              : current linear velocity
        Delta                 : time step
        LiftCoefficientSlope  : dCL/dα
        PitchingMomentSlope   : dCm/dα (negative = stable)
        PitchDampingCoeff     : Cmq
        RollDampingCoeff      : Clp
        AoADragFactor         : sin²α multiplier on drag
        ReferenceArea         : S_ref
        ReferenceLength       : d_ref
        AirDensity            : ρ
        MomentOfInertia       : scalar MOI (transverse)
        SpinMOI               : scalar MOI (axial, for precession)
        MaxAngularSpeed       : clamp ceiling

    Returns:
        NewOrientation    : CFrame
        NewAngularVelocity: Vector3
        LiftAcceleration  : Vector3 (force/mass to add to linear acceleration)
        DragMultiplier    : number  (multiply onto existing drag coefficient)
        AngleOfAttack     : number  (radians, for telemetry)
]]
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

	-- ── Aerodynamic forces ───────────────────────────────────────────────
	local LiftForce = SixDOF.ComputeLiftForce(
		Velocity, BodyForward, LiftCoefficientSlope, ReferenceArea, AirDensity
	)

	-- Convert force to acceleration. If BulletMass is zero or unset,
	-- treat the coefficient as already encoding force/mass.
	local LiftAccel
	if BulletMass > 0 then
		LiftAccel = LiftForce / BulletMass
	else
		LiftAccel = LiftForce
	end

	local DragMult = SixDOF.DragMultiplier(BodyForward, Velocity, AoADragFactor)

	-- ── Aerodynamic torques ──────────────────────────────────────────────
	local PitchMoment = SixDOF.ComputePitchingMoment(
		Velocity, BodyForward, PitchingMomentSlope, ReferenceArea, ReferenceLength, AirDensity
	)

	local PitchDamp = SixDOF.ComputePitchDamping(
		AngularVelocity, BodyForward, PitchDampingCoeff, Speed, ReferenceArea, ReferenceLength, AirDensity
	)

	local RollDamp = SixDOF.ComputeRollDamping(
		AngularVelocity, BodyForward, RollDampingCoeff, Speed, ReferenceArea, ReferenceLength, AirDensity
	)

	-- Gyroscopic precession — converts pitching moment into coning motion.
	local Precession = SixDOF.ComputeGyroscopicPrecession(
		PitchMoment, BodyForward, AngularVelocity, SpinMOI
	)

	-- ── Integrate angular state ──────────────────────────────────────────
	-- Transverse torques (pitching moment + pitch damping) are divided by
	-- the transverse MOI. Roll damping acts about the longitudinal axis and
	-- must be divided by SpinMOI — combining them with one MOI would scale
	-- roll decay by the wrong factor (typically ~10× off for rifle bullets).
	local TransverseTorque   = PitchMoment + PitchDamp
	local NewAngularVelocity = SixDOF.IntegrateAngularVelocity(
		AngularVelocity, TransverseTorque, MomentOfInertia, MaxAngularSpeed, Delta
	)

	-- Roll decay: applied separately with the axial (spin) MOI.
	if SpinMOI > 0 then
		NewAngularVelocity = NewAngularVelocity + RollDamp / SpinMOI * Delta
		-- Re-clamp after the roll contribution.
		local OmegaMagSq = NewAngularVelocity:Dot(NewAngularVelocity)
		if OmegaMagSq > MaxAngularSpeed * MaxAngularSpeed then
			NewAngularVelocity = NewAngularVelocity.Unit * MaxAngularSpeed
		end
	end

	-- Precession is applied to orientation only — not stored in
	-- AngularVelocity. Storing it would cause ComputePitchDamping to treat
	-- the precession rate as nutation and artificially kill it off each frame.
	local NewOrientation = SixDOF.IntegrateOrientation(
		Orientation, NewAngularVelocity + Precession, Delta
	)

	return NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local SixDOFMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("%s: nil key '%s'", Identity, tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"%s: write to protected key '%s' = '%s'",
			Identity, tostring(Key), tostring(Value)
		))
	end,
})

return setmetatable(SixDOF, SixDOFMetatable)
