--!strict
--FireValidator.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Authority/FireValidator.lua
    Server-side validation of incoming fire requests.

    Stateless per-request: no mutable state lives here. All shared mutable
    state (session count, rate limiter tokens) lives in Session and RateLimiter
    respectively, which are passed in on each call. Keeping FireValidator
    stateless makes it trivially testable and prevents accidental state sharing
    between concurrent validation calls.

    Validation checks run in order from cheapest to most expensive,
    with destructive checks (rate limiter token consumption) placed last:
      1. Player exists and is in game         — O(1) table read
      2. Session active / concurrent cap      — O(1) counter check
      3. Origin distance from character        — O(1) vector dot product
      4. Direction is a unit vector            — O(1) magnitude check
      5. BehaviorHash resolves to a behavior   — O(1) hash table lookup
      6. Speed within behavior bounds          — O(1) comparison
      7. Rate limiter token available          — O(1) arithmetic, DESTRUCTIVE

    Checks 3–6 are non-destructive and gate check 7. An exploiter sending
    geometrically invalid payloads (bad origin, direction, unknown behavior)
    is rejected before any token is consumed, preventing token drain attacks.

    Rejection reasons are logged server-side with the player's UserId.
    They are NEVER returned to the client — silence is the only response
    a rejected client receives. Sending rejection reasons would allow
    exploiters to probe which checks are active and calibrate their spoofs.

    SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity      = "FireValidator"

local FireValidator = {}
FireValidator.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core  = script.Parent.Parent.Core
local Types = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local Constants  = require(Types.Constants)
local LogService = require(Core.Logger)
local Enums      = require(Types.Enums)

Authority.AssertServer("FireValidator")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_sqrt   = math.sqrt
local math_abs    = math.abs
local string_format = string.format

-- ─── Helpers ─────────────────────────────────────────────────────────────────

-- Locate the character root part for position-based origin checks.
-- Returns nil if the character is not fully loaded, which may happen during
-- respawn. In that case we accept the fire — the origin tolerance check will
-- still catch obvious teleport exploits once the character has a valid position.
local function GetCharacterRoot(Player: Player): BasePart?
	local Char = Player.Character
	if not Char then return nil end
	return Char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Validate an incoming fire payload.
-- Returns a ValidationResult { Passed, Reason }.
-- Session, RateLimiter, and BehaviorRegistry are passed in as arguments
-- rather than required here — this module has no dependencies on concrete
-- instances, making it straightforward to unit-test with mock objects.
function FireValidator.Validate(
	Player           : Player,
	Payload          : any,
	Session          : any,
	RateLimiter      : any,
	BehaviorRegistry : any,
	ResolvedConfig   : any
): any
	-- ── Check 1: Player in game ─────────────────────────────────────────────
	if not Player or not Player.Parent then
		return { Passed = false, Reason = Enums.ValidationReason.PlayerNotFound }
	end

	-- ── Check 2: Session / concurrent cap ──────────────────────────────────
	local SessionResult = Session:CanFire(Player)
	if SessionResult ~= Enums.SessionStatus.Ready then
		if SessionResult == Enums.SessionStatus.AtLimit then
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — concurrent bullet cap reached (%d active)",
				Player.Name, Player.UserId, ResolvedConfig.MaxConcurrentPerPlayer
				))
			return { Passed = false, Reason = Enums.ValidationReason.ConcurrentLimit }
		else
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — session inactive",
				Player.Name, Player.UserId
				))
			return { Passed = false, Reason = Enums.ValidationReason.SessionInactive }
		end
	end

	-- ── Check 3: Origin tolerance ───────────────────────────────────────────
	-- Structural/geometry checks run before the rate limiter so that exploiters
	-- with spoofed origins or bad directions cannot drain the token bucket.
	-- RateLimiter.Acquire is destructive — it consumes a token on call — so it
	-- must only run after we are confident the payload is geometrically valid.
	local Root = GetCharacterRoot(Player)
	if Root then
		local OriginTolerance = ResolvedConfig.MaxOriginTolerance
		local OriginDelta     = (Payload.Origin - Root.Position)
		local DistanceSq      = OriginDelta:Dot(OriginDelta)
		if DistanceSq > OriginTolerance * OriginTolerance then
			Logger:Warn(string_format(
				"FireValidator: player '%s' (UserId: %d) rejected — origin %.1f studs from character (tolerance: %.1f)",
				Player.Name, Player.UserId, math_sqrt(DistanceSq), OriginTolerance
				))
			return { Passed = false, Reason = Enums.ValidationReason.OriginTolerance }
		end
	end

	-- ── Check 4: Direction unit vector ──────────────────────────────────────
	local DirectionMagnitude = Payload.Direction.Magnitude
	local DirectionEpsilon   = Constants.DEFAULT_DIRECTION_UNIT_EPSILON
	if math_abs(DirectionMagnitude - 1) > DirectionEpsilon then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — direction magnitude %.6f (expected ~1.0)",
			Player.Name, Player.UserId, DirectionMagnitude
			))
		return { Passed = false, Reason = Enums.ValidationReason.InvalidDirection }
	end

	-- ── Check 5: Behavior hash valid ────────────────────────────────────────
	local Behavior = BehaviorRegistry:Get(Payload.BehaviorHash)
	if not Behavior then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — unknown behavior hash %d",
			Player.Name, Player.UserId, Payload.BehaviorHash
			))
		return { Passed = false, Reason = Enums.ValidationReason.UnknownBehavior }
	end

	-- ── Check 6: Speed within behavior bounds ───────────────────────────────
	local BehaviorMinSpeed = Behavior.MinSpeed or Constants.DEFAULT_MIN_SPEED
	local BehaviorMaxSpeed = Behavior.MaxSpeed or Constants.DEFAULT_MAX_SPEED
	if Payload.Speed < BehaviorMinSpeed or Payload.Speed > BehaviorMaxSpeed then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — speed %.1f out of bounds [%.1f, %.1f]",
			Player.Name, Player.UserId, Payload.Speed, BehaviorMinSpeed, BehaviorMaxSpeed
			))
		return { Passed = false, Reason = Enums.ValidationReason.InvalidSpeed }
	end

	-- ── Check 7: Rate limiter token ─────────────────────────────────────────
	-- Runs last among the pre-fire checks. All structural and geometric
	-- validations above are cheap and non-destructive. Acquire() is the only
	-- destructive call in the chain — placing it here ensures tokens are only
	-- consumed for payloads that are geometrically valid and carry a known behavior.
	if not RateLimiter:Acquire(Player) then
		Logger:Warn(string_format(
			"FireValidator: player '%s' (UserId: %d) rejected — rate limited",
			Player.Name, Player.UserId
			))
		return { Passed = false, Reason = Enums.ValidationReason.RateLimited }
	end

	return { Passed = true, Reason = Enums.ValidationReason.Passed }
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(FireValidator, {
	__index = function(_, Key)
		Logger:Warn(string_format("FireValidator: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("FireValidator: write to protected key '%s'", tostring(Key)))
	end,
}))