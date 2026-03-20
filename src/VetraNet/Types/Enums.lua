--!strict
--Enums.lua

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Types/Enums.lua
    Frozen enum tables for every string constant used in comparisons across
    VetraNet. No module may compare against a raw string literal for these
    values — always reference the enum key.

    The string values here must stay in sync with the union types declared in
    NetworkTypes.lua. The union types serve the Luau type checker; these tables
    serve runtime code that needs to branch on a value.

    Contains no runtime logic — safe to require on both server and client.
]]

-- ── SessionStatus ─────────────────────────────────────────────────────────────
-- Return values of Session:CanFire().
-- See NetworkTypes.SessionStatus for the matching type union.
local SessionStatus = table.freeze({
	-- Player has an active session with room for another bullet.
	Ready    = "ok",
	-- Concurrent in-flight bullet count is at the configured maximum.
	AtLimit  = "cap",
	-- No session is registered for this player.
	Inactive = "inactive",
})

-- ── ValidationReason ──────────────────────────────────────────────────────────
-- Reason codes returned by FireValidator.Validate().
-- Logged server-side only — never forwarded to the client.
-- See NetworkTypes.ValidationReason for the matching type union.
local ValidationReason = table.freeze({
	-- Fire request passed all checks.
	Passed             = "ok",
	-- Player is not present in the game (disconnected between send and receive).
	PlayerNotFound     = "RejectedPlayerNotFound",
	-- Player has no active session registered.
	SessionInactive    = "RejectedSessionInactive",
	-- Token bucket is empty — player is firing faster than their allowed rate.
	RateLimited        = "RejectedRateLimited",
	-- Player already has the maximum allowed in-flight bullets.
	ConcurrentLimit    = "RejectedConcurrentLimit",
	-- Fire origin is too far from the player's character position.
	OriginTolerance    = "RejectedOriginTolerance",
	-- Direction vector is not a unit vector (magnitude deviates beyond epsilon).
	InvalidDirection   = "RejectedInvalidDirection",
	-- Bullet speed is outside the behavior's [MinSpeed, MaxSpeed] bounds.
	InvalidSpeed       = "RejectedInvalidSpeed",
	-- BehaviorHash does not resolve to a registered behavior.
	UnknownBehavior    = "RejectedUnknownBehavior",
	-- Fire request was rejected by a registered FireValidator hook.
	FireRequest        = "RejectedFireRequest",
})

-- ── NetworkMode ───────────────────────────────────────────────────────────────
-- Governs which side is permitted to initiate a fire request.
--
--   ClientAuthoritative — default. Clients call :Fire() locally; the server
--                         validates and replicates. Suitable for player-driven
--                         projectiles (guns, abilities).
--
--   ServerAuthority     — server-only fire. Only server code may call :Fire()
--                         on the ServerNetwork handle. Client fire requests are
--                         silently dropped. Suitable for NPC projectiles,
--                         scripted events, or any bullet the server must own.
--
--   SharedAuthority     — both sides may fire. Clients send validated fire
--                         requests as normal, and server code may also call
--                         :Fire() directly. Useful when player bullets and
--                         server-owned bullets coexist in the same handle.
local NetworkMode = table.freeze({
	ClientAuthoritative = "ClientAuthoritative",
	ServerAuthority     = "ServerAuthority",
	SharedAuthority     = "SharedAuthority",
})

-- ─── Module Return ────────────────────────────────────────────────────────────

return table.freeze({
	SessionStatus    = SessionStatus,
	ValidationReason = ValidationReason,
	NetworkMode      = NetworkMode,
})