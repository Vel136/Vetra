--!strict
--!optimize 2
-- ─── RaycastParamsPooler ──────────────────────────────────────────────────────
--[[
    Adaptive, demand-smoothed object pool for RaycastParams.
    Thin wrapper around Fluix — delegates all EMA, heartbeat, and sizing logic
    to the generic pooler. Only the RaycastParams-specific Factory, Reset, and
    template-copy (Acquire) live here.

    Usage:
        local PoolerClass = require(path.to.RaycastParamsPooler)

        local ShotgunPool = PoolerClass.new({ MinSize = 16, Headroom = 2.5 })
        local SniperPool  = PoolerClass.new({ MinSize = 4,  Headroom = 1.5 })

        ShotgunPool:Seed(12)
        local params = ShotgunPool:Acquire(templateParams)
        ShotgunPool:Release(params)
        ShotgunPool:Destroy()

    Config fields (all optional):
        MinSize              number   Floor the pool never shrinks below.          Default: 8
        MaxSize              number   Hard memory ceiling.                          Default: MAX_PARAMS_POOL_SIZE
        Alpha                number   EMA smoothing coefficient (0–1).              Default: 0.3
        Headroom             number   Pool target multiplier over smoothed demand.  Default: 2.0
        SampleWindow         number   Demand measurement interval in seconds.       Default: 0.5
        PrewarmBatchSize     number   Max allocations per Heartbeat tick.           Default: 16
        ShrinkGraceSeconds   number   Surplus duration before eviction begins.      Default: 3.0
        IdleDisconnectWindows number  Consecutive idle windows before dormancy.     Default: 6
]]

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Fluix     = require(Core.Fluix)
local Constants = require(Core.Constants)

-- ─── Types ───────────────────────────────────────────────────────────────────

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

-- ─── Fluix Factory / Reset ───────────────────────────────────────────────────

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
end

-- ─── Constructor ─────────────────────────────────────────────────────────────

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

-- ─── Public API ──────────────────────────────────────────────────────────────

--[=[
	Pre-loads the EMA with a known expected demand and fills the pool
	synchronously to the resulting target.
]=]
function PoolerClass:Seed(ExpectedDemand: number)
	self._Pool:Seed(ExpectedDemand)
end

--[=[
	Pops a RaycastParams from the pool and copies fields from `src` if provided.
	On a miss (empty pool), allocates fresh via Fluix.

	Parameters:
	    src: RaycastParams? — template to copy. FilterDescendantsInstances is cloned.
]=]
function PoolerClass:Acquire(src: RaycastParams?): RaycastParams
	return self._Pool:Acquire(src and function(Params: RaycastParams)
		Params.CollisionGroup             = src.CollisionGroup
		Params.FilterType                 = src.FilterType
		Params.FilterDescendantsInstances = table.clone(src.FilterDescendantsInstances)
		Params.RespectCanCollide          = src.RespectCanCollide
		Params.BruteForceAllSlow          = src.BruteForceAllSlow
		Params.IgnoreWater                = src.IgnoreWater
	end or nil)
end

--[=[
	Returns a used RaycastParams to the pool. Fluix resets all fields via
	`_ResetParams` before returning it to the free list.
]=]
function PoolerClass:Release(Params: RaycastParams)
	self._Pool:Release(Params)
end

--[=[
	Fully tears down this pool instance. The instance should not be used
	after this call.
]=]
function PoolerClass:Destroy()
	self._Pool:Destroy()
end

--[=[
	Returns a snapshot of the pool's state for debugging and tuning.
	Shape matches the existing PoolerStats type.
]=]
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

-- ─── Module Return ───────────────────────────────────────────────────────────

return PoolerClass
