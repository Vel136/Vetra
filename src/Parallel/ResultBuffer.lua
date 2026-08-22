--!strict
--!optimize 2
--!native


local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local VetraNet   = Vetra.VetraNet

local Constants  = require(Core.Constants)
local Serializer = require(VetraNet.Transport.Serializer)
local TypeDefinition = require(Vetra.Types)

type ParallelResult = TypeDefinition.ParallelResult

local ResultBuffer = {}

local PARALLEL_EVENT = Constants.PARALLEL_EVENT

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local EVENT_TO_INT: { [string]: number } = {
	[PARALLEL_EVENT.Travel]        = 0,
	[PARALLEL_EVENT.Hit]           = 1,
	[PARALLEL_EVENT.BouncePending] = 2,
	[PARALLEL_EVENT.Bounce]        = 3,
	[PARALLEL_EVENT.PiercePending] = 4,
	[PARALLEL_EVENT.DistanceEnd]   = 5,
	[PARALLEL_EVENT.SpeedEnd]      = 6,
	[PARALLEL_EVENT.TrajUpdate]    = 7,
	[PARALLEL_EVENT.Skip]          = 8,
	[PARALLEL_EVENT.DisplacementEnd] = 9,
}

local EVENT_TRAVEL_LITE = 10

local TRAVEL_LITE_OFF_ID       = 1
local TRAVEL_LITE_OFF_POSITION = 9
local TRAVEL_LITE_OFF_VELOCITY = 21
local TRAVEL_LITE_OFF_RUNTIME  = 33
local TRAVEL_LITE_SIZE         = 41

local EVENT_TRAVEL_HOMING_LITE = 11

local HOMING_LITE_OFF_ID              = 1
local HOMING_LITE_OFF_POSITION        = 9
local HOMING_LITE_OFF_VELOCITY        = 21
local HOMING_LITE_OFF_RUNTIME         = 33
local HOMING_LITE_OFF_HOMING_ELAPSED  = 41
local HOMING_LITE_OFF_TRAJ_ORIGIN     = 49
local HOMING_LITE_OFF_TRAJ_START_TIME = 61
local HOMING_LITE_SIZE                = 69

local EVENT_TRAJ_UPDATE_LITE = 12

local TRAJ_LITE_OFF_ID         = 1
local TRAJ_LITE_OFF_RUNTIME    = 9
local TRAJ_LITE_OFF_DISTANCE   = 17
local TRAJ_LITE_OFF_ORIGIN     = 25
local TRAJ_LITE_OFF_VELOCITY   = 37
local TRAJ_LITE_OFF_ACCEL      = 49
local TRAJ_LITE_OFF_START_TIME = 61
local TRAJ_LITE_SIZE           = 69

local EVENT_TRAJ_UPDATE_6DOF = 13

local EVENT_THROTTLE_STATE = 14

local THROTTLE_OFF_ID          = 1
local THROTTLE_OFF_RUNTIME     = 9
local THROTTLE_OFF_IS_THROTTLED = 17
local THROTTLE_SIZE            = 18

local ZERO_VECTOR_FALLBACK = Vector3.zero

local TRAJ_6DOF_OFF_RIGHT   = 69
local TRAJ_6DOF_OFF_UP      = 81
local TRAJ_6DOF_OFF_ANGVEL  = 93
local TRAJ_6DOF_OFF_AOA     = 105
local TRAJ_6DOF_SIZE        = 109

local INT_TO_EVENT: { [number]: string } = {}
for EventName, Int in EVENT_TO_INT do
	INT_TO_EVENT[Int] = EventName
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local F_IS_LOD            = 0x00000001
local F_IS_SUPERSONIC     = 0x00000002
local F_HOMING_DISENGAGED = 0x00000004
local F_HOMING_ACQUIRED   = 0x00000008
local F_IS_CORNER_TRAP    = 0x00000010

