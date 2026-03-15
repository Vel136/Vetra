--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/GyroDrift ───────────────────────────────────────────────────
--[[
    Pure gyroscopic spin-drift math — no Cast references, no side effects.

    Safe to call from both the serial simulation and the parallel Actor context.
]]

local PureGyroDrift  = {}
PureGyroDrift.__type = "PureGyroDrift"

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants = require(Core.Constants)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local UP_VECTOR        = Constants.UP_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns the gyroscopic drift acceleration vector for the current velocity.

    GyroDriftAxis defaults to world UP_VECTOR when nil, matching right-hand
    rifling convention. Pass -UP_VECTOR for left-hand rifling.

    Returns Vector3.zero when velocity is degenerate or the cross product
    collapses (axis parallel to velocity — theoretical edge case).
]]
function PureGyroDrift.ComputeForce(
	Velocity      : Vector3,
	DriftRate     : number,
	ReferenceAxis : Vector3?
): Vector3
	if Velocity:Dot(Velocity) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end
	if DriftRate == 0 then return ZERO_VECTOR end

	local Axis     = ReferenceAxis or UP_VECTOR
	local DriftDir = Axis:Cross(Velocity.Unit)

	-- Degenerate case: velocity is parallel to the reference axis.
	-- Extremely unlikely in practice (straight up/down shot with default axis)
	-- but guard it to avoid NaN from .Unit on a near-zero vector.
	if DriftDir:Dot(DriftDir) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end

	return DriftDir.Unit * DriftRate
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(PureGyroDrift)
