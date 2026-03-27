--!native
--!optimize 2
--!strict

-- ─── Tumble ───────────────────────────────────────────────────────────────────
--[[
    Gyroscopic stability loss — Cast-aware wrapper around Pure/Tumble.

    Handles the two state transitions that start tumbling:
        • Speed drops below Behavior.TumbleSpeedThreshold
        • A pierce occurs and Behavior.TumbleOnPierce = true

    Once Runtime.IsTumbling is set it is never cleared for the lifetime of
    the cast. The OnTumbleBegin signal is fired exactly once per cast.

    All math lives in Physics/Pure/Tumble, which is also called directly by
    the parallel DragRecalc path. This wrapper is serial-only.

    See Physics/Pure/Tumble for the full physics model and behavior field docs.
]]

local Identity = "Tumble"
local Tumble   = {}
Tumble.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local PureTumble = require(Physics.Pure.Tumble)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns true when the behavior has any tumbling configuration enabled.
    Used as a fast exit in the simulation loop.
]]
function Tumble.IsConfigured(Behavior: any): boolean
	return (Behavior.TumbleSpeedThreshold ~= nil and Behavior.TumbleSpeedThreshold > 0)
		or Behavior.TumbleOnPierce == true
end

--[[
    Checks whether a currently tumbling cast has recovered above TumbleRecoverySpeed.
    Clears Runtime.IsTumbling and Runtime.TumbleRandom when recovery occurs.
    Returns true if tumble just ended so the caller can fire OnTumbleEnd.
    Always returns false when TumbleRecoverySpeed is nil (permanent tumble).
]]
function Tumble.CheckRecovery(Cast: any, CurrentSpeed: number): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if not Runtime.IsTumbling then return false end

	if PureTumble.ShouldRecover(CurrentSpeed, Behavior.TumbleRecoverySpeed) then
		Runtime.IsTumbling   = false
		Runtime.TumbleRandom = nil
		return true
	end

	return false
end

--[[
    Checks speed-based trigger. If the threshold is crossed and the cast is
    not already tumbling, marks Runtime.IsTumbling = true, seeds Runtime.TumbleRandom
    from Cast.Id, and returns true so the caller can fire OnTumbleBegin.

    Returns false when tumble was already active or no threshold is configured.
]]
function Tumble.CheckSpeedTrigger(Cast: any, CurrentSpeed: number): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.IsTumbling then return false end

	if PureTumble.ShouldBeginFromSpeed(CurrentSpeed, Behavior.TumbleSpeedThreshold) then
		Runtime.IsTumbling    = true
		Runtime.TumbleRandom  = PureTumble.CreateRandom(Cast.Id)
		return true
	end

	return false
end

--[[
    Pierce-triggered tumble. Call after a pierce resolves.
    Same semantics as CheckSpeedTrigger — returns true if tumble just began.
]]
function Tumble.CheckPierceTrigger(Cast: any): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	if Runtime.IsTumbling then return false end
	if not Behavior.TumbleOnPierce then return false end

	Runtime.IsTumbling   = true
	Runtime.TumbleRandom = PureTumble.CreateRandom(Cast.Id)
	return true
end

--[[
    Returns the drag multiplier for the current cast state.
    1.0 when not tumbling; TumbleDragMultiplier (default 3.0) when tumbling.
]]
function Tumble.GetDragMultiplier(Cast: any): number
	return PureTumble.GetDragMultiplier(Cast.Runtime.IsTumbling, Cast.Behavior.TumbleDragMultiplier)
end

--[[
    Advances the seeded PRNG and returns the lateral acceleration vector for
    this drag-recalc interval. Returns Vector3.zero when not tumbling or when
    TumbleLateralStrength is 0.
]]
function Tumble.StepLateralForce(Cast: any, CurrentVelocity: Vector3): Vector3
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior
	if not Runtime.IsTumbling then return Vector3.zero end
	return PureTumble.StepLateralForce(
		CurrentVelocity,
		Behavior.TumbleLateralStrength,
		Runtime.TumbleRandom
	)
end

-- ─── Module Return ────────────────────────────────────────────────────────────

local TumbleMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Tumble: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Tumble: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
		))
	end,
})

return setmetatable(Tumble, TumbleMetatable)
