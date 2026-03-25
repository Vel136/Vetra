--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Magnus ─────────────────────────────────────────────────────
--[[
    Pure Magnus-effect math — no Cast references, no side effects.

    Functional ApplySpinDecay returns the new spin vector instead of mutating
    Behavior.SpinVector, making it safe for the parallel Actor context.
    The serial Magnus wrapper calls this and writes the result back itself.
]]

local PureMagnus   = {}
PureMagnus.__type  = "PureMagnus"

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants = require(Core.Constants)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_clamp = math.clamp

local ZERO_VECTOR        = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ   = Constants.MIN_MAGNITUDE_SQ
local MIN_SPIN_MAGNITUDE = Constants.MIN_SPIN_MAGNITUDE

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns the Magnus acceleration vector for a spinning projectile.
    Returns Vector3.zero when either input is degenerate.
]]
function PureMagnus.ComputeForce(
	SpinVector        : Vector3,
	Velocity          : Vector3,
	MagnusCoefficient : number
): Vector3
	if SpinVector:Dot(SpinVector) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	if Velocity:Dot(Velocity)     < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	return SpinVector:Cross(Velocity) * MagnusCoefficient
end

--[[
    Returns the spin vector after applying aerodynamic decay for one segment.
    Returns the original vector unchanged when DecayRate <= 0.
    Returns Vector3.zero when the resulting spin falls below MIN_SPIN_MAGNITUDE.

    This is the functional counterpart of Magnus.StepSpinDecay — it does not
    mutate Behavior.SpinVector, making it safe for the parallel context.
]]
function PureMagnus.ApplySpinDecay(
	SpinVector : Vector3,
	DecayRate  : number,
	Delta      : number
): Vector3
	if DecayRate <= 0 then return SpinVector end
	if SpinVector:Dot(SpinVector) < MIN_MAGNITUDE_SQ then return SpinVector end

	local Factor  = 1 - math_clamp(DecayRate * Delta, 0, 1)
	local NewSpin = SpinVector * Factor

	if NewSpin.Magnitude < MIN_SPIN_MAGNITUDE then
		return ZERO_VECTOR
	end
	return NewSpin
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(PureMagnus)
