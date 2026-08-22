--!strict
--!optimize 2
--!native

local DriftCorrector = {}
DriftCorrector.__index = DriftCorrector

local math_min = math.min

function DriftCorrector.new(ResolvedConfig: any): any
	return setmetatable({
		_DriftThreshold = ResolvedConfig.DriftThreshold,
		_CorrectionRate = ResolvedConfig.CorrectionRate,
	}, DriftCorrector)
end

function DriftCorrector.Evaluate(self: any, LocalCast: any, ServerPosition: Vector3): boolean
	local LocalPosition = LocalCast:GetPosition()
	if not LocalPosition then return false end
	local Delta = ServerPosition - LocalPosition
	return Delta:Dot(Delta) > self._DriftThreshold * self._DriftThreshold
end

function DriftCorrector.Correct(
	self           : any,
	LocalCast      : any,
	ServerPosition : Vector3,
	ServerVelocity : Vector3,
	DeltaTime      : number
)
	local LocalPosition = LocalCast:GetPosition()
	if not LocalPosition then
		warn("DriftCorrector.Correct: could not read local cast position")
		return
	end

	local Alpha     = math_min(DeltaTime * self._CorrectionRate, 1)
	local Corrected = LocalPosition:Lerp(ServerPosition, Alpha)

	LocalCast:SetPosition(Corrected)
	LocalCast:SetVelocity(ServerVelocity)
end

function DriftCorrector.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	setmetatable(self, nil)
end

return table.freeze(DriftCorrector)
