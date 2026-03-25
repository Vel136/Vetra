--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Tumble ──────────────────────────────────────────────────────
--[[
    Pure tumbling math — no Cast references, no Runtime mutations, no signals.

    Safe to call from both the serial simulation and the parallel Actor context.
]]

local PureTumble  = {}
PureTumble.__type = "PureTumble"

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants = require(Core.Constants)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local UP_VECTOR        = Constants.UP_VECTOR
local RIGHT_VECTOR     = Constants.RIGHT_VECTOR

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns true when speed has dropped below the tumble threshold.
    Always returns false when TumbleSpeedThreshold is nil.
]]
function PureTumble.ShouldBeginFromSpeed(
	Speed                : number,
	TumbleSpeedThreshold : number?
): boolean
	return TumbleSpeedThreshold ~= nil and Speed < TumbleSpeedThreshold
end

--[[
    Returns true when a tumbling cast has recovered above the recovery speed.
    Always returns false when TumbleRecoverySpeed is nil (permanent tumble).
]]
function PureTumble.ShouldRecover(
	Speed                 : number,
	TumbleRecoverySpeed   : number?
): boolean
	return TumbleRecoverySpeed ~= nil and Speed >= TumbleRecoverySpeed
end

--[[
    Creates and returns a new Random instance seeded from CastId.
    Called exactly once when a cast enters the tumbling state.
    The returned object must be stored on Runtime.TumbleRandom so it
    persists and advances consistently across all subsequent intervals.
]]
function PureTumble.CreateRandom(CastId: number): Random
	return Random.new(CastId)
end

--[[
    Returns the effective drag coefficient multiplier to use when tumbling.
    Returns 1.0 (no change) when not tumbling.
]]
function PureTumble.GetDragMultiplier(
	IsTumbling           : boolean,
	TumbleDragMultiplier : number?
): number
	if not IsTumbling then return 1.0 end
	return TumbleDragMultiplier or 3.0
end

--[[
    Advances the PRNG by one step and returns the lateral acceleration vector
    for this drag-recalc interval.

    The lateral direction is constructed by rotating a perpendicular-to-velocity
    axis by a random angle in [0, 2π), then scaling by TumbleLateralStrength.
    This produces a force that is always perpendicular to the current velocity
    (no component along the flight path) but whose rotational phase drifts
    smoothly and unpredictably each interval.

    Returns Vector3.zero when:
        • TumbleLateralStrength is 0 or nil
        • Velocity is degenerate
        • TumbleRandom is nil (should never happen if wired correctly)
]]
function PureTumble.StepLateralForce(
	Velocity              : Vector3,
	TumbleLateralStrength : number?,
	TumbleRandom          : Random?
): Vector3
	if not TumbleLateralStrength or TumbleLateralStrength == 0 then return ZERO_VECTOR end
	if not TumbleRandom then return ZERO_VECTOR end
	if Velocity:Dot(Velocity) < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end

	-- Build an orthonormal basis perpendicular to velocity.
	-- Same axis-selection logic as cone sampling to avoid degenerate cross products.
	local VUnit  = Velocity.Unit
	local RefAxis = math.abs(VUnit:Dot(UP_VECTOR)) < Constants.PERPENDICULAR_AXIS_THRESHOLD
		and UP_VECTOR or RIGHT_VECTOR

	local Perp1 = VUnit:Cross(RefAxis).Unit
	local Perp2 = VUnit:Cross(Perp1).Unit

	-- Advance the PRNG and sample a random angle in [0, 2π).
	local Angle  = TumbleRandom:NextNumber(0, math.pi * 2)
	local CosA   = math.cos(Angle)
	local SinA   = math.sin(Angle)

	-- Lateral direction is a unit vector in the plane perpendicular to velocity.
	local LateralDir = Perp1 * CosA + Perp2 * SinA

	return LateralDir * TumbleLateralStrength
end

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze(PureTumble)