local F_SPIN_VECTOR       = 0x00000020
local F_TRAVEL_POSITION   = 0x00000040
local F_TRAVEL_VELOCITY   = 0x00000080
local F_HIT_POSITION      = 0x00000100
local F_HIT_NORMAL        = 0x00000200
local F_HIT_MATERIAL      = 0x00000400
local F_RAY_ORIGIN        = 0x00000800
local F_PRE_BOUNCE_VEL    = 0x00001000
local F_VIS_RAY_ORIGIN    = 0x00002000
local F_PROVIDER_UNUSED   = 0x00004000
local F_REMAINING_RESIM   = 0x00008000
local F_TRAJECTORY        = 0x00010000
local F_VEL_DIR_EMA       = 0x00020000
local F_FIRST_BOUNCE_POS  = 0x00040000
local F_BOUNCE_HISTORY    = 0x00080000
local F_SIXDOF            = 0x00100000
local F_IS_TUMBLING       = 0x00200000
local F_TUMBLE_BEGAN      = 0x00400000
local F_TUMBLE_RECOVERED  = 0x00800000

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local MAX_HISTORY_ENTRIES = 64
ResultBuffer.MAX_RECORD_SIZE = 1
	+ 8
	+ 4
	+ 8 * 12
	+ 12 * 12
	+ (3 * 12 + 8)
	+ 8
	+ 2
	+ 8
	+ (2 + MAX_HISTORY_ENTRIES * 12)
	+ (24 + 12 + 8)

ResultBuffer.HEADER_SIZE = 4

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local buffer_writeu8  = buffer.writeu8
local buffer_writef32 = buffer.writef32
local buffer_writef64 = buffer.writef64
local buffer_readu8   = buffer.readu8
local buffer_readf32  = buffer.readf32
local buffer_readf64  = buffer.readf64

ResultBuffer.EVENT_TRAVEL_LITE   = EVENT_TRAVEL_LITE
ResultBuffer.TRAVEL_LITE_SIZE    = TRAVEL_LITE_SIZE
ResultBuffer.TRAVEL_LITE_OFF_ID       = TRAVEL_LITE_OFF_ID
ResultBuffer.TRAVEL_LITE_OFF_POSITION = TRAVEL_LITE_OFF_POSITION
ResultBuffer.TRAVEL_LITE_OFF_VELOCITY = TRAVEL_LITE_OFF_VELOCITY
ResultBuffer.TRAVEL_LITE_OFF_RUNTIME  = TRAVEL_LITE_OFF_RUNTIME

ResultBuffer.EVENT_TRAVEL_HOMING_LITE = EVENT_TRAVEL_HOMING_LITE
ResultBuffer.HOMING_LITE_SIZE         = HOMING_LITE_SIZE

ResultBuffer.EVENT_TRAJ_UPDATE_LITE = EVENT_TRAJ_UPDATE_LITE
ResultBuffer.TRAJ_LITE_SIZE         = TRAJ_LITE_SIZE
ResultBuffer.EVENT_TRAJ_UPDATE_6DOF = EVENT_TRAJ_UPDATE_6DOF
ResultBuffer.TRAJ_6DOF_SIZE         = TRAJ_6DOF_SIZE

ResultBuffer.EVENT_THROTTLE_STATE = EVENT_THROTTLE_STATE
ResultBuffer.THROTTLE_SIZE        = THROTTLE_SIZE

function ResultBuffer.PackThrottleState(
	Buffer: buffer, Offset: number,
	Id: number, TotalRuntime: number, IsThrottled: boolean
): number
	buffer_writeu8(Buffer, Offset, EVENT_THROTTLE_STATE)
	buffer_writef64(Buffer, Offset + THROTTLE_OFF_ID, Id)
	buffer_writef64(Buffer, Offset + THROTTLE_OFF_RUNTIME, TotalRuntime)
	buffer_writeu8(Buffer, Offset + THROTTLE_OFF_IS_THROTTLED, IsThrottled and 1 or 0)
	return Offset + THROTTLE_SIZE
end

function ResultBuffer.ReadThrottleState(Buffer: buffer, Offset: number): (number, number, boolean, number)
	local Id          = buffer_readf64(Buffer, Offset + THROTTLE_OFF_ID)
	local Runtime     = buffer_readf64(Buffer, Offset + THROTTLE_OFF_RUNTIME)
	local IsThrottled = buffer_readu8(Buffer, Offset + THROTTLE_OFF_IS_THROTTLED) == 1
	return Id, Runtime, IsThrottled, Offset + THROTTLE_SIZE
end

