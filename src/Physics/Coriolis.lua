--!native
--!optimize 2
--!strict

-- ─── Coriolis ────────────────────────────────────────────────────────────────
--[[
    Computes the Coriolis acceleration imparted on a projectile travelling
    through a rotating reference frame (Earth).

    Why Coriolis is not baked into a trajectory segment
    ────────────────────────────────────────────────────
    Every other continuous force in Vetra (gravity, wind, drag, Magnus) is
    eventually folded into a trajectory segment's constant Acceleration field.
    That works because those forces either don't change step-to-step (gravity,
    wind) or are re-approximated on a fixed interval and written as a new
    constant (drag, Magnus).

    Coriolis cannot do this: its acceleration equals -2*(Ωxv), and v changes
    every step. Baking in Ωxv₀ as a constant would give the right deflection
    on step 1 and increasingly wrong deflection on every step after, because
    v has changed but the baked term has not.

    The correct integration is a per-step velocity nudge: compute -2*(Ωxv)
    for the current velocity, multiply by delta time, add to CurrentVelocity.
    This is what SimulateCast and the parallel Step module both do.
]]
local Identity   = "Coriolis"
local Coriolis   = {}
Coriolis.__type  = Identity

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Earth's actual angular velocity in radians per second.
-- Named explicitly so it is never confused with a game-units value.
local EARTH_OMEGA_RADS = 7.2921e-5

-- ─── Public API ──────────────────────────────────────────────────────────────


function Coriolis.ComputeOmega(latitude: number, scale: number): Vector3
	-- Fast path: scale = 0 means Coriolis is disabled. Return zero immediately
	-- so the per-step check (omega:Dot(omega) > 0) exits without a cross product.
	if scale == 0 then
		return Vector3.zero
	end

	local phi   = math.rad(latitude)
	local omega = EARTH_OMEGA_RADS * scale

	-- +Y component (vertical):  zero at equator, maximum at poles.
	-- +Z component (northward): maximum at equator, zero at poles.
	-- +X component is always 0 — Earth's rotation axis lies in the Y-Z plane
	-- under the +Z = north / +X = east convention.
	return Vector3.new(
		0,
		omega * math.sin(phi),
		omega * math.cos(phi)
	)
end


function Coriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	-- a = -2 * (Ω x v)
	-- The negative sign is load-bearing: without it deflection is in the
	-- wrong direction (the "anti-Coriolis" direction, which does not exist
	-- in nature for a prograde-rotating planet like Earth).
	return -2 * omega:Cross(velocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Coriolis)
