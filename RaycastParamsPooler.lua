-- ─── CONSTANTS ──────────────────────────────────────────────────────
local EMPTY_FILTER: { Instance } = {}
local MAX_PARAMS_POOL_SIZE            = 256
local ParamsPoolSize                  = 0

-- ─── RaycastParams Pool ──────────────────────────────────────────────────────

-- We track params here.
local ParamsPool: { RaycastParams }   = {}

function AcquireParams(src: RaycastParams?): RaycastParams
	local params: RaycastParams

	if ParamsPoolSize > 0 then
		params = ParamsPool[ParamsPoolSize]
		ParamsPool[ParamsPoolSize] = nil
		ParamsPoolSize -= 1
	else
		params = RaycastParams.new()
	end

	if src then
		params.CollisionGroup             = src.CollisionGroup
		params.FilterType                 = src.FilterType
		params.FilterDescendantsInstances = table.clone(src.FilterDescendantsInstances)
		params.RespectCanCollide          = src.RespectCanCollide
		params.BruteForceAllSlow		  = src.BruteForceAllSlow
		params.IgnoreWater                = src.IgnoreWater
	end

	return params
end

function ReleaseParams(params: RaycastParams)
	if ParamsPoolSize >= MAX_PARAMS_POOL_SIZE then return end

	params.FilterDescendantsInstances = {}
	params.RespectCanCollide          = false
	params.CollisionGroup             = ""
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.IgnoreWater                = false
	params.BruteForceAllSlow		  = false
	
	ParamsPoolSize += 1
	ParamsPool[ParamsPoolSize] = params
end

return {
	Acquire = AcquireParams,
	Release = ReleaseParams,
}