function ResultBuffer.PackTravelLite(
	Buffer: buffer, Offset: number,
	Id: number, Position: Vector3, Velocity: Vector3, TotalRuntime: number
): number
	buffer_writeu8(Buffer, Offset, EVENT_TRAVEL_LITE)
	buffer_writef64(Buffer, Offset + TRAVEL_LITE_OFF_ID, Id)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION,      Position.X)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION + 4,  Position.Y)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION + 8,  Position.Z)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY,      Velocity.X)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY + 4,  Velocity.Y)
	buffer_writef32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY + 8,  Velocity.Z)
	buffer_writef64(Buffer, Offset + TRAVEL_LITE_OFF_RUNTIME, TotalRuntime)
	return Offset + TRAVEL_LITE_SIZE
end

function ResultBuffer.PeekEventTag(Buffer: buffer, Offset: number): number
	return buffer_readu8(Buffer, Offset)
end

function ResultBuffer.ReadTravelLite(Buffer: buffer, Offset: number): (number, Vector3, Vector3, number, number)
	local Id = buffer_readf64(Buffer, Offset + TRAVEL_LITE_OFF_ID)
	local Px = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION)
	local Py = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION + 4)
	local Pz = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_POSITION + 8)
	local Vx = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY)
	local Vy = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY + 4)
	local Vz = buffer_readf32(Buffer, Offset + TRAVEL_LITE_OFF_VELOCITY + 8)
	local Runtime = buffer_readf64(Buffer, Offset + TRAVEL_LITE_OFF_RUNTIME)
	return Id, Vector3.new(Px, Py, Pz), Vector3.new(Vx, Vy, Vz), Runtime, Offset + TRAVEL_LITE_SIZE
end

function ResultBuffer.PackTravelHomingLite(
	Buffer: buffer, Offset: number,
	Id: number, Position: Vector3, Velocity: Vector3, TotalRuntime: number,
	HomingElapsed: number, TrajectoryOrigin: Vector3, TrajectoryStartTime: number
): number
	buffer_writeu8(Buffer, Offset, EVENT_TRAVEL_HOMING_LITE)
	buffer_writef64(Buffer, Offset + HOMING_LITE_OFF_ID, Id)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_POSITION,      Position.X)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_POSITION + 4,  Position.Y)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_POSITION + 8,  Position.Z)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY,      Velocity.X)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY + 4,  Velocity.Y)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY + 8,  Velocity.Z)
	buffer_writef64(Buffer, Offset + HOMING_LITE_OFF_RUNTIME, TotalRuntime)
	buffer_writef64(Buffer, Offset + HOMING_LITE_OFF_HOMING_ELAPSED, HomingElapsed)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN,      TrajectoryOrigin.X)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN + 4,  TrajectoryOrigin.Y)
	buffer_writef32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN + 8,  TrajectoryOrigin.Z)
	buffer_writef64(Buffer, Offset + HOMING_LITE_OFF_TRAJ_START_TIME, TrajectoryStartTime)
	return Offset + HOMING_LITE_SIZE
end

