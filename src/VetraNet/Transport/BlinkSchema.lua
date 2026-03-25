--!strict
--BlinkSchema.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/BlinkSchema.lua
    High-level payload encode / decode layer.

    Knows the exact structure of FirePayload, HitPayload, StateEntry, and
    StateBatch. Calls Serializer primitives to read and write them. This layer
    is the only place in VetraNet where payload byte layouts are hardcoded —
    changing a layout requires editing only this file plus Constants.lua.

    Buffer sizes are pre-computed from Constants at module load. Encode
    functions call buffer.create() with exact capacity (never dynamic) so
    the allocator runs exactly once per encode call with no over-allocation.

    StateBatch encoding pre-allocates for MAX_STATE_BATCH_SIZE entries and
    writes a count prefix so the decoder knows how many entries follow.
    Using a fixed-size buffer with a count prefix is cheaper than a dynamic
    buffer that reallocates as entries are appended.
]]

local Identity    = "BlinkSchema"

local BlinkSchema = {}
BlinkSchema.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Types     = script.Parent.Parent.Types
local Transport = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Types.Constants)
local Serializer = require(Transport.Serializer)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_min      = math.min
local table_create  = table.create
local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

-- FirePayload: origin(12) + direction(12) + speed(4) + behaviorHash(2)
--            + castId(4) + localCastId(4) + timestamp(8) = 46 bytes.
local FIRE_PAYLOAD_BYTES: number = Constants.FIRE_PAYLOAD_BYTES

-- HitPayload: castId(4) + position(12) + normal(12) + velocity(12)
--           + timestamp(8) = 48 bytes.
local HIT_PAYLOAD_BYTES: number = Constants.HIT_PAYLOAD_BYTES

-- StateBatch: frameId(u32=4) + count(u32=4) + N × stateEntry(28)
-- We allocate for the maximum possible count and pad unused entries with zeros.
-- This avoids reallocation entirely at the cost of a fixed upper-bound buffer.
local STATE_ENTRY_BYTES: number     = Constants.STATE_ENTRY_BYTES
local MAX_STATE_BATCH: number       = Constants.MAX_STATE_BATCH_SIZE
local STATE_BATCH_HEADER_BYTES      = Constants.STATE_BATCH_HEADER_BYTES   -- frameId(4) + count(4) + frameDelta(4) = 12
local STATE_BATCH_MAX_BYTES: number = STATE_BATCH_HEADER_BYTES + MAX_STATE_BATCH * STATE_ENTRY_BYTES

-- ─── FirePayload ─────────────────────────────────────────────────────────────

-- Encode a fire request into a fixed-size buffer.
-- layout: origin(12) | direction(12) | speed(4) | behaviorHash(2)
--        | castId(4) | localCastId(4) | timestamp(8)
--
-- castId      — server-authoritative cast ID (0 in client→server direction;
--               filled by ServerHooks before replication).
-- localCastId — client's local cosmetic cast ID (set by Client.Fire, echoed
--               back in server→client replication so the shooter can migrate
--               their CosmeticTracker entry from LocalCastId to ServerCastId).
--               Always 0 in client→server direction (server ignores it).
function BlinkSchema.EncodeFire(
	Origin       : Vector3,
	Direction    : Vector3,
	Speed        : number,
	BehaviorHash : number,
	CastId       : number,
	Timestamp    : number,
	LocalCastId  : number?
): buffer
	local Buffer = buffer.create(FIRE_PAYLOAD_BYTES)
	local Offset = 0
	Offset = Serializer.WriteVector3(Buffer, Offset, Origin)
	Offset = Serializer.WriteVector3(Buffer, Offset, Direction)
	Offset = Serializer.WriteF32(Buffer, Offset, Speed)
	Offset = Serializer.WriteU16(Buffer, Offset, BehaviorHash)
	Offset = Serializer.WriteU32(Buffer, Offset, CastId)
	Offset = Serializer.WriteU32(Buffer, Offset, LocalCastId or 0)
	Serializer.WriteTimestamp(Buffer, Offset, Timestamp)
	return Buffer
end

function BlinkSchema.DecodeFire(Buffer: buffer): any
	local Offset = 0
	local Origin, OffsetA       = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetA
	local Direction, OffsetB    = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetB
	local Speed, OffsetC        = Serializer.ReadF32(Buffer, Offset)       Offset = OffsetC
	local BehaviorHash, OffsetD = Serializer.ReadU16(Buffer, Offset)       Offset = OffsetD
	local CastId, OffsetE       = Serializer.ReadU32(Buffer, Offset)       Offset = OffsetE
	local LocalCastId, OffsetF  = Serializer.ReadU32(Buffer, Offset)       Offset = OffsetF
	local Timestamp, _          = Serializer.ReadTimestamp(Buffer, Offset)
	return {
		Origin       = Origin,
		Direction    = Direction,
		Speed        = Speed,
		BehaviorHash = BehaviorHash,
		CastId       = CastId,
		LocalCastId  = LocalCastId,
		Timestamp    = Timestamp,
	}
