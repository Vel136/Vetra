--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/GyroDrift ───────────────────────────────────────────────────
--[[
    Pure gyroscopic spin-drift math — no Cast references, no side effects.

    Safe to call from both the serial simulation and the parallel Actor context.

    Background
    ──────────
    A rifled barrel imparts spin to a bullet. As the bullet travels and gravity
    deflects its nose downward, gyroscopic precession causes the spin axis to
    lag behind the velocity vector. That lag generates a slow, continuous
    lateral force — spin drift — always perpendicular to the current velocity.

    For right-hand rifling the drift is to the RIGHT of travel regardless of
    whether the bullet is climbing, flying level, or arcing downward. This is
    what the old flat Vector3 field could not model: a static world-space
    vector is only correct for a perfectly horizontal shot.

    Model
    ─────
    DriftAcceleration = (GyroDriftAxis × velocity.Unit).Unit × GyroDriftRate

    GyroDriftAxis is a world-space reference axis (typically UP_VECTOR for
    right-hand rifling, -UP_VECTOR for left-hand). The cross product always
    produces a vector perpendicular to the current velocity, so drift direction
    tracks the flight path naturally through climb, level, and drop phases.

    GyroDriftRate is the acceleration magnitude in studs/s². It is a designer
    tunable: 0.5–3.0 is typical for a rifle-class projectile, higher values
    exaggerate for gameplay feel. The force is applied at each drag segment
    recalculation interval rather than every frame, consistent with how drag
    and Magnus are applied.

    Practical starting values:
        GyroDriftRate = 1.5      -- studs/s², subtle but visible at long range
        GyroDriftAxis = Vector3.new(0, 1, 0)   -- right-hand rifling (default)
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
