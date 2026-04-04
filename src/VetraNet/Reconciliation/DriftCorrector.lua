--!strict
--DriftCorrector.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Reconciliation/DriftCorrector.lua
    Corrects cosmetic bullet position when it drifts from the server
    authoritative position.

    Why exponential blend instead of hard snap?
    A hard snap (Position = ServerPosition on every frame) produces a visible
    teleport jitter whenever the state batch arrives slightly late or with
    a reordered packet. Exponential blending amortises the correction over
    several frames — the cosmetic bullet moves smoothly toward the authoritative
    position without a discrete jump. The blend alpha = deltaTime x CorrectionRate
    ensures corrections scale correctly regardless of frame rate.

    Why a drift threshold?
    Applying correction below the threshold would cause constant micro-corrections
    (sub-stud drift is normal due to floating-point differences between the
    server's f64 simulation and the client's f32-serialised state). Micro-
    corrections every frame produce a subtle but perceptible jitter that is
    visually worse than the underlying drift.

    Correction algorithm:
        newPosition = lerp(localPosition, serverPosition, alpha)
        where alpha = min(deltaTime * CorrectionRate, 1)

    We use Cast:SetPosition() from Vetra's CAST_STATE_METHODS rather than
    directly mutating position, so Vetra's trajectory system remains consistent.

    CLIENT-ONLY. Errors at require() time if loaded on the server.
]]

local Identity       = "DriftCorrector"

local DriftCorrector = {}
DriftCorrector.__type = Identity

local DriftCorrectorMetatable = table.freeze({
	__index = DriftCorrector,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)

Authority.AssertClient("DriftCorrector")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_min      = math.min
local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

function DriftCorrector.new(ResolvedConfig: any): any
	local self = setmetatable({
		_DriftThreshold = ResolvedConfig.DriftThreshold,
		_CorrectionRate = ResolvedConfig.CorrectionRate,
	}, DriftCorrectorMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Returns true if the local cast's current position deviates from the
-- authoritative server position by more than DriftThreshold studs.
-- Called before Correct() to avoid the lerp cost when no correction is needed.
function DriftCorrector.Evaluate(self: any, LocalCast: any, ServerPosition: Vector3): boolean
	-- GetPosition() calls Kinematics.PositionAtTime on the cast's active
	-- trajectory — it is O(1) and does not mutate any state.
	local LocalPosition = LocalCast:GetPosition()
	if not LocalPosition then
		return false
	end
	local Delta = ServerPosition - LocalPosition
	return Delta:Dot(Delta) > self._DriftThreshold * self._DriftThreshold
end

-- Apply one frame of exponential drift correction.
-- Blends the cast's local position toward ServerPosition using:
--     alpha = clamp(deltaTime * CorrectionRate, 0, 1)
--     correctedPosition = lerp(localPosition, serverPosition, alpha)
-- Velocity is snapped directly to ServerVelocity rather than blended.
-- Blending velocity produces a direction change that lingers across multiple
-- frames and causes the bullet to curve visibly between corrections. A direct
-- snap is imperceptible at the sub-frame correction granularity and ensures
-- the local trajectory immediately agrees with the server's physics, so
-- corrections do not re-accumulate within the same batch interval.
function DriftCorrector.Correct(
	self           : any,
	LocalCast      : any,
	ServerPosition : Vector3,
	ServerVelocity : Vector3,
	DeltaTime      : number
)
	local LocalPosition = LocalCast:GetPosition()
	if not LocalPosition then
		Logger:Warn("DriftCorrector.Correct: could not read local cast position")
		return
	end

	local Alpha     = math_min(DeltaTime * self._CorrectionRate, 1)
	local Corrected = LocalPosition:Lerp(ServerPosition, Alpha)

	-- SetPosition opens a new kinematic segment at the corrected position.
	-- SetVelocity must be called after SetPosition — both call ModifyTrajectory
	-- which opens a new segment; calling SetVelocity first would have its
	-- segment immediately overwritten by SetPosition's segment.
	LocalCast:SetPosition(Corrected)
	LocalCast:SetVelocity(ServerVelocity)

	Logger:Debug(string_format(
		"DriftCorrector: applied alpha=%.3f, drift=%.3f studs",
		Alpha, (ServerPosition - LocalPosition).Magnitude
		))
end

-- Idempotent destroy.
function DriftCorrector.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(DriftCorrector, {
	__index = function(_, Key)
		Logger:Warn(string_format("DriftCorrector: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("DriftCorrector: write to protected key '%s'", tostring(Key)))
	end,
}))