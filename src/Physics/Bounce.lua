--!strict
--!optimize 2
--!native

local Bounce   = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local PureBounce = require(script.Parent.Pure.Bounce)

function Bounce.Reflect(IncomingVelocity: Vector3, SurfaceNormal: Vector3): Vector3
	return PureBounce.Reflect(IncomingVelocity, SurfaceNormal)
end

function Bounce.ApplyRestitution(
	Cast               : any,
	ReflectedVelocity  : Vector3,
	SurfaceNormal      : Vector3,
	Restitution        : number,
	MaterialMultiplier : number,
	NormalPerturbation : number
): Vector3
	local Runtime = Cast.Runtime
	local BounceRandom = Runtime.BounceRandom
	if not BounceRandom and NormalPerturbation > 0 then
		BounceRandom         = PureBounce.CreateRandom(Cast.Id)
		Runtime.BounceRandom = BounceRandom
	end
	return PureBounce.ApplyRestitution(
		ReflectedVelocity, SurfaceNormal, Restitution, MaterialMultiplier, NormalPerturbation, BounceRandom
	)
end

function Bounce.GetMaterialMultiplier(Cast: any, Material: Enum.Material): number
	return PureBounce.GetMaterialMultiplier(Cast.Behavior.MaterialRestitution, Material)
end

function Bounce.IsCornerTrap(Cast: any, SurfaceNormal: Vector3, ContactPosition: Vector3): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local State: PureBounce.CornerState = {
		TotalRuntime                = Runtime.TotalRuntime,
		LastBounceTime              = Runtime.LastBounceTime,
		BouncePositionHistory       = Runtime.BouncePositionHistory,
		BouncePositionHead          = Runtime.BouncePositionHead,
		CornerBounceCount           = Runtime.CornerBounceCount,
		VelocityDirectionEMA        = Runtime.VelocityDirectionEMA,
		FirstBouncePosition         = Runtime.FirstBouncePosition,
		CornerTimeThreshold         = Behavior.CornerTimeThreshold,
		CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold,
		CornerEMAAlpha              = Behavior.CornerEMAAlpha,
		CornerEMAThreshold          = Behavior.CornerEMAThreshold,
		CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = Behavior.CornerPositionHistorySize,
	}

	return PureBounce.IsCornerTrap(State, ContactPosition, Runtime.TotalRuntime)
end

function Bounce.RecordBounceState(Cast: any, Normal: Vector3, Position: Vector3, PostBounceVelocity: Vector3)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local State: PureBounce.CornerState = {
		TotalRuntime                = Runtime.TotalRuntime,
		LastBounceTime              = Runtime.LastBounceTime,
		BouncePositionHistory       = Runtime.BouncePositionHistory,
		BouncePositionHead          = Runtime.BouncePositionHead,
		CornerBounceCount           = Runtime.CornerBounceCount,
		VelocityDirectionEMA        = Runtime.VelocityDirectionEMA,
		FirstBouncePosition         = Runtime.FirstBouncePosition,
		CornerTimeThreshold         = Behavior.CornerTimeThreshold,
		CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold,
		CornerEMAAlpha              = Behavior.CornerEMAAlpha,
		CornerEMAThreshold          = Behavior.CornerEMAThreshold,
		CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = Behavior.CornerPositionHistorySize,
	}

	local NewLastBounceTime, NewHead, NewHistory, NewCornerBounceCount, NewEMA, NewFirstBounce =
		PureBounce.RecordBounceState(State, Position, PostBounceVelocity, Runtime.TotalRuntime)

	Runtime.LastBounceTime       = NewLastBounceTime
	Runtime.BouncePositionHead   = NewHead
	Runtime.BouncePositionHistory = NewHistory
	Runtime.CornerBounceCount    = NewCornerBounceCount
	Runtime.VelocityDirectionEMA = NewEMA
	Runtime.FirstBouncePosition  = NewFirstBounce
end

return table.freeze(Bounce)
