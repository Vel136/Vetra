--!strict
--Constants.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Types/Constants.lua
    Single source of truth for every numeric and string constant used across
    VetraNet. No module may embed a magic number — all constants are imported
    from here by name. This prevents the class of bug where server and client
    use subtly different byte offsets or threshold values because a literal
    was copy-pasted rather than shared.
]]

return table.freeze({

	-- ── Remote Names ─────────────────────────────────────────────────────────
	-- V0.1.2: three remotes collapsed into one. All outbound server messages
	-- (fire replication, hit confirmation, state batch) are written into a
	-- per-player OutboundBatcher cursor and flushed as a single FireClient
	-- call per Heartbeat. The client reads a 1-byte channel prefix to
	-- dispatch to the correct decoder. One remote, one send per player/frame.
	REMOTE_NET = "VetraNet_Net",

	-- Name of the Folder created under ReplicatedStorage to house the remote.
	-- Both sides search for the same name so mismatches are impossible.
	NETWORK_FOLDER_NAME = "VetraNet",

	-- ── Channel IDs ──────────────────────────────────────────────────────────
	-- 1-byte prefix written before each message in the outbound buffer.
	-- The client decoder reads this byte first and dispatches accordingly.
	-- Values must be unique u8 non-zero integers.
	CHANNEL_FIRE  = 1,
	CHANNEL_HIT   = 2,
	CHANNEL_STATE = 3,

	-- ── Validation Defaults ──────────────────────────────────────────────────
	-- Maximum stud distance between the client-reported fire origin and the
	-- server-reconstructed character HumanoidRootPart position.
	-- Bullets fired from farther than this are treated as teleport exploits.
	DEFAULT_MAX_ORIGIN_TOLERANCE     = 15,

	-- Acceptable deviation from a perfect unit vector (magnitude == 1.0).
	-- A direction with |magnitude - 1| > epsilon is considered invalid input,
	-- not merely imprecise floating-point — it signals a spoofed payload.
	DEFAULT_DIRECTION_UNIT_EPSILON   = 0.001,

	-- Fallback speed bounds used when the fire validator cannot resolve a
	-- behavior from the provided hash. These are intentionally wide so a
	-- hash registry miss is a soft rejection ("unknown behavior"), not a
	-- false speed-bounds rejection that would mask the real failure reason.
	DEFAULT_MIN_SPEED = 0,
	DEFAULT_MAX_SPEED = 5000,

	-- ── Rate Limiting ────────────────────────────────────────────────────────
	-- Token bucket defaults. TokensPerSecond controls the sustainable fire
	-- rate (e.g. 10 = semi-auto rifles). BurstLimit allows short bursts
	-- above that rate (e.g. 15 = fanning a revolver) without immediately
	-- triggering the rate limiter, which would feel punitive for legitimate
	-- rapid-fire actions.
	DEFAULT_TOKENS_PER_SECOND = 10,
	DEFAULT_BURST_LIMIT       = 15,

	-- ── Session ──────────────────────────────────────────────────────────────
	-- Maximum simultaneous in-flight bullets per player. Prevents a malicious
	-- client from flooding the server solver with thousands of bullets by
	-- replaying fire requests faster than bullets terminate.
	DEFAULT_MAX_CONCURRENT_PER_PLAYER = 20,

	-- ── Drift Correction ─────────────────────────────────────────────────────
	-- Minimum stud distance between the local cosmetic bullet and the server
	-- authoritative position before DriftCorrector intervenes. Below this
	-- threshold, correction is skipped entirely — constant micro-corrections
	-- at sub-threshold drift produce visible jitter that is worse than the
	-- drift itself.
	DEFAULT_DRIFT_THRESHOLD = 2,

	-- Exponential blend rate: fraction of remaining drift closed per second.
	-- alpha = deltaTime * CorrectionRate in the lerp expression.
	-- 8.0 closes ~99.9% of a 2-stud gap within roughly 0.85 seconds without
	-- any visible teleport discontinuity.
	DEFAULT_CORRECTION_RATE = 8,

	-- ── State Sync Toggle ────────────────────────────────────────────────────
	-- When false, the server frame loop skips writing state entries entirely.
	-- Useful for games that handle reconciliation themselves, or for debugging.
	DEFAULT_REPLICATE_STATE = true,

	-- ── Outbound Batcher ─────────────────────────────────────────────────────
	-- Initial byte capacity for each per-player outbound cursor buffer.
	-- The buffer grows (doubles) on overflow — this size covers a typical frame
	-- with a few fire/hit events plus a full state batch without reallocation.
	OUTBOUND_BUFFER_INITIAL = 512,
	-- Byte budget per bullet entry in StateBatcher output buffers.
	-- Layout: castId(u32=4) + px(f32=4) + py(f32=4) + pz(f32=4)
	--       + vx(f32=4) + vy(f32=4) + vz(f32=4) = 28 bytes total.
	STATE_ENTRY_BYTES = 28,

	-- StateBatch header size. Layout: frameId(u32=4) + count(u32=4) + frameDelta(f32=4) = 12 bytes.
	-- frameDelta is the server Heartbeat DeltaTime for this frame in seconds.
	-- The client uses it as the correction alpha denominator instead of os.clock()
	-- wall-time difference, which is wrong under burst packet delivery (two batches
	-- arriving the same frame collapse DeltaTime to near-zero, making alpha ~0).
	STATE_BATCH_HEADER_BYTES = 12,

	-- Maximum bullet count per state batch. 128 × 28 = 3 584 bytes, well
	-- within Roblox's ~64 KB remote payload limit. Chosen to cover the
	-- realistic peak of a crowded server fight (8 players × ~16 bullets each)
	-- with comfortable headroom for simultaneous explosions.
	MAX_STATE_BATCH_SIZE = 128,

	-- ── Serializer Primitive Sizes ────────────────────────────────────────────
	-- Named constants for every primitive byte width. BlinkSchema uses these
	-- to pre-compute buffer sizes at module load rather than inline literals,
	-- which would rot silently if the layout changed.
	BYTES_VECTOR3   = 12,   -- 3 × f32 (x, y, z)
	BYTES_F32       =  4,
	BYTES_F64       =  8,
	BYTES_TIMESTAMP =  8,   -- f64 — workspace:GetServerTimeNow() sub-millisecond
	BYTES_U8        =  1,
	BYTES_U16       =  2,
	BYTES_U32       =  4,
	BYTES_BOOL      =  1,

	-- ── Payload Byte Sizes ────────────────────────────────────────────────────
	-- Pre-computed total sizes used by BlinkSchema.Encode* to call
	-- buffer.create() with exact capacity rather than a dynamic size.
	-- Dynamic sizes inside encode functions would force a reallocation on
	-- every call — a per-fire allocation that accumulates under high fire rates.

	-- origin(12) + direction(12) + speed(4) + behaviorHash(2)
	-- + castId(4) + localCastId(4) + timestamp(8) = 46 bytes.
	-- localCastId is the client's local cosmetic cast ID, echoed back in
	-- fire replication so the shooter can migrate their tracker entry from
	-- LocalCastId → ServerCastId. Value is 0 in client→server direction is
	-- ignored; the field only carries meaning in server→client replication.
	FIRE_PAYLOAD_BYTES = 46,

	-- castId(4) + position(12) + normal(12) + velocity(12) + timestamp(8)
	-- = 48 bytes.
	HIT_PAYLOAD_BYTES = 48,

	-- ── Behavior Hash ────────────────────────────────────────────────────────
	-- Sentinel returned by BehaviorRegistry.GetHash when the name is unknown.
	-- u16 value 0 is reserved as "invalid" — no legitimate registration may
	-- claim this value. FireValidator rejects any payload carrying hash 0.
	UNKNOWN_BEHAVIOR_HASH = 0,

	-- ── Latency Buffer ───────────────────────────────────────────────────────
	-- Player:GetNetworkPing() returns round-trip time in seconds.
	-- We halve it to get the estimated one-way (server → client) delay.
	RTT_HALF_DIVISOR = 2,

	-- Fallback full round-trip time used when Stats:GetStatValue cannot produce
	-- a measurement (e.g. in Studio, or before the first ping completes).
	-- GetDelay() halves this via RTT_HALF_DIVISOR to get the one-way estimate.
	-- 100 ms is a typical moderate-latency baseline.
	DEFAULT_RTT_FALLBACK_SECONDS = 0.1,

	-- ── FireValidator Cancel Ceiling ─────────────────────────────────────────
	-- Unused — reserved for a future hook layer. Not referenced by any module.
	-- FIRE_REQUEST_CANCEL_LIMIT = 3,

})