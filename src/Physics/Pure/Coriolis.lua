--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Coriolis ───────────────────────────────────────────────────
--[[
    Parallel-safe Coriolis acceleration computation.

    "Pure" modules contain only stateless math with no upward require() paths
    that would fail inside a Roblox Actor (task.desynchronize context). They
    mirror the logic of their Physics/ counterparts but are stripped of any
    dependency that cannot cross the Actor boundary.

    This module exposes only ComputeAcceleration. ComputeOmega is intentionally
    excluded because Ω is computed once on the main thread (via
    Vetra:SetCoriolisConfig → Physics.Coriolis.ComputeOmega), written into
    each CastSnapshot as the field CoriolisOmega, and then read here. The trig
    (sin/cos) therefore never runs inside task.desynchronize().

    Relationship to Physics/Coriolis.lua
    ─────────────────────────────────────
    The formula is identical. The separation exists purely for the Actor
    require() path — Parallel/Physics/Step.lua requires Physics/Pure/Coriolis
    rather than Physics/Coriolis because the Pure subtree has no dependencies
    on game services or upward script references.
]]
local Identity = "PureCoriolis"
local PureCoriolis   = {}
PureCoriolis.__type  = Identity

-- ─── Public API ──────────────────────────────────────────────────────────────

--[[
    ComputeAcceleration(omega, velocity)

    Identical to Physics.Coriolis.ComputeAcceleration.
    Safe to call from inside task.desynchronize().

    Parameters
        omega     Vector3   Precomputed Ω, sourced from Snapshot.CoriolisOmega.
        velocity  Vector3   Current projectile velocity this step.

    Returns
        Vector3   Per-step velocity-dependent acceleration nudge.
]]
function PureCoriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	return -2 * omega:Cross(velocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(PureCoriolis)