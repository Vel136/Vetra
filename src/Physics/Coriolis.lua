--!native
--!optimize 2
--!strict

-- ─── Coriolis ────────────────────────────────────────────────────────────────
--[[
    Computes the Coriolis acceleration imparted on a projectile travelling
    through a rotating reference frame (Earth).

    Physics background
    ──────────────────
    The Coriolis effect is an apparent force experienced inside any rotating
    frame. Earth rotates once per sidereal day (~24 h), so a projectile that
    travels in a straight line as seen from space appears to curve when
    observed from the ground. The acceleration is:

        a_coriolis = -2 * (Ω × v)

    where Ω is Earth's angular velocity vector (oriented by geographic
    latitude) and v is the projectile's current velocity. The cross product
    produces a vector perpendicular to both inputs — which is why the
    deflection is sideways relative to the flight path rather than along it.

    Coordinate convention (Roblox)
    ──────────────────────────────
        +Y  = world up
        +Z  = geographic north
        +X  = geographic east

    At latitude φ (degrees), Ω decomposes as:

        Ω = ω * Vector3.new(0, sin(φ), cos(φ))

    where ω = 7.2921 × 10⁻⁵ rad/s (Earth's actual angular speed).

    Latitude behaviour:
        φ =   0° (equator):  Ω points north (+Z). Deflection is purely
                             horizontal — east or west depending on direction.
        φ =  90° (N. Pole):  Ω points straight up (+Y). Ground-track rotates
                             clockwise when viewed from above.
        φ = -90° (S. Pole):  Ω points straight down (−Y). Ground-track
                             rotates counter-clockwise from above.

    Scale factor
    ────────────
    At real-world ω, deflection is millimetre-scale at game distances — fully
    invisible. CoriolisScale is a plain multiplier on ω. Representative values:
        0        → disabled (zero cost, the default)
        500      → subtle; only experts notice at 500+ studs
        1000     → clearly perceptible at ~300 studs
        3000     → strong, map-defining mechanic

    Expose as a per-map config (not per-gun) because the Coriolis effect is
    an environment property — every bullet on the map is deflected the same
    way regardless of weapon.

    Why Coriolis is NOT baked into a trajectory segment
    ────────────────────────────────────────────────────
    Every other continuous force in Vetra (gravity, wind, drag, Magnus) is
    eventually folded into a trajectory segment's constant Acceleration field.
    That works because those forces either don't change step-to-step (gravity,
    wind) or are re-approximated on a fixed interval and written as a new
    constant (drag, Magnus).

    Coriolis cannot do this: its acceleration equals -2*(Ω×v), and v changes
    every step. Baking in Ω×v₀ as a constant would give the right deflection
    on step 1 and increasingly wrong deflection on every step after, because
    v has changed but the baked term has not.

    The correct integration is a per-step velocity nudge: compute -2*(Ω×v)
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

--[[
    ComputeOmega(latitude, scale)

    Precompute the scaled Ω vector from a latitude and exaggeration factor.
    Call this once whenever the solver's Coriolis config changes and cache
    the result on the solver instance (via Vetra:SetCoriolisConfig). This
    ensures math.sin / math.cos never run inside the per-frame step loop.

    Parameters
        latitude  number   Geographic latitude in degrees.
                           Positive  = northern hemisphere.
                           Negative  = southern hemisphere.
                           0         = equator (horizontal E/W deflection only)
                           90 / -90  = poles (deflection rotates ground track)
        scale     number   Exaggeration multiplier.
                           0 = disabled (returns Vector3.zero immediately)
                           1 = physically accurate (invisible at game scales)

    Returns
        Vector3   The precomputed, scaled Ω. Pass this directly to
                  ComputeAcceleration each simulation step.
]]
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

--[[
    ComputeAcceleration(omega, velocity)

    Compute the Coriolis acceleration for a single simulation step.
    Must be called every step because velocity changes continuously.

    Parameters
        omega     Vector3   Precomputed Ω from ComputeOmega().
                            If this is Vector3.zero, returns zero with no work.
        velocity  Vector3   Current projectile velocity this step.

    Returns
        Vector3   Acceleration to ADD to CurrentVelocity * Delta this step.
                  Do NOT accumulate into the trajectory's stored Acceleration
                  field — that would bake in the wrong v permanently.
]]
function Coriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	-- a = -2 * (Ω × v)
	-- The negative sign is load-bearing: without it deflection is in the
	-- wrong direction (the "anti-Coriolis" direction, which does not exist
	-- in nature for a prograde-rotating planet like Earth).
	return -2 * omega:Cross(velocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Coriolis)