--!strict
--!optimize 2
--!native

local LateJoinHandler = {}

local Transport = script.Parent.Parent.Transport

local BlinkSchema = require(Transport.BlinkSchema)

function LateJoinHandler.SyncPlayer(
	Player         : Player,
	Solver         : any,
	Batcher        : any,
	NetRemote      : RemoteEvent,
	CurrentFrameId : number
)
	local ActiveCasts = Solver._ActiveCasts
	if not ActiveCasts or #ActiveCasts == 0 then return end

	local States = {}

	for Index = 1, #ActiveCasts do
		local Cast = ActiveCasts[Index]
		if not Cast or not Cast.Alive or Cast.Paused then continue end

		local BulletCtx    = Solver._CastToBulletContext[Cast]
		local ServerCastId = BulletCtx and BulletCtx.__solverData and BulletCtx.__solverData.ServerCastId
		if not ServerCastId then continue end

		local Runtime          = Cast.Runtime
		local ActiveTrajectory = Runtime.ActiveTrajectory
		if not ActiveTrajectory then continue end

		local Elapsed         = Runtime.TotalRuntime - ActiveTrajectory.StartTime
		local InitialVelocity = ActiveTrajectory.InitialVelocity
		local Acceleration    = ActiveTrajectory.Acceleration
		local Origin          = ActiveTrajectory.Origin

		local Position = Origin + InitialVelocity * Elapsed + Acceleration * (Elapsed * Elapsed * 0.5)
		local Velocity = InitialVelocity + Acceleration * Elapsed

		States[#States + 1] = {
			CastId   = ServerCastId,
			Position = Position,
			Velocity = Velocity,
		}
	end

	if #States == 0 then return end

	local Encoded = BlinkSchema.EncodeStateBatch(CurrentFrameId, States, #States, 0)
	Batcher:WriteStateForAll({ Player }, Encoded)
	Batcher:FlushPlayer(NetRemote, Player)
end

return table.freeze(LateJoinHandler)
