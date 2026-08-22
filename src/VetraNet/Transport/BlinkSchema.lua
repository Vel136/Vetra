--!strict
--!optimize 2
--!native

local BlinkSchema = {}

local Types     = script.Parent.Parent.Types
local Transport = script.Parent

local Constants  = require(Types.Constants)
local Serializer = require(Transport.Serializer)

local math_min      = math.min
local math_floor    = math.floor
local math_clamp    = math.clamp
local table_create  = table.create

local FIRE_PAYLOAD_BYTES    = Constants.FIRE_PAYLOAD_BYTES
local HIT_PAYLOAD_BYTES     = Constants.HIT_PAYLOAD_BYTES
local STATE_ENTRY_BYTES     = Constants.STATE_ENTRY_BYTES
local MAX_STATE_BATCH       = Constants.MAX_STATE_BATCH_SIZE
local STATE_BATCH_HEADER_BYTES = Constants.STATE_BATCH_HEADER_BYTES

local function encodeVelocity(v: Vector3): (number, number, number)
	local mag = v.Magnitude
	if mag < 0.0001 then return 0, 0, 0 end
	local dir    = v / mag
	local yaw    = math.atan2(dir.X, dir.Z)
	local pitch  = math.asin(math_clamp(dir.Y, -1, 1))
	local yawB   = math_clamp(math_floor((yaw   + math.pi)     / (2 * math.pi) * 255 + 0.5), 0, 255)
	local pitchB = math_clamp(math_floor((pitch + math.pi / 2) / math.pi       * 255 + 0.5), 0, 255)
	local magU16 = math_clamp(math_floor(mag + 0.5), 0, 65535)
	return yawB, pitchB, magU16
end

local function decodeVelocity(yawB: number, pitchB: number, magU16: number): Vector3
	if magU16 == 0 then return Vector3.zero end
	local yaw   = (yawB   / 255) * (2 * math.pi) - math.pi
	local pitch = (pitchB / 255) * math.pi       - math.pi / 2
	local cos   = math.cos(pitch)
	local dir   = Vector3.new(math.sin(yaw) * cos, math.sin(pitch), math.cos(yaw) * cos)
	return dir * magU16
end

function BlinkSchema.EncodeFire(
	Origin         : Vector3,
	Direction      : Vector3,
	Speed          : number,
	BehaviorHash   : number,
	ModifierBuffer : buffer,
	CastId         : number,
	LocalCastId    : number?
): buffer
	local ModBufLen = buffer.len(ModifierBuffer)
	local Total     = FIRE_PAYLOAD_BYTES + 2 + ModBufLen
	local Buffer    = buffer.create(Total)
	local Offset    = 0
	Offset = Serializer.WriteQuantizedPosition(Buffer, Offset, Origin)
	Offset = Serializer.WriteDirection(Buffer, Offset, Direction)
	Offset = Serializer.WriteU16(Buffer, Offset, math_clamp(math_floor(Speed + 0.5), 0, 65535))
	Offset = Serializer.WriteU16(Buffer, Offset, BehaviorHash)
	Offset = Serializer.WriteU16(Buffer, Offset, CastId)
	Offset = Serializer.WriteU16(Buffer, Offset, LocalCastId or 0)
	Offset = Serializer.WriteU16(Buffer, Offset, ModBufLen)
	if ModBufLen > 0 then
		buffer.copy(Buffer, Offset, ModifierBuffer, 0, ModBufLen)
	end
	return Buffer
end

function BlinkSchema.DecodeFire(Buffer: buffer): any
	local Offset = 0
	local Origin, OffsetA           = Serializer.ReadQuantizedPosition(Buffer, Offset)  Offset = OffsetA
	local Direction, OffsetB        = Serializer.ReadDirection(Buffer, Offset)          Offset = OffsetB
	local Speed, OffsetC            = Serializer.ReadU16(Buffer, Offset)                Offset = OffsetC
	local BehaviorHash, OffsetD     = Serializer.ReadU16(Buffer, Offset)                Offset = OffsetD
	local CastId, OffsetE           = Serializer.ReadU16(Buffer, Offset)                Offset = OffsetE
	local LocalCastId, OffsetF      = Serializer.ReadU16(Buffer, Offset)                Offset = OffsetF
	local ModBufLen, OffsetG        = Serializer.ReadU16(Buffer, Offset)                Offset = OffsetG

	local ModifierBuffer = buffer.create(ModBufLen)
	if ModBufLen > 0 then
		buffer.copy(ModifierBuffer, 0, Buffer, Offset, ModBufLen)
	end

	return {
		Origin         = Origin,
		Direction      = Direction,
		Speed          = Speed,
		BehaviorHash   = BehaviorHash,
		ModifierBuffer = ModifierBuffer,
		CastId         = CastId,
		LocalCastId    = LocalCastId,
	}
end

function BlinkSchema.EncodeHit(
	CastId   : number,
	Position : Vector3,
	Normal   : Vector3,
	Velocity : Vector3
): buffer
	local Buffer = buffer.create(HIT_PAYLOAD_BYTES)
	local Offset = 0
	local velYaw, velPitch, velMag = encodeVelocity(Velocity)
	Offset = Serializer.WriteU16(Buffer, Offset, CastId)
	Offset = Serializer.WriteQuantizedPosition(Buffer, Offset, Position)
	Offset = Serializer.WriteDirection(Buffer, Offset, Normal)
	Offset = Serializer.WriteU8(Buffer, Offset, velYaw)
	Offset = Serializer.WriteU8(Buffer, Offset, velPitch)
	Serializer.WriteU16(Buffer, Offset, velMag)
	return Buffer
end

function BlinkSchema.DecodeHit(Buffer: buffer): any
	local Offset = 0
	local CastId, OffsetA    = Serializer.ReadU16(Buffer, Offset)               Offset = OffsetA
	local Position, OffsetB  = Serializer.ReadQuantizedPosition(Buffer, Offset) Offset = OffsetB
	local Normal, OffsetC    = Serializer.ReadDirection(Buffer, Offset)         Offset = OffsetC
	local VelYaw, OffsetD    = Serializer.ReadU8(Buffer, Offset)                Offset = OffsetD
	local VelPitch, OffsetE  = Serializer.ReadU8(Buffer, Offset)                Offset = OffsetE
	local VelMag, _          = Serializer.ReadU16(Buffer, Offset)
	return {
		CastId   = CastId,
		Position = Position,
		Normal   = Normal,
		Velocity = decodeVelocity(VelYaw, VelPitch, VelMag),
	}
end

function BlinkSchema.EncodeStateBatch(FrameId: number, States: { any }, Count: number?, FrameDelta: number?): buffer
	local EntryCount = math_min(Count or #States, MAX_STATE_BATCH)
	local Buffer     = buffer.create(STATE_BATCH_HEADER_BYTES + EntryCount * STATE_ENTRY_BYTES)
	local Offset     = 0
	Offset = Serializer.WriteU32(Buffer, Offset, FrameId)
	Offset = Serializer.WriteU32(Buffer, Offset, EntryCount)
	Offset = Serializer.WriteF32(Buffer, Offset, FrameDelta or 0)
	for Index = 1, EntryCount do
		local Entry = States[Index]
		local velYaw, velPitch, velMag = encodeVelocity(Entry.Velocity)
		Offset = Serializer.WriteU16(Buffer, Offset, Entry.CastId)
		Offset = Serializer.WriteQuantizedPosition(Buffer, Offset, Entry.Position)
		Offset = Serializer.WriteU8(Buffer, Offset, velYaw)
		Offset = Serializer.WriteU8(Buffer, Offset, velPitch)
		Offset = Serializer.WriteU16(Buffer, Offset, velMag)
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
		local CastId, OffsetD   = Serializer.ReadU16(Buffer, Offset)               Offset = OffsetD
		local Position, OffsetE = Serializer.ReadQuantizedPosition(Buffer, Offset) Offset = OffsetE
		local VelYaw, OffsetF   = Serializer.ReadU8(Buffer, Offset)                Offset = OffsetF
		local VelPitch, OffsetG = Serializer.ReadU8(Buffer, Offset)                Offset = OffsetG
		local VelMag, OffsetH   = Serializer.ReadU16(Buffer, Offset)               Offset = OffsetH
		States[Index] = {
			CastId   = CastId,
			Position = Position,
			Velocity = decodeVelocity(VelYaw, VelPitch, VelMag),
		}
	end
	return {
		FrameId    = FrameId,
		FrameDelta = FrameDelta,
		States     = States,
	}
end

return table.freeze(BlinkSchema)
