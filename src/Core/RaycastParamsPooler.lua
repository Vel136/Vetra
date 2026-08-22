--!strict
--!optimize 2
--!native

local Core         = script.Parent
local Dependencies = Core.Parent.Dependencies

local Fluix     = require(Dependencies.Fluix)
local Constants = require(Core.Constants)

export type PoolerConfig = {
	MinSize              : number?,
	MaxSize              : number?,
	Alpha                : number?,
	Headroom             : number?,
	SampleWindow         : number?,
	PrewarmBatchSize     : number?,
	ShrinkGraceSeconds   : number?,
	IdleDisconnectWindows: number?,
}

export type PoolerStats = {
	PoolSize        : number,
	TargetSize      : number,
	DemandEMA       : number,
	MissCount       : number,
	MissesThisWindow: number,
	IsActive        : boolean,
}

export type Pooler = {
	Seed    : (self: Pooler, ExpectedDemand: number) -> (),
	Acquire : (self: Pooler, src: RaycastParams?)    -> RaycastParams,
	Release : (self: Pooler, Params: RaycastParams)  -> (),
	Destroy : (self: Pooler)                         -> (),
	GetStats: (self: Pooler)                         -> PoolerStats,
}

local PoolerClass   = {}
PoolerClass.__index = PoolerClass

local function _MakeParams(): RaycastParams
	return RaycastParams.new()
end

local function _ResetParams(Params: RaycastParams)
	Params.FilterDescendantsInstances = {}
	Params.RespectCanCollide          = false
	Params.CollisionGroup             = ""
	Params.FilterType                 = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater                = false
	Params.BruteForceAllSlow          = false
	Params.IncludeInstances           = nil
	Params.ExcludeInstances           = nil
end

function PoolerClass.new(config: PoolerConfig?): Pooler
	local cfg = config or {}
	local FluixPool = Fluix.new({
		Factory               = _MakeParams,
		Reset                 = _ResetParams,
		MinSize               = cfg.MinSize               or 8,
		MaxSize               = cfg.MaxSize               or Constants.MAX_PARAMS_POOL_SIZE,
		Alpha                 = cfg.Alpha                 or 0.3,
		Headroom              = cfg.Headroom              or 2.0,
		SampleWindow          = cfg.SampleWindow          or 0.5,
		PrewarmBatchSize      = cfg.PrewarmBatchSize      or 16,
		ShrinkGraceSeconds    = cfg.ShrinkGraceSeconds    or 3.0,
		IdleDisconnectWindows = cfg.IdleDisconnectWindows or 6,
	})
	return setmetatable({ _Pool = FluixPool }, PoolerClass) :: any
end

function PoolerClass:Seed(ExpectedDemand: number)
	self._Pool:Seed(ExpectedDemand)
end

function PoolerClass:Acquire(src: RaycastParams?): RaycastParams
	return self._Pool:Acquire(src and function(Params: RaycastParams)
		Params.CollisionGroup             = src.CollisionGroup
		Params.FilterType                 = src.FilterType
		Params.FilterDescendantsInstances = table.clone(src.FilterDescendantsInstances)
		Params.RespectCanCollide          = src.RespectCanCollide
		Params.BruteForceAllSlow          = src.BruteForceAllSlow
		Params.IgnoreWater                = src.IgnoreWater
		Params.IncludeInstances           = src.IncludeInstances and table.clone(src.IncludeInstances)
		Params.ExcludeInstances           = src.ExcludeInstances and table.clone(src.ExcludeInstances)
	end or nil)
end

function PoolerClass:Release(Params: RaycastParams)
	self._Pool:Release(Params)
end

function PoolerClass:Destroy()
	self._Pool:Destroy()
end

function PoolerClass:GetStats(): PoolerStats
	local S = self._Pool:GetStats()
	return {
		PoolSize         = S.PoolSize,
		TargetSize       = S.TargetSize,
		DemandEMA        = S.DemandEMA,
		MissCount        = S.MissCount,
		MissesThisWindow = S.MissesThisWindow,
		IsActive         = S.IsActive,
	}
end

return PoolerClass