function ResultBuffer.ReadTravelHomingLite(Buffer: buffer, Offset: number): (
	number, Vector3, Vector3, number, number, Vector3, number, number
)
	local Id = buffer_readf64(Buffer, Offset + HOMING_LITE_OFF_ID)
	local Px = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_POSITION)
	local Py = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_POSITION + 4)
	local Pz = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_POSITION + 8)
	local Vx = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY)
	local Vy = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY + 4)
	local Vz = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_VELOCITY + 8)
	local Runtime = buffer_readf64(Buffer, Offset + HOMING_LITE_OFF_RUNTIME)
	local HomingElapsed = buffer_readf64(Buffer, Offset + HOMING_LITE_OFF_HOMING_ELAPSED)
	local TOx = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN)
	local TOy = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN + 4)
	local TOz = buffer_readf32(Buffer, Offset + HOMING_LITE_OFF_TRAJ_ORIGIN + 8)
	local TrajStartTime = buffer_readf64(Buffer, Offset + HOMING_LITE_OFF_TRAJ_START_TIME)
	return Id, Vector3.new(Px, Py, Pz), Vector3.new(Vx, Vy, Vz), Runtime,
		HomingElapsed, Vector3.new(TOx, TOy, TOz), TrajStartTime,
		Offset + HOMING_LITE_SIZE
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function ResultBuffer.PackTrajUpdateLite(
	Buffer: buffer, Offset: number,
	Id: number, TotalRuntime: number, DistanceCovered: number,
	Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3, StartTime: number,
	Orientation: CFrame?, AngularVelocity: Vector3?, AngleOfAttack: number?
): number
	buffer_writeu8(Buffer, Offset, Orientation and EVENT_TRAJ_UPDATE_6DOF or EVENT_TRAJ_UPDATE_LITE)
	buffer_writef64(Buffer, Offset + TRAJ_LITE_OFF_ID, Id)
	buffer_writef64(Buffer, Offset + TRAJ_LITE_OFF_RUNTIME, TotalRuntime)
	buffer_writef64(Buffer, Offset + TRAJ_LITE_OFF_DISTANCE, DistanceCovered)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN,       Origin.X)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN + 4,   Origin.Y)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN + 8,   Origin.Z)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY,     InitialVelocity.X)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY + 4, InitialVelocity.Y)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY + 8, InitialVelocity.Z)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL,        Acceleration.X)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL + 4,    Acceleration.Y)
	buffer_writef32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL + 8,    Acceleration.Z)
	buffer_writef64(Buffer, Offset + TRAJ_LITE_OFF_START_TIME, StartTime)

	if Orientation then
		local Rx, Ry, Rz, Ux, Uy, Uz = Orientation.RightVector.X, Orientation.RightVector.Y, Orientation.RightVector.Z,
			Orientation.UpVector.X, Orientation.UpVector.Y, Orientation.UpVector.Z
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT,     Rx)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT + 4, Ry)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT + 8, Rz)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_UP,        Ux)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_UP + 4,    Uy)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_UP + 8,    Uz)
		local AV = AngularVelocity or ZERO_VECTOR_FALLBACK
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL,     AV.X)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL + 4, AV.Y)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL + 8, AV.Z)
		buffer_writef32(Buffer, Offset + TRAJ_6DOF_OFF_AOA, AngleOfAttack or 0)
		return Offset + TRAJ_6DOF_SIZE
	end

	return Offset + TRAJ_LITE_SIZE
end

function ResultBuffer.ReadTrajUpdate6DOFTail(Buffer: buffer, Offset: number): (CFrame, Vector3, number, number)
	local Rx = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT)
	local Ry = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT + 4)
	local Rz = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_RIGHT + 8)
	local Ux = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_UP)
	local Uy = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_UP + 4)
	local Uz = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_UP + 8)
	local Ax = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL)
	local Ay = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL + 4)
	local Az = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_ANGVEL + 8)
	local AoA = buffer_readf32(Buffer, Offset + TRAJ_6DOF_OFF_AOA)
	local Orientation = CFrame.fromMatrix(
		ZERO_VECTOR_FALLBACK,
		Vector3.new(Rx, Ry, Rz),
		Vector3.new(Ux, Uy, Uz)
	)
	return Orientation, Vector3.new(Ax, Ay, Az), AoA, Offset + TRAJ_6DOF_SIZE
end

function ResultBuffer.ReadTrajUpdateLite(Buffer: buffer, Offset: number): (
	number, number, number, Vector3, Vector3, Vector3, number
)
	local Id       = buffer_readf64(Buffer, Offset + TRAJ_LITE_OFF_ID)
	local Runtime  = buffer_readf64(Buffer, Offset + TRAJ_LITE_OFF_RUNTIME)
	local Distance = buffer_readf64(Buffer, Offset + TRAJ_LITE_OFF_DISTANCE)
	local Ox = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN)
	local Oy = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN + 4)
	local Oz = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ORIGIN + 8)
	local Vx = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY)
	local Vy = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY + 4)
	local Vz = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_VELOCITY + 8)
	local Ax = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL)
	local Ay = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL + 4)
	local Az = buffer_readf32(Buffer, Offset + TRAJ_LITE_OFF_ACCEL + 8)
	local StartTime = buffer_readf64(Buffer, Offset + TRAJ_LITE_OFF_START_TIME)
	return Id, Runtime, Distance,
		Vector3.new(Ox, Oy, Oz), Vector3.new(Vx, Vy, Vz), Vector3.new(Ax, Ay, Az),
		StartTime
end

function ResultBuffer.PackEvent(Buffer: buffer, Offset: number, Result: ParallelResult): number
	local Cursor = Offset

	Cursor = Serializer.WriteU8(Buffer, Cursor, EVENT_TO_INT[Result.Event] or 8)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.Id)

	local Flags = 0
	if Result.IsLOD            then Flags += F_IS_LOD            end
	if Result.IsSupersonic     then Flags += F_IS_SUPERSONIC     end
	if Result.HomingDisengaged then Flags += F_HOMING_DISENGAGED end
	if Result.HomingAcquired   then Flags += F_HOMING_ACQUIRED   end
	if Result.IsCornerTrap     then Flags += F_IS_CORNER_TRAP    end
	if Result.IsTumbling       then Flags += F_IS_TUMBLING       end
	if Result.TumbleBegan      then Flags += F_TUMBLE_BEGAN      end
	if Result.TumbleRecovered  then Flags += F_TUMBLE_RECOVERED  end

	if Result.SpinVector             ~= nil then Flags += F_SPIN_VECTOR      end
	if Result.TravelPosition         ~= nil then Flags += F_TRAVEL_POSITION  end
	if Result.TravelVelocity         ~= nil then Flags += F_TRAVEL_VELOCITY  end
	if Result.HitPosition            ~= nil then Flags += F_HIT_POSITION     end
	if Result.HitNormal              ~= nil then Flags += F_HIT_NORMAL       end
	if Result.HitMaterial            ~= nil then Flags += F_HIT_MATERIAL     end
	if Result.RayOrigin              ~= nil then Flags += F_RAY_ORIGIN       end
	if Result.PreBounceVelocity      ~= nil then Flags += F_PRE_BOUNCE_VEL   end
	if Result.VisualizationRayOrigin ~= nil then Flags += F_VIS_RAY_ORIGIN   end
	if Result.RemainingResimDelta    ~= nil then Flags += F_REMAINING_RESIM  end
	if Result.Trajectory             ~= nil then Flags += F_TRAJECTORY       end
	if Result.VelocityDirectionEMA   ~= nil then Flags += F_VEL_DIR_EMA      end
	if Result.FirstBouncePosition    ~= nil then Flags += F_FIRST_BOUNCE_POS end
	if Result.BouncePositionHistory  ~= nil then Flags += F_BOUNCE_HISTORY   end
	if Result.Orientation            ~= nil then Flags += F_SIXDOF           end

	Cursor = Serializer.WriteU32(Buffer, Cursor, Flags)

	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.TotalRuntime or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.DistanceCovered or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.LastDragRecalcTime or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.HomingElapsed or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.CurrentSegmentSize or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.BouncesThisFrame or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.LODFrameAccumulator or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.LODDeltaAccumulator or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.SpatialFrameAccumulator or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.SpatialDeltaAccumulator or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.BouncePositionHead or 0)
	Cursor = Serializer.WriteF64(Buffer, Cursor, Result.CornerBounceCount or 0)

	if Result.SpinVector             ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.SpinVector)             end
	if Result.TravelPosition         ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.TravelPosition)         end
	if Result.TravelVelocity         ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.TravelVelocity)         end
	if Result.HitPosition            ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.HitPosition)            end
	if Result.HitNormal              ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.HitNormal)              end
	if Result.RayOrigin              ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.RayOrigin)              end
	if Result.PreBounceVelocity      ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.PreBounceVelocity)      end
	if Result.VisualizationRayOrigin ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.VisualizationRayOrigin) end
	if Result.VelocityDirectionEMA   ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.VelocityDirectionEMA)   end
	if Result.FirstBouncePosition    ~= nil then Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.FirstBouncePosition)    end

	if Result.HitNormal ~= nil then
		Cursor = Serializer.WriteF64(Buffer, Cursor, Result.ImpactDot or -1)
	end

	if Result.HitMaterial ~= nil then
		Cursor = Serializer.WriteU16(Buffer, Cursor, Result.HitMaterial.Value)
	end

	if Result.RemainingResimDelta ~= nil then
		Cursor = Serializer.WriteF64(Buffer, Cursor, Result.RemainingResimDelta)
	end

	local Trajectory = Result.Trajectory
	if Trajectory ~= nil then
		Cursor = Serializer.WriteVector3(Buffer, Cursor, Trajectory.Origin)
		Cursor = Serializer.WriteVector3(Buffer, Cursor, Trajectory.InitialVelocity)
		Cursor = Serializer.WriteVector3(Buffer, Cursor, Trajectory.Acceleration)
		Cursor = Serializer.WriteF64(Buffer, Cursor, Trajectory.StartTime)
	end

	local History = Result.BouncePositionHistory
	if History ~= nil then
		local Count = #History
		if Count > MAX_HISTORY_ENTRIES then Count = MAX_HISTORY_ENTRIES end
		Cursor = Serializer.WriteU16(Buffer, Cursor, Count)
		for Index = 1, Count do
			Cursor = Serializer.WriteVector3(Buffer, Cursor, History[Index])
		end
	end

	if Result.Orientation ~= nil then
		Cursor = Serializer.WriteCFrame(Buffer, Cursor, Result.Orientation)
		Cursor = Serializer.WriteVector3(Buffer, Cursor, Result.AngularVelocity or Vector3.zero)
		Cursor = Serializer.WriteF64(Buffer, Cursor, Result.AngleOfAttack or 0)
	end

	return Cursor
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function ResultBuffer.UnpackEvent(Buffer: buffer, Offset: number): (any, number)
	local Cursor = Offset

	local EventInt, Id, Flags
	EventInt, Cursor = Serializer.ReadU8(Buffer, Cursor)
	Id,       Cursor = Serializer.ReadF64(Buffer, Cursor)
	Flags,    Cursor = Serializer.ReadU32(Buffer, Cursor)

	local Event: any = {}
	Event.Id    = Id
	Event.Event = INT_TO_EVENT[EventInt]

	Event.IsLOD            = bit32.band(Flags, F_IS_LOD)            ~= 0
	Event.IsSupersonic     = bit32.band(Flags, F_IS_SUPERSONIC)     ~= 0
	Event.HomingDisengaged = bit32.band(Flags, F_HOMING_DISENGAGED) ~= 0
	Event.HomingAcquired   = bit32.band(Flags, F_HOMING_ACQUIRED)   ~= 0
	Event.IsCornerTrap     = bit32.band(Flags, F_IS_CORNER_TRAP)    ~= 0
	Event.IsTumbling       = bit32.band(Flags, F_IS_TUMBLING)       ~= 0
	Event.TumbleBegan      = bit32.band(Flags, F_TUMBLE_BEGAN)      ~= 0
	Event.TumbleRecovered  = bit32.band(Flags, F_TUMBLE_RECOVERED)  ~= 0

	local TotalRuntime, DistanceCovered, LastDragRecalcTime, HomingElapsed
	local CurrentSegmentSize, BouncesThisFrame
	local LODFrameAccumulator, LODDeltaAccumulator, SpatialFrameAccumulator, SpatialDeltaAccumulator
	local BouncePositionHead, CornerBounceCount

	TotalRuntime,            Cursor = Serializer.ReadF64(Buffer, Cursor)
	DistanceCovered,         Cursor = Serializer.ReadF64(Buffer, Cursor)
	LastDragRecalcTime,      Cursor = Serializer.ReadF64(Buffer, Cursor)
	HomingElapsed,           Cursor = Serializer.ReadF64(Buffer, Cursor)
	CurrentSegmentSize,      Cursor = Serializer.ReadF64(Buffer, Cursor)
	BouncesThisFrame,        Cursor = Serializer.ReadF64(Buffer, Cursor)
	LODFrameAccumulator,     Cursor = Serializer.ReadF64(Buffer, Cursor)
	LODDeltaAccumulator,     Cursor = Serializer.ReadF64(Buffer, Cursor)
	SpatialFrameAccumulator, Cursor = Serializer.ReadF64(Buffer, Cursor)
	SpatialDeltaAccumulator, Cursor = Serializer.ReadF64(Buffer, Cursor)
	BouncePositionHead,      Cursor = Serializer.ReadF64(Buffer, Cursor)
	CornerBounceCount,       Cursor = Serializer.ReadF64(Buffer, Cursor)

	Event.TotalRuntime            = TotalRuntime
	Event.DistanceCovered         = DistanceCovered
	Event.LastDragRecalcTime      = LastDragRecalcTime
	Event.HomingElapsed           = HomingElapsed
	Event.CurrentSegmentSize      = CurrentSegmentSize
	Event.BouncesThisFrame        = BouncesThisFrame
	Event.LODFrameAccumulator     = LODFrameAccumulator
	Event.LODDeltaAccumulator     = LODDeltaAccumulator
	Event.SpatialFrameAccumulator = SpatialFrameAccumulator
	Event.SpatialDeltaAccumulator = SpatialDeltaAccumulator
	Event.BouncePositionHead      = BouncePositionHead
	Event.CornerBounceCount       = CornerBounceCount

	local V: Vector3
	if bit32.band(Flags, F_SPIN_VECTOR)    ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.SpinVector             = V end
	if bit32.band(Flags, F_TRAVEL_POSITION)~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.TravelPosition         = V end
	if bit32.band(Flags, F_TRAVEL_VELOCITY)~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.TravelVelocity         = V end
	if bit32.band(Flags, F_HIT_POSITION)   ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.HitPosition            = V end
	if bit32.band(Flags, F_HIT_NORMAL)     ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.HitNormal              = V end
	if bit32.band(Flags, F_RAY_ORIGIN)     ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.RayOrigin              = V end
	if bit32.band(Flags, F_PRE_BOUNCE_VEL) ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.PreBounceVelocity      = V end
	if bit32.band(Flags, F_VIS_RAY_ORIGIN) ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.VisualizationRayOrigin = V end
	if bit32.band(Flags, F_VEL_DIR_EMA)    ~= 0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.VelocityDirectionEMA   = V end
	if bit32.band(Flags, F_FIRST_BOUNCE_POS)~=0 then V, Cursor = Serializer.ReadVector3(Buffer, Cursor) Event.FirstBouncePosition    = V end

	if bit32.band(Flags, F_HIT_NORMAL) ~= 0 then
		local Dot: number
		Dot, Cursor = Serializer.ReadF64(Buffer, Cursor)
		if Dot >= 0 then Event.ImpactDot = Dot end
	end

	if bit32.band(Flags, F_HIT_MATERIAL) ~= 0 then
		local MatValue: number
		MatValue, Cursor = Serializer.ReadU16(Buffer, Cursor)
		Event.HitMaterial = Enum.Material:FromValue(MatValue)
	end

	if bit32.band(Flags, F_REMAINING_RESIM) ~= 0 then
		local Remaining: number
		Remaining, Cursor = Serializer.ReadF64(Buffer, Cursor)
		Event.RemainingResimDelta = Remaining
	end

	if bit32.band(Flags, F_TRAJECTORY) ~= 0 then
		local Origin, InitialVelocity, Acceleration, StartTime
		Origin,          Cursor = Serializer.ReadVector3(Buffer, Cursor)
		InitialVelocity, Cursor = Serializer.ReadVector3(Buffer, Cursor)
		Acceleration,    Cursor = Serializer.ReadVector3(Buffer, Cursor)
		StartTime,       Cursor = Serializer.ReadF64(Buffer, Cursor)
		Event.Trajectory = {
			Origin          = Origin,
			InitialVelocity = InitialVelocity,
			Acceleration    = Acceleration,
			StartTime       = StartTime,
		}
	end

	if bit32.band(Flags, F_BOUNCE_HISTORY) ~= 0 then
		local Count: number
		Count, Cursor = Serializer.ReadU16(Buffer, Cursor)
		local History = table.create(Count)
		for Index = 1, Count do
			local Entry: Vector3
			Entry, Cursor = Serializer.ReadVector3(Buffer, Cursor)
			History[Index] = Entry
		end
		Event.BouncePositionHistory = History
	end

	if bit32.band(Flags, F_SIXDOF) ~= 0 then
		local Orientation: CFrame
		local AngularVelocity: Vector3
		local AngleOfAttack: number
		Orientation,     Cursor = Serializer.ReadCFrame(Buffer, Cursor)
		AngularVelocity, Cursor = Serializer.ReadVector3(Buffer, Cursor)
		AngleOfAttack,   Cursor = Serializer.ReadF64(Buffer, Cursor)
		Event.Orientation     = Orientation
		Event.AngularVelocity = AngularVelocity
		Event.AngleOfAttack   = AngleOfAttack
	end

	return Event, Cursor
end

ResultBuffer.EVENT_TO_INT = EVENT_TO_INT
ResultBuffer.INT_TO_EVENT = INT_TO_EVENT

return table.freeze(ResultBuffer)
