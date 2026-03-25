--!strict

-- ─── HitValidator ────────────────────────────────────────────────────────────
--[[
    Server-side hit validation against reconstructed cast trajectories.
]]

-- ─── References ───────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core       = Vetra.Core
local Validation = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local LogService      = require(Core.Logger)
local Constants       = require(Core.Constants)
local AntiRewindGuard = require(Validation.AntiRewindGuard)
local DefaultConfig   = require(Validation.ValidationConfig)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("HitValidator", true)

-- ─── Constants ───────────────────────────────────────────────────────────────

local VALIDATION_RESULT = Constants.VALIDATION_RESULT

-- ─── Module ──────────────────────────────────────────────────────────────────

local HitValidator = {}
HitValidator.__index = HitValidator

export type ValidationResult = "Validated" | "Suspicious" | "Rejected" -- use VALIDATION_RESULT constants

export type HitClaim = {
	CastId       : number,
	Position     : Vector3,
	Timestamp    : number,
	Velocity     : Vector3?,
}

export type ValidationOutcome = {
	Result          : ValidationResult,
	PositionError   : number,
	VelocityError   : number?,
	Reason          : string?,
}

function HitValidator.new(ValidatorConfig: any?)
	local ResolvedConfig = ValidatorConfig or {}
	local self = setmetatable({
		_LastPurgeTime        = 0,
		_PositionTolerance    = ResolvedConfig.PositionTolerance    or DefaultConfig.PositionTolerance,
		_TimeTolerance        = ResolvedConfig.TimeTolerance        or DefaultConfig.TimeTolerance,
		_VelocityTolerance    = ResolvedConfig.VelocityTolerance    or DefaultConfig.VelocityTolerance,
		_SuspiciousMultiplier = ResolvedConfig.SuspiciousMultiplier or DefaultConfig.SuspiciousMultiplier,
		_MaxRewindAge         = ResolvedConfig.MaxRewindAge         or DefaultConfig.MaxRewindAge,
		_CastHistories        = {},
	}, HitValidator)
	return self
end

function HitValidator.RecordCastHistory(self: any, CastId: number, Trajectories: { any }, StartTime: number)
	-- Store a live reference to the cast's Trajectories array intentionally.
	-- Cloning at fire-time (as attempted for Bug 19) snapshots only the
	-- initial segment; every arc opened later by a bounce, homing turn, or
	-- drag recalc is invisible to the validator. ReconstructAtTime would then
	-- reconstruct the wrong position for any hit after the first segment
	-- boundary, rejecting every valid hit on a bouncing or homing bullet.
	-- The live reference ensures the validator always sees the full history.
	self._CastHistories[CastId] = {
		Trajectories = Trajectories,
		StartTime    = StartTime,
		RecordedAt   = workspace:GetServerTimeNow(),
	}
end

-- Grace period in seconds between server-side cast termination and history
-- removal. Fast-moving projectiles can be terminated on the server before the
-- client's hit remote event is processed; purging immediately caused every
-- such hit to be Rejected as "no trajectory history".
local PURGE_GRACE_PERIOD = 2

function HitValidator.PurgeCast(self: any, CastId: number)
	local History = self._CastHistories[CastId]
	if History then
		-- Mark for deferred removal rather than deleting immediately.
		-- The periodic purge in Validate() will clean it up once the grace
		-- period has elapsed.
		History.PurgeAt = workspace:GetServerTimeNow() + PURGE_GRACE_PERIOD
	end
end

local function PositionAtTime(
	ElapsedTime     : number,
	Origin          : Vector3,
	InitialVelocity : Vector3,
	Acceleration    : Vector3
): Vector3
	return Origin + InitialVelocity * ElapsedTime + Acceleration * (ElapsedTime ^ 2 / 2)
end

local function VelocityAtTime(
	ElapsedTime     : number,
	InitialVelocity : Vector3,
	Acceleration    : Vector3
): Vector3
	return InitialVelocity + Acceleration * ElapsedTime
end

local function ReconstructAtTime(Trajectories: { any }, TargetTime: number): (Vector3?, Vector3?)
	for TrajectoryIndex = #Trajectories, 1, -1 do
		local Trajectory = Trajectories[TrajectoryIndex]

		if TargetTime >= Trajectory.StartTime then
			local ElapsedTime = TargetTime - Trajectory.StartTime

			if Trajectory.EndTime >= 0 and TargetTime > Trajectory.EndTime then
				ElapsedTime = Trajectory.EndTime - Trajectory.StartTime
			end

			local ReconstructedPosition = PositionAtTime(ElapsedTime, Trajectory.Origin, Trajectory.InitialVelocity, Trajectory.Acceleration)
			local ReconstructedVelocity = VelocityAtTime(ElapsedTime, Trajectory.InitialVelocity, Trajectory.Acceleration)
			return ReconstructedPosition, ReconstructedVelocity
		end
	end

	return nil, nil
end

function HitValidator.Validate(self: any, Claim: HitClaim): ValidationOutcome
	local ServerNow = workspace:GetServerTimeNow()

	if (ServerNow - self._LastPurgeTime) > self._MaxRewindAge then
		self._LastPurgeTime = ServerNow
		local MaxAge = self._MaxRewindAge
		for CastId, History in pairs(self._CastHistories) do
			-- Remove entries that are past their grace period (deferred purge from
			-- PurgeCast), or that have simply exceeded the max rewind age.
			local IsPastGrace = History.PurgeAt ~= nil and ServerNow >= History.PurgeAt
			local IsExpired   = (ServerNow - History.RecordedAt) > MaxAge
			if IsPastGrace or IsExpired then
				self._CastHistories[CastId] = nil
			end
		end
	end

	local AgeIsValid, AgeRejectionReason = AntiRewindGuard.IsValid(Claim.Timestamp, ServerNow, self._MaxRewindAge)
	if not AgeIsValid then
		return {
			Result        = VALIDATION_RESULT.Rejected,
			PositionError = math.huge,
			Reason        = AgeRejectionReason,
		}
	end

	local CastHistory = self._CastHistories[Claim.CastId]
	if not CastHistory then
		return {
			Result        = VALIDATION_RESULT.Rejected,
			PositionError = math.huge,
			Reason        = "no trajectory history for cast ID",
		}
	end

	local CastRelativeTime        = Claim.Timestamp - CastHistory.StartTime
	local ReconstructedPosition, ReconstructedVelocity = ReconstructAtTime(CastHistory.Trajectories, CastRelativeTime)

	if not ReconstructedPosition then
		return {
			Result        = VALIDATION_RESULT.Rejected,
			PositionError = math.huge,
			Reason        = "timestamp precedes cast start",
		}
	end

	local PositionError = (Claim.Position - ReconstructedPosition).Magnitude

	local VelocityError: number? = nil
	if Claim.Velocity and ReconstructedVelocity then
		VelocityError = (Claim.Velocity - ReconstructedVelocity).Magnitude
	end

	-- Expand position tolerance by how far the bullet could travel in the
	-- timing window — this is what _TimeTolerance is for.
	local TimingPositionSlack    = ReconstructedVelocity and (ReconstructedVelocity.Magnitude * self._TimeTolerance) or 0
	local EffectivePosTolerance  = self._PositionTolerance + TimingPositionSlack

	local PositionPassed        = PositionError <= EffectivePosTolerance
	local VelocityPassed        = VelocityError == nil or (VelocityError :: number) <= self._VelocityTolerance
	local PositionIsSuspicious  = PositionError <= EffectivePosTolerance * self._SuspiciousMultiplier
	local VelocityIsSuspicious  = VelocityError == nil or (VelocityError :: number) <= self._VelocityTolerance * self._SuspiciousMultiplier

	if PositionPassed and VelocityPassed then
		return {
			Result        = VALIDATION_RESULT.Validated,
			PositionError = PositionError,
			VelocityError = VelocityError,
		}
	elseif PositionIsSuspicious and VelocityIsSuspicious then
		return {
			Result        = VALIDATION_RESULT.Suspicious,
			PositionError = PositionError,
			VelocityError = VelocityError,
			Reason        = string.format("position error %.2f studs exceeds tolerance %.2f", PositionError, EffectivePosTolerance),
		}
	else
		return {
			Result        = VALIDATION_RESULT.Rejected,
			PositionError = PositionError,
			VelocityError = VelocityError,
			Reason        = string.format("position error %.2f studs far exceeds tolerance", PositionError),
		}
	end
end

function HitValidator.PurgeOlderThan(self: any, MaxAge: number)
	local ServerNow = workspace:GetServerTimeNow()
	for CastId, History in pairs(self._CastHistories) do
		if (ServerNow - History.RecordedAt) > MaxAge then
			self._CastHistories[CastId] = nil
		end
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(HitValidator, {
	__index = function(_, Key)
		Logger:Warn(string.format("Vetra: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Vetra: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})