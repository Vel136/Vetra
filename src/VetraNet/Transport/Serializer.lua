--!strict
--Serializer.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/Serializer.lua
    Low-level buffer primitive layer.

    Knows how to read and write raw types into a Roblox buffer.
    Has no knowledge of what a FirePayload or HitPayload is — only knows types:
    Vector3, f32, f64, u8, u16, u32, boolean, timestamp.

    Every function signature follows the pattern:
        Write*(buf, offset, value) → nextOffset
        Read*(buf, offset)        → (value, nextOffset)

    Keeping offset threading explicit (rather than storing a cursor in a
    closure) lets callers compose reads and writes without allocation and
    makes the byte layout of every payload visible at the call site.
]]

local Identity   = "Serializer"

local Serializer = {}
Serializer.__type = Identity

local SerializerMetatable = table.freeze({
	__index = Serializer,
})

-- ─── Cached Globals ──────────────────────────────────────────────────────────

-- Localise buffer API for native-compile inlining in hot encode/decode paths.
local buffer_writef32 = buffer.writef32
local buffer_writef64 = buffer.writef64
local buffer_writeu8  = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_writeu32 = buffer.writeu32
local buffer_readf32  = buffer.readf32
local buffer_readf64  = buffer.readf64
local buffer_readu8   = buffer.readu8
local buffer_readu16  = buffer.readu16
local buffer_readu32  = buffer.readu32

local string_format   = string.format

-- ─── Primitive Writers ────────────────────────────────────────────────────────

-- f32 — single-precision float. Used for positions and velocities.
-- f32 gives ~7 significant decimal digits which is sufficient for stud-level
-- precision across map-scale distances. Using f64 for positions would double
-- the per-bullet wire cost for sub-millimetre accuracy nobody can perceive.
function Serializer.WriteF32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadF32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf32(Buffer, Offset), Offset + 4
end

-- f64 — double-precision float. Used only for timestamps where sub-millisecond
-- precision is required to reconstruct trajectories and compute anti-rewind ages.
function Serializer.WriteF64(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadF64(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

-- u8 — 8-bit unsigned integer [0, 255].
function Serializer.WriteU8(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu8(Buffer, Offset, Value)
	return Offset + 1
end

function Serializer.ReadU8(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu8(Buffer, Offset), Offset + 1
end

-- u16 — 16-bit unsigned integer [0, 65 535]. Used for behavior hashes.
-- 65 535 unique behaviors is far beyond any realistic game's weapon count.
function Serializer.WriteU16(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu16(Buffer, Offset, Value)
	return Offset + 2
end

function Serializer.ReadU16(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu16(Buffer, Offset), Offset + 2
end

-- u32 — 32-bit unsigned integer [0, 4 294 967 295]. Used for cast IDs and
-- frame counters. A 32-bit cast ID space is essentially inexhaustible —
-- at 1 000 fires per second it wraps after ~49 days, which is fine.
function Serializer.WriteU32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadU32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu32(Buffer, Offset), Offset + 4
end

-- boolean — packed as a single byte (0 = false, 1 = true).
function Serializer.WriteBool(Buffer: buffer, Offset: number, Value: boolean): number
	buffer_writeu8(Buffer, Offset, if Value then 1 else 0)
	return Offset + 1
end

function Serializer.ReadBool(Buffer: buffer, Offset: number): (boolean, number)
	return buffer_readu8(Buffer, Offset) ~= 0, Offset + 1
end

-- Vector3 — three consecutive f32 values (x, y, z). 12 bytes total.
-- Components are written in XYZ order consistently; swapping the order would
-- silently corrupt any payload that includes a Vector3.
function Serializer.WriteVector3(Buffer: buffer, Offset: number, Value: Vector3): number
	buffer_writef32(Buffer, Offset,     Value.X)
	buffer_writef32(Buffer, Offset + 4, Value.Y)
	buffer_writef32(Buffer, Offset + 8, Value.Z)
	return Offset + 12
end

function Serializer.ReadVector3(Buffer: buffer, Offset: number): (Vector3, number)
	local X = buffer_readf32(Buffer, Offset)
	local Y = buffer_readf32(Buffer, Offset + 4)
	local Z = buffer_readf32(Buffer, Offset + 8)
	return Vector3.new(X, Y, Z), Offset + 12
end

-- Timestamp — f64. workspace:GetServerTimeNow() returns a double-precision
-- value; storing it as f32 would lose 10–100 ms of precision, which is
-- enough to corrupt anti-rewind guard checks on fast bullets.
function Serializer.WriteTimestamp(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadTimestamp(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(Serializer, {
	__index = function(_, Key)
		error(string_format("[VetraNet.Serializer] Nil key '%s'", tostring(Key)), 2)
	end,
	__newindex = function(_, Key, _Value)
		error(string_format("[VetraNet.Serializer] Write to protected key '%s'", tostring(Key)), 2)
	end,
}))
