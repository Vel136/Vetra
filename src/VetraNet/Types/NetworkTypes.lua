--!strict
--NetworkTypes.lua

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Types/NetworkTypes.lua
    Luau type definitions for every VetraNet structure.
    Imported by any module that needs type annotations.
    Contains no runtime logic — safe to require on both server and client.
]]

-- ── Payload Types ─────────────────────────────────────────────────────────────

-- Decoded representation of a client fire request.
-- Produced by BlinkSchema.DecodeFire and consumed by FireValidator.
export type FirePayload = {
	Origin       : Vector3,
	Direction    : Vector3,
	Speed        : number,
	BehaviorHash : number,  -- u16 key into BehaviorRegistry
	CastId       : number,  -- server-authoritative cast ID (0 in client→server direction)
	LocalCastId  : number,  -- client's local cosmetic ID; echoed back in server→client replication
	Timestamp    : number,  -- workspace:GetServerTimeNow() at fire moment
}

-- Decoded representation of a server-confirmed hit.
-- Produced by server signal handlers and encoded by OutboundBatcher via BlinkSchema.EncodeHit.
export type HitPayload = {
	CastId    : number,
	Position  : Vector3,
	Normal    : Vector3,
	Velocity  : Vector3,
	Timestamp : number,
}

-- One bullet's position + velocity sampled for a given frame.
-- Produced by StateBatcher.Collect and decoded by BlinkSchema.DecodeStateBatch.
export type StateEntry = {
	CastId   : number,
	Position : Vector3,
	Velocity : Vector3,
}

-- Container for all StateEntries collected in one frame.
-- FrameId is a monotonically increasing counter used by the client to discard
-- out-of-order batches from reordered UDP packets.
-- FrameDelta is the server Heartbeat DeltaTime for this frame, embedded in the
-- batch header so the client can use it directly as the correction alpha base.
export type StateBatch = {
	FrameId    : number,
	FrameDelta : number,
	States     : { StateEntry },
}

-- ── Validation ────────────────────────────────────────────────────────────────

-- Reason codes for FireValidator rejections.
-- Reason strings are logged server-side but NEVER sent to the client.
-- The client receives no rejection acknowledgement — silence prevents
-- exploiters from probing which checks are active.
--
-- Runtime code must use Enums.ValidationReason rather than raw string literals.
-- These union types exist solely for the Luau type checker.
export type ValidationReason =
	"ok"
| "RejectedPlayerNotFound"
| "RejectedSessionInactive"
| "RejectedRateLimited"
| "RejectedConcurrentLimit"
| "RejectedOriginTolerance"
| "RejectedInvalidDirection"
| "RejectedInvalidSpeed"
| "RejectedUnknownBehavior"
| "RejectedFireRequest"

export type ValidationResult = {
	Passed : boolean,
	Reason : ValidationReason,
}

-- ── NetworkMode ───────────────────────────────────────────────────────────────

-- Which side may call :Fire() to initiate a bullet.
-- Runtime code must use Enums.NetworkMode rather than raw string literals.
export type NetworkMode = "ClientAuthoritative" | "ServerAuthority" | "SharedAuthority"

-- ── Configuration ─────────────────────────────────────────────────────────────

-- Consumer-facing config accepted by VetraNet.new() and VetraNet.Client.new().
-- Every field is optional — missing fields resolve to Constants defaults.
export type NetworkConfig = {
	-- Stud radius around the character within which fire origins are accepted.
	MaxOriginTolerance     : number?,

	-- Maximum simultaneous in-flight bullets per player.
	MaxConcurrentPerPlayer : number?,

	-- Token bucket fill rate (tokens per second).
	TokensPerSecond        : number?,

	-- Token bucket maximum capacity (burst ceiling).
	BurstLimit             : number?,

	-- Minimum stud drift before DriftCorrector activates.
	DriftThreshold         : number?,

	-- Exponential blend rate for drift correction (fraction per second).
	CorrectionRate         : number?,

	-- Override one-way latency estimate in seconds. 0 = use Stats RTT.
	-- Useful for LAN servers where RTT is near zero and buffering is unwanted.
	LatencyBuffer          : number?,

	-- When false, per-frame bullet state sync is disabled entirely.
	-- Drift correction on other clients will not occur.
	-- Default: true.
	ReplicateState         : boolean?,

	-- Authority mode. Defaults to ClientAuthoritative.
	--   ClientAuthoritative — clients send fire requests; server validates.
	--   ServerAuthority     — only server may call :Fire(); client requests are dropped.
	--   SharedAuthority     — both client and server may fire.
	Mode                   : NetworkMode?,
}

-- ── Public API Surface Types ──────────────────────────────────────────────────

-- The server-side network handle returned by VetraNet.new().
-- Game code binds to OnValidatedHit here and never touches Transport or
-- Authority directly.
export type ServerNetwork = {
	-- Fires for every hit that passes FireValidator and OwnershipRegistry checks.
	-- Signature matches Vetra's OnHit: (context, result?, velocity, impactForce).
	OnValidatedHit : any,

	-- Fires when a fire request is rejected, providing the reason for logging
	-- or analytics. Reason is never forwarded to the client.
	OnFireRejected : any,

	-- Only available when Mode = ServerAuthority.
	-- Fires a server-owned bullet and replicates it to all clients.
	-- Errors if called in ClientAuthoritative mode.
	Fire : (self: ServerNetwork, Origin: Vector3, Direction: Vector3, Speed: number, BehaviorHash: number) -> (),

	Destroy : (self: ServerNetwork) -> (),
}

-- The client-side handle returned by VetraNet.Client.new().
-- Game code calls Fire() to send a fire request and never constructs payloads.
export type ClientNetwork = {
	-- Serialize a BulletContext + behavior name into a fire payload and send
	-- to the server. Returns immediately — no acknowledgement is expected.
	Fire : (self: ClientNetwork, context: any, behaviorName: string) -> (),

	Destroy : (self: ClientNetwork) -> (),
}

-- ── Session ───────────────────────────────────────────────────────────────────

-- Return value of Session:CanFire().
--   "ok"       — player has an active session with room for another bullet.
--   "cap"      — concurrent bullet count is at the configured maximum.
--   "inactive" — no session is registered for this player.
--
-- Runtime code must use Enums.SessionStatus rather than raw string literals.
-- This union type exists solely for the Luau type checker.
export type SessionStatus = "ok" | "cap" | "inactive"

-- ── ServerHooks ───────────────────────────────────────────────────────────────

-- Context table passed to ServerHooks.Bind().
-- Using a named table instead of positional parameters means adding a new
-- dependency in a future version is a field addition, not a signature change.
export type ServerHooksContext = {
	Solver            : any,
	Remotes           : { Net: RemoteEvent },
	Session           : any,
	RateLimiter       : any,
	BehaviorRegistry  : any,
	OwnershipRegistry : any,
	StateBatcher      : any,
	OutboundBatcher   : any,
	ResolvedConfig    : any,
	OnValidatedHit    : any,
	OnFireRejected    : any,
	Mode              : NetworkMode,
}

return {}