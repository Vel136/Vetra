--!strict
--!optimize 2
--!native

local Serializer = {}

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

function Serializer.WriteF32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadF32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf32(Buffer, Offset), Offset + 4
end

function Serializer.WriteF64(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadF64(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

function Serializer.WriteU8(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu8(Buffer, Offset, Value)
	return Offset + 1
end

function Serializer.ReadU8(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu8(Buffer, Offset), Offset + 1
end

function Serializer.WriteU16(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu16(Buffer, Offset, Value)
	return Offset + 2
end

function Serializer.ReadU16(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu16(Buffer, Offset), Offset + 2
end

function Serializer.WriteU32(Buffer: buffer, Offset: number, Value: number): number
	buffer_writeu32(Buffer, Offset, Value)
	return Offset + 4
end

function Serializer.ReadU32(Buffer: buffer, Offset: number): (number, number)
	return buffer_readu32(Buffer, Offset), Offset + 4
end

function Serializer.WriteBool(Buffer: buffer, Offset: number, Value: boolean): number
	buffer_writeu8(Buffer, Offset, if Value then 1 else 0)
	return Offset + 1
end

function Serializer.ReadBool(Buffer: buffer, Offset: number): (boolean, number)
	return buffer_readu8(Buffer, Offset) ~= 0, Offset + 1
end

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

function Serializer.WriteCFrame(Buffer: buffer, Offset: number, Value: CFrame): number
	local Rx, Ry, Rz = Value.RightVector.X, Value.RightVector.Y, Value.RightVector.Z
	local Ux, Uy, Uz = Value.UpVector.X,    Value.UpVector.Y,    Value.UpVector.Z
	buffer_writef32(Buffer, Offset,      Rx)
	buffer_writef32(Buffer, Offset + 4,  Ry)
	buffer_writef32(Buffer, Offset + 8,  Rz)
	buffer_writef32(Buffer, Offset + 12, Ux)
	buffer_writef32(Buffer, Offset + 16, Uy)
	buffer_writef32(Buffer, Offset + 20, Uz)
	return Offset + 24
end

function Serializer.ReadCFrame(Buffer: buffer, Offset: number): (CFrame, number)
	local Rx = buffer_readf32(Buffer, Offset)
	local Ry = buffer_readf32(Buffer, Offset + 4)
	local Rz = buffer_readf32(Buffer, Offset + 8)
	local Ux = buffer_readf32(Buffer, Offset + 12)
	local Uy = buffer_readf32(Buffer, Offset + 16)
	local Uz = buffer_readf32(Buffer, Offset + 20)
	local Right = Vector3.new(Rx, Ry, Rz)
	local Up    = Vector3.new(Ux, Uy, Uz)
	return CFrame.fromMatrix(Vector3.zero, Right, Up), Offset + 24
end

function Serializer.WriteTimestamp(Buffer: buffer, Offset: number, Value: number): number
	buffer_writef64(Buffer, Offset, Value)
	return Offset + 8
end

function Serializer.ReadTimestamp(Buffer: buffer, Offset: number): (number, number)
	return buffer_readf64(Buffer, Offset), Offset + 8
end

local POSITION_ORIGIN = Vector3.new(0, 0, 0)
local POSITION_SCALE  = 10
local POSITION_OFFSET = 32767.5
local POSITION_MAX    = 65535

local DIR_STEPS = 255

function Serializer.WriteDirection(Buffer: buffer, Offset: number, Value: Vector3): number
	local yaw   = math.atan2(Value.X, Value.Z)
	local pitch = math.asin(math.clamp(Value.Y, -1, 1))
	local yawByte   = math.clamp(math.floor((yaw   + math.pi)     / (2 * math.pi) * DIR_STEPS + 0.5), 0, DIR_STEPS)
	local pitchByte = math.clamp(math.floor((pitch + math.pi / 2) / math.pi       * DIR_STEPS + 0.5), 0, DIR_STEPS)
	buffer_writeu8(Buffer, Offset,     yawByte)
	buffer_writeu8(Buffer, Offset + 1, pitchByte)
	return Offset + 2
end

function Serializer.ReadDirection(Buffer: buffer, Offset: number): (Vector3, number)
	local yawByte   = buffer_readu8(Buffer, Offset)
	local pitchByte = buffer_readu8(Buffer, Offset + 1)
	local yaw      = (yawByte   / DIR_STEPS) * (2 * math.pi) - math.pi
	local pitch    = (pitchByte / DIR_STEPS) * math.pi       - math.pi / 2
	local cosPitch = math.cos(pitch)
	return Vector3.new(math.sin(yaw) * cosPitch, math.sin(pitch), math.cos(yaw) * cosPitch), Offset + 2
end

function Serializer.WriteQuantizedPosition(Buffer: buffer, Offset: number, Value: Vector3): number
	local x = math.clamp(math.floor((Value.X - POSITION_ORIGIN.X) * POSITION_SCALE + POSITION_OFFSET), 0, POSITION_MAX)
	local y = math.clamp(math.floor((Value.Y - POSITION_ORIGIN.Y) * POSITION_SCALE + POSITION_OFFSET), 0, POSITION_MAX)
	local z = math.clamp(math.floor((Value.Z - POSITION_ORIGIN.Z) * POSITION_SCALE + POSITION_OFFSET), 0, POSITION_MAX)
	buffer_writeu16(Buffer, Offset,     x)
	buffer_writeu16(Buffer, Offset + 2, y)
	buffer_writeu16(Buffer, Offset + 4, z)
	return Offset + 6
end

function Serializer.ReadQuantizedPosition(Buffer: buffer, Offset: number): (Vector3, number)
	local x = (buffer_readu16(Buffer, Offset)     - POSITION_OFFSET) / POSITION_SCALE + POSITION_ORIGIN.X
	local y = (buffer_readu16(Buffer, Offset + 2) - POSITION_OFFSET) / POSITION_SCALE + POSITION_ORIGIN.Y
	local z = (buffer_readu16(Buffer, Offset + 4) - POSITION_OFFSET) / POSITION_SCALE + POSITION_ORIGIN.Z
	return Vector3.new(x, y, z), Offset + 6
end

return table.freeze(Serializer)
