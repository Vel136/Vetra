--!native
--!optimize 2
--!strict

-- ─── SixDOF ──────────────────────────────────────────────────────────────────
--[[
    Cast-aware 6DOF wrapper — reads angular state from Cast.Runtime, delegates
    all math to Physics/Pure/SixDOF, and writes updated state back.

    Integration point:
        Called from SimulateCast during the drag-recalculation interval (the
        same cadence that drag, Magnus, Coriolis, and tumble use). When
        Behavior.SixDOFEnabled is true, this module:
            1. Calls PureSixDOF.Step() with current state
            2. Writes new Orientation and AngularVelocity to Runtime
            3. Returns LiftAcceleration and DragMultiplier so the caller can
               composite them into the trajectory segment's acceleration and
               the effective drag coefficient.

    Backward compatibility:
        When SixDOFEnabled is false (the default), IsEnabled() returns false
        and no 6DOF code runs. All existing 3DOF behaviour is unaffected.

    Cosmetic bullet orientation:
        When 6DOF is active, Runtime.Orientation is authoritative for the
        bullet's CFrame. SimulateCast's cosmetic-update block should use it
        instead of the velocity look-at fallback.
]]

local Identity = "SixDOF"
local SixDOF   = {}
SixDOF.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)
local PureSixDOF = require(Physics.Pure.SixDOF)

local SPEED_OF_SOUND  = Constants.SPEED_OF_SOUND
local LerpMachTable   = Constants.MACH_TABLES.Lerp
local ANGULAR_SUBSTEP = Constants.ANGULAR_SUBSTEP

-- Resolves a coefficient: if a Mach table is provided, interpolate at the
-- given Mach number; otherwise fall back to the flat scalar.
local function Resolve(Table: { { number } }?, Mach: number, Scalar: number): number
	if Table then return LerpMachTable(Table, Mach) end
	return Scalar
end

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns true when the behavior has 6DOF enabled and the required fields
    are present. Fast exit for the simulation loop.
]]
function SixDOF.IsEnabled(Behavior: any): boolean
	return Behavior.SixDOFEnabled == true
end

--[[
    Step the 6DOF angular state for one simulation interval.

    Reads current state from Cast.Runtime, calls the pure math layer, and
    writes updated Orientation + AngularVelocity back to Runtime.

    Parameters:
        Cast     : the active cast table
        Velocity : current linear velocity (from kinematic evaluation)
        Delta    : time step for this recalculation interval

    Returns:
        LiftAcceleration : Vector3 — add to the new trajectory acceleration
        DragMultiplier   : number  — multiply onto the effective drag coeff
]]
function SixDOF.StepAngularState(
	Cast     : any,
	Velocity : Vector3,
	Delta    : number
): (Vector3, number)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	-- Resolve Mach-variable coefficients once per drag-recalc interval.
	-- Velocity is treated as approximately constant across sub-steps because
	-- linear speed changes negligibly over the ~4ms recalc window.
	local Mach    = Velocity.Magnitude / SPEED_OF_SOUND
	local CLSlope = Resolve(Behavior.CLAlphaMachTable, Mach, Behavior.LiftCoefficientSlope)
	local CmSlope = Resolve(Behavior.CmAlphaMachTable, Mach, Behavior.PitchingMomentSlope)
	local CmqCoef = Resolve(Behavior.CmqMachTable,     Mach, Behavior.PitchDampingCoeff)
	local ClpCoef = Resolve(Behavior.ClpMachTable,     Mach, Behavior.RollDampingCoeff)

	local AoADragFactor  = Behavior.AoADragFactor
	local ReferenceArea  = Behavior.ReferenceArea
	local ReferenceLen   = Behavior.ReferenceLength
	local AirDensity     = Behavior.AirDensity
	local MOI            = Behavior.MomentOfInertia
	local SpinMOI        = Behavior.SpinMOI
	local MaxAngSpeed    = Behavior.MaxAngularSpeed
	local BulletMass     = Behavior.BulletMass

	-- ── Fixed-timestep accumulator sub-stepping ───────────────────────────────
	-- Pitching moment and gyroscopic precession form a stiff ODE — their
	-- solution diverges when integrated with a large Δt. The accumulator
	-- carries remainder time across drag-recalc intervals so no time is lost,
	-- and each sub-step uses a small fixed Δt (ANGULAR_SUBSTEP ≈ 1/240 s)
	-- where the Rodrigues integrator remains accurate.
	--
	-- Lift and AoA-drag are accumulated across sub-steps and averaged at the
	-- end so the translational trajectory receives a representative composite
	-- rather than only the final sub-step's values.
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
			CLSlope,
			CmSlope,
			CmqCoef,
			ClpCoef,
			AoADragFactor,
			ReferenceArea,
			ReferenceLen,
			AirDensity,
			MOI,
			SpinMOI,
			MaxAngSpeed,
			BulletMass
		)

		Runtime.Orientation     = NewOrientation
		Runtime.AngularVelocity = NewAngularVelocity
		Runtime.AngleOfAttack   = AoA

		AccumLiftAccel += LiftAccel
		AccumDragMult  += DragMult
		SubStepCount   += 1

		Runtime.SixDOFAccumulator -= ANGULAR_SUBSTEP
	end

	-- If the accumulator had less than one sub-step (e.g. first frame, or a
	-- very short drag interval), fall back to a single step with the full
	-- Delta so lift and drag are never reported as zero.
	if SubStepCount == 0 then
		local NewOrientation, NewAngularVelocity, LiftAccel, DragMult, AoA = PureSixDOF.Step(
			Runtime.Orientation,
			Runtime.AngularVelocity,
			Velocity,
			Delta,
			CLSlope,
			CmSlope,
			CmqCoef,
			ClpCoef,
			AoADragFactor,
			ReferenceArea,
			ReferenceLen,
			AirDensity,
			MOI,
			SpinMOI,
			MaxAngSpeed,
			BulletMass
		)
		Runtime.Orientation     = NewOrientation
		Runtime.AngularVelocity = NewAngularVelocity
		Runtime.AngleOfAttack   = AoA
		-- Do NOT drain the accumulator here — this remainder will combine
		-- with the next interval's Delta to form a full sub-step.
		return LiftAccel, DragMult
	end

	-- Return the average lift and drag multiplier across all sub-steps.
	-- Averaging is correct here because both quantities feed into a new
	-- trajectory segment that spans the whole recalc interval.
	local InvCount = 1 / SubStepCount
	return AccumLiftAccel * InvCount, AccumDragMult * InvCount