end

-- ─── HitPayload ──────────────────────────────────────────────────────────────

-- layout: castId(4) | position(12) | normal(12) | velocity(12) | timestamp(8)
function BlinkSchema.EncodeHit(
	CastId    : number,
	Position  : Vector3,
	Normal    : Vector3,
	Velocity  : Vector3,
	Timestamp : number
): buffer
	local Buffer    = buffer.create(HIT_PAYLOAD_BYTES)
	local Offset = 0
	Offset = Serializer.WriteU32(Buffer, Offset, CastId)
	Offset = Serializer.WriteVector3(Buffer, Offset, Position)
	Offset = Serializer.WriteVector3(Buffer, Offset, Normal)
	Offset = Serializer.WriteVector3(Buffer, Offset, Velocity)
	Serializer.WriteTimestamp(Buffer, Offset, Timestamp)
	return Buffer
end

function BlinkSchema.DecodeHit(Buffer: buffer): any
	local Offset = 0
	local CastId, OffsetA   = Serializer.ReadU32(Buffer, Offset)       Offset = OffsetA
	local Position, OffsetB = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetB
	local Normal, OffsetC   = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetC
	local Velocity, OffsetD = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetD
	local Timestamp, _      = Serializer.ReadTimestamp(Buffer, Offset)
	return {
		CastId    = CastId,
		Position  = Position,
		Normal    = Normal,
		Velocity  = Velocity,
		Timestamp = Timestamp,
	}
end

-- ─── StateBatch ──────────────────────────────────────────────────────────────

-- Encode a batch of state entries into a fixed-size buffer.
-- layout: frameId(4) | count(4) | frameDelta(4) | [castId(4) | px(4) | py(4) | pz(4) | vx(4) | vy(4) | vz(4)] × N
--
-- The buffer is always STATE_BATCH_MAX_BYTES large regardless of N.
-- The count field tells the decoder how many valid entries to read.
-- frameDelta is the server Heartbeat DeltaTime (seconds, f32). The client uses
-- it directly as the correction alpha base instead of os.clock() wall-time
-- diff, which collapses to near-zero when two batches arrive in the same frame.
-- Unused trailing bytes are zero (Roblox buffer.create initialises to zero).
--
-- Count is passed explicitly rather than using #States because the States table
-- may be pre-allocated (table.create) with zeroed-but-non-nil slots beyond the
-- active count. Using #States on such a table returns the full pre-allocated
-- size, not the number of valid entries written this frame.
function BlinkSchema.EncodeStateBatch(FrameId: number, States: { any }, Count: number?, FrameDelta: number?): buffer
	local Buffer     = buffer.create(STATE_BATCH_MAX_BYTES)
	local EntryCount = math_min(Count or #States, MAX_STATE_BATCH)
	local Offset     = 0
	Offset = Serializer.WriteU32(Buffer, Offset, FrameId)
	Offset = Serializer.WriteU32(Buffer, Offset, EntryCount)
	Offset = Serializer.WriteF32(Buffer, Offset, FrameDelta or 0)
	for Index = 1, EntryCount do
		local Entry = States[Index]
		Offset = Serializer.WriteU32(Buffer, Offset, Entry.CastId)
		Offset = Serializer.WriteVector3(Buffer, Offset, Entry.Position)
		Offset = Serializer.WriteVector3(Buffer, Offset, Entry.Velocity)
	end
	return Buffer
end

function BlinkSchema.DecodeStateBatch(Buffer: buffer): any
	local Offset = 0
	local FrameId, OffsetA    = Serializer.ReadU32(Buffer, Offset)   Offset = OffsetA
	local Count, OffsetB      = Serializer.ReadU32(Buffer, Offset)   Offset = OffsetB
	local FrameDelta, OffsetC = Serializer.ReadF32(Buffer, Offset)   Offset = OffsetC
	local States              = table_create(Count)
	for Index = 1, Count do
		local CastId, OffsetD   = Serializer.ReadU32(Buffer, Offset)       Offset = OffsetD
		local Position, OffsetE = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetE
		local Velocity, OffsetF = Serializer.ReadVector3(Buffer, Offset)   Offset = OffsetF
		States[Index] = {
			CastId   = CastId,
			Position = Position,
			Velocity = Velocity,
		}
	end
	return {
		FrameId    = FrameId,
		FrameDelta = FrameDelta,
		States     = States,
	}
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(BlinkSchema, {
	__index = function(_, Key)
		error(string_format("[VetraNet.BlinkSchema] Nil key '%s'", tostring(Key)), 2)
	end,
	__newindex = function(_, Key, _Value)
		error(string_format("[VetraNet.BlinkSchema] Write to protected key '%s'", tostring(Key)), 2)
	end,
}))