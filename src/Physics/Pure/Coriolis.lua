--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Coriolis ───────────────────────────────────────────────────
--[[
    Parallel-safe Coriolis acceleration computation.
]]
local Identity = "PureCoriolis"
local PureCoriolis   = {}
PureCoriolis.__type  = Identity

-- ─── Public API ──────────────────────────────────────────────────────────────


function PureCoriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	return -2 * omega:Cross(velocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(PureCoriolis)
