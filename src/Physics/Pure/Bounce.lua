--!strict
--!optimize 2
--!native

local PureBounce  = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

local math_random = math.random
local math_sqrt   = math.sqrt
local math_max    = math.max

local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MIN_DOT_SQ       = Constants.MIN_DOT_SQ

export type CornerState = {
	TotalRuntime:                number,
	LastBounceTime:              number,
	BouncePositionHistory:       { Vector3 },
	BouncePositionHead:          number,
	CornerBounceCount:           number,
	VelocityDirectionEMA:        Vector3,
	FirstBouncePosition:         Vector3?,
	CornerTimeThreshold:         number,
	CornerDisplacementThreshold: number,
	CornerEMAAlpha:              number,
	CornerEMAThreshold:          number,
	CornerMinProgressPerBounce:  number,
	CornerPositionHistorySize:   number,
}

function PureBounce.Reflect(IncomingVelocity: Vector3, SurfaceNormal: Vector3): Vector3
	return IncomingVelocity - 2 * IncomingVelocity:Dot(SurfaceNormal) * SurfaceNormal
end

function PureBounce.ApplyRestitution(
	ReflectedVelocity  : Vector3,
	SurfaceNormal      : Vector3,
	Restitution        : number,
	MaterialMultiplier : number,
	NormalPerturbation : number,
	BounceRandom       : Random?
): Vector3
	local ReflectedNormal = SurfaceNormal * SurfaceNormal:Dot(ReflectedVelocity)
	local Tangential      = ReflectedVelocity - ReflectedNormal
	local FinalVelocity   = Tangential + ReflectedNormal * (Restitution * MaterialMultiplier)

	if NormalPerturbation > 0 and FinalVelocity:Dot(FinalVelocity) > MIN_DOT_SQ then
		local NX, NY, NZ
		if BounceRandom then
			NX, NY, NZ = BounceRandom:NextNumber() - 0.5, BounceRandom:NextNumber() - 0.5, BounceRandom:NextNumber() - 0.5
		else
			NX, NY, NZ = math_random() - 0.5, math_random() - 0.5, math_random() - 0.5
		end

		local Raw = Vector3.new(NX, NY, NZ)
		if Raw:Dot(Raw) < MIN_MAGNITUDE_SQ then return FinalVelocity end

		local Noise      = Raw.Unit * NormalPerturbation
		local Perturbed  = FinalVelocity.Unit + Noise
		if Perturbed:Dot(Perturbed) < MIN_MAGNITUDE_SQ then return FinalVelocity end

		FinalVelocity = Perturbed.Unit * FinalVelocity.Magnitude
	end

	return FinalVelocity
end

function PureBounce.CreateRandom(CastId: number): Random
	return Random.new(CastId * 2654435761 % 2147483647)
end

function PureBounce.GetMaterialMultiplier(
	MaterialRestitutionMap : { [Enum.Material]: number }?,
	Material               : Enum.Material
): number
	if not MaterialRestitutionMap then return 1.0 end
	return MaterialRestitutionMap[Material] or 1.0
end

function PureBounce.IsCornerTrap(
	State           : CornerState,
	ContactPosition : Vector3,
	CurrentTime     : number
): boolean
	if (CurrentTime - State.LastBounceTime) < State.CornerTimeThreshold then
		return true
	end

	local DisplacementThresholdSq = State.CornerDisplacementThreshold * State.CornerDisplacementThreshold
	for _, Position in State.BouncePositionHistory do
		local Delta = ContactPosition - Position
		if Delta:Dot(Delta) < DisplacementThresholdSq then
			return true
		end
	end

	if State.CornerBounceCount >= 1 then
		local EMAMagnitudeSq = State.VelocityDirectionEMA:Dot(State.VelocityDirectionEMA)
		if EMAMagnitudeSq < State.CornerEMAThreshold * State.CornerEMAThreshold then
			return true
		end
	end

	local MinProgress = State.CornerMinProgressPerBounce
	if MinProgress > 0
		and State.FirstBouncePosition ~= nil
		and State.CornerBounceCount >= 3
	then
		local NetDisplacement = ContactPosition - State.FirstBouncePosition
		local NetDistanceSq   = NetDisplacement:Dot(NetDisplacement)
		local MinRequired     = State.CornerBounceCount * MinProgress
		if NetDistanceSq < MinRequired * MinRequired then
			return true
		end
	end

	return false
end

function PureBounce.RecordBounceState(
	State              : CornerState,
	ContactPosition    : Vector3,
	PostBounceVelocity : Vector3,
	TotalRuntime       : number
): (number, number, { Vector3 }, number, Vector3, Vector3?)
	local HistorySize = math_max(State.CornerPositionHistorySize, 4)

	local NewHead    = (State.BouncePositionHead % HistorySize) + 1
	local NewHistory : { Vector3 } = {}
	for Index, Value in State.BouncePositionHistory do
		NewHistory[Index] = Value
	end
	NewHistory[NewHead] = ContactPosition

	local Alpha        = State.CornerEMAAlpha
	local NewEMA: Vector3
	local SpeedSq = PostBounceVelocity:Dot(PostBounceVelocity)
	if SpeedSq > MIN_MAGNITUDE_SQ then
		local Direction = PostBounceVelocity / math_sqrt(SpeedSq)
		NewEMA = State.VelocityDirectionEMA * (1 - Alpha) + Direction * Alpha
	else
		NewEMA = State.VelocityDirectionEMA * (1 - Alpha)
	end

	local NewFirstBounce       = State.FirstBouncePosition or ContactPosition
	local NewCornerBounceCount = State.CornerBounceCount + 1

	return TotalRuntime, NewHead, NewHistory, NewCornerBounceCount, NewEMA, NewFirstBounce
end

return table.freeze(PureBounce)