end

--[[
    Get the body-frame forward vector from the cast's current orientation.
    Used by the cosmetic update path and by consumers who need the nose
    direction for VFX (tracer alignment, muzzle flash facing, etc.).
]]
function SixDOF.GetBodyForward(Cast: any): Vector3
	return PureSixDOF.GetBodyForward(Cast.Runtime.Orientation)
end

--[[
    Compose the cosmetic CFrame from a world position and the cast's
    body-frame orientation. Call this instead of the velocity look-at
    when 6DOF is active.
]]
function SixDOF.ComposeCosmeticCFrame(Position: Vector3, Orientation: CFrame): CFrame
	return CFrame.new(Position) * (Orientation - Orientation.Position)
end

--[[
    Handle post-bounce orientation update.

    After a bounce, the body axis should reflect about the surface normal,
    matching the velocity reflection. Angular velocity's pitch/yaw components
    are preserved (they represent tumble/wobble), but the roll component is
    dampened by the bounce restitution.
]]
function SixDOF.OnBounce(
	Cast           : any,
	SurfaceNormal  : Vector3,
	PostBounceVel  : Vector3,
	Restitution    : number
)
	local Runtime = Cast.Runtime
	if not Runtime.Orientation then return end

	local BodyForward = PureSixDOF.GetBodyForward(Runtime.Orientation)

	-- Reflect the body forward axis about the surface normal, same as velocity.
	local ReflectedForward = BodyForward - 2 * BodyForward:Dot(SurfaceNormal) * SurfaceNormal

	-- Build new orientation from reflected forward and an "up" heuristic.
	-- Use the post-bounce velocity direction as a guide for the up axis.
	local VelMagSq = PostBounceVel:Dot(PostBounceVel)
	local UpHint
	if VelMagSq > 1e-6 then
		-- Cross forward with velocity to get a lateral axis, then cross again
		-- to get an up that is perpendicular to the new forward.
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

	-- Dampen the roll (spin) component of angular velocity by restitution.
	-- Pitch/yaw components are preserved — the bounce adds wobble, it doesn't
	-- remove it.
	local OldOmega       = Runtime.AngularVelocity
	local SpinComponent  = BodyForward * BodyForward:Dot(OldOmega)
	local PitchYawOmega  = OldOmega - SpinComponent

	-- Reflect the pitch/yaw component about the surface normal (mirror tumble axis).
	local ReflectedPitchYaw = PitchYawOmega - 2 * PitchYawOmega:Dot(SurfaceNormal) * SurfaceNormal

	Runtime.AngularVelocity = ReflectedPitchYaw + SpinComponent * Restitution
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
