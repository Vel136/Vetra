--!strict
--!optimize 2
-- ─── RaycastParamsPooler ──────────────────────────────────────────────────────
--[[
    Adaptive, demand-smoothed object pool for RaycastParams.
    Per-instance design — multiple pools can coexist with independent tuning.

    Usage:
        local PoolerClass = require(path.to.RaycastParamsPooler)

        local ShotgunPool = PoolerClass.new({ MinSize = 16, Headroom = 2.5 })
        local SniperPool  = PoolerClass.new({ MinSize = 4,  Headroom = 1.5 })
        local RiflePool   = PoolerClass.new({ Alpha = 0.5 })

        ShotgunPool:Seed(12)
        local params = ShotgunPool:Acquire(templateParams)
        ShotgunPool:Release(params)
        ShotgunPool:Destroy()

    Config fields (all optional):
        MinSize             number   Floor the pool never shrinks below.          Default: 8
        MaxSize             number   Hard memory ceiling.                          Default: 256
        Alpha               number   EMA smoothing coefficient (0–1).              Default: 0.3
        Headroom            number   Pool target multiplier over smoothed demand.  Default: 2.0
        SampleWindow        number   Demand measurement interval in seconds.       Default: 0.5
        PrewarmBatchSize    number   Max allocations per Heartbeat tick.           Default: 16
        ShrinkGraceSeconds  number   Surplus duration before eviction begins.      Default: 3.0
        IdleDisconnectWindows number Consecutive idle windows before dormancy.     Default: 6
]]

local RunService = game:GetService("RunService")

-- ─── Class Definition ────────────────────────────────────────────────────────

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

local PoolerClass  = {}
PoolerClass.__index = PoolerClass

-- ─── Internal Helpers ────────────────────────────────────────────────────────

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

--[=[
    PoolerClass.new

    Creates a new, independent RaycastParams pool with its own EMA state,
    tuning constants, and Heartbeat lifecycle. Multiple instances can coexist
    without sharing demand state.

    Parameters:
        config: PoolerConfig?
            Optional table of tuning overrides. Any omitted field uses its
            default value.

    Returns:
        Pooler
]=]
function PoolerClass.new(config: PoolerConfig?): Pooler
	local cfg = config or {}

	local self = setmetatable({}, PoolerClass)

	-- ── Tuning Constants (per-instance) ──────────────────────────────────────
	self._MIN_POOL_SIZE             = cfg.MinSize               or 8
	self._MAX_POOL_SIZE             = cfg.MaxSize               or 256
	self._EMA_ALPHA                 = cfg.Alpha                 or 0.3
	self._HEADROOM                  = cfg.Headroom              or 2.0
	self._SAMPLE_WINDOW             = cfg.SampleWindow          or 0.5
	self._PREWARM_BATCH_SIZE        = cfg.PrewarmBatchSize      or 16
	self._SHRINK_GRACE_SECONDS      = cfg.ShrinkGraceSeconds    or 3.0
	self._IDLE_DISCONNECT_WINDOWS   = cfg.IdleDisconnectWindows or 6

	-- ── Pool State ────────────────────────────────────────────────────────────
	self._Pool     = {} :: { RaycastParams }
	self._PoolSize = 0

	-- ── Demand Tracking ───────────────────────────────────────────────────────
	self._DemandEMA               = 0.0
	self._WindowAcquisitions      = 0
	self._WindowStart             = os.clock()
	self._TargetSize              = self._MIN_POOL_SIZE
	self._LastDemandSatisfiedTime = os.clock()
	self._IdleWindowCount         = 0

	-- ── Heartbeat Lifecycle ───────────────────────────────────────────────────
	self._HeartbeatConnection = nil :: RBXScriptConnection?

	-- ── Telemetry ─────────────────────────────────────────────────────────────
	self._MissCount        = 0
	self._MissesThisWindow = 0

	return self :: any
end

-- ─── Heartbeat Tick ──────────────────────────────────────────────────────────

--[[
    _HeartbeatTick

    Bound per-instance via a closure in _EnsureConnected. Owns all allocation,
    eviction, and idle-disconnect logic for this pool. Never called from
    Acquire() — runs exclusively on the Heartbeat signal.
]]
function PoolerClass:_HeartbeatTick()
	local Now = os.clock()

	-- ── Window Boundary ───────────────────────────────────────────────────────

	if (Now - self._WindowStart) >= self._SAMPLE_WINDOW then

		-- ── Idle Disconnect ───────────────────────────────────────────────────

		if self._WindowAcquisitions == 0 then
			self._IdleWindowCount += 1
			if self._IdleWindowCount >= self._IDLE_DISCONNECT_WINDOWS then
				if self._HeartbeatConnection then
					self._HeartbeatConnection:Disconnect()
					self._HeartbeatConnection = nil
				end
				self._WindowStart     = os.clock()
				self._IdleWindowCount = 0
				return
			end
		else
			self._IdleWindowCount = 0
		end

		self._DemandEMA = self._EMA_ALPHA * self._WindowAcquisitions
			+ (1 - self._EMA_ALPHA) * self._DemandEMA

		self._TargetSize = math.clamp(
			math.ceil(self._DemandEMA * self._HEADROOM),
			self._MIN_POOL_SIZE,
			self._MAX_POOL_SIZE
		)

		self._WindowAcquisitions = 0
		self._MissesThisWindow   = 0
		self._WindowStart        = Now
	end

	-- ── Pre-Warming ───────────────────────────────────────────────────────────

	if self._PoolSize < self._TargetSize then
		local Deficit = self._TargetSize - self._PoolSize
		local Batch   = math.min(math.ceil(Deficit / 2), self._PREWARM_BATCH_SIZE)
		for _ = 1, Batch do
			if self._PoolSize >= self._MAX_POOL_SIZE then break end
			self._PoolSize             += 1
			self._Pool[self._PoolSize]  = _MakeParams()
		end
	end

	-- ── Demand-Satisfied Timestamp ────────────────────────────────────────────

	if self._PoolSize >= self._TargetSize then
		self._LastDemandSatisfiedTime = Now
	end

	-- ── Gradual Shrink ────────────────────────────────────────────────────────

	local IsExcess       = self._PoolSize > self._TargetSize
	local IsGraceExpired = (Now - self._LastDemandSatisfiedTime) > self._SHRINK_GRACE_SECONDS
	local IsAboveFloor   = self._PoolSize > self._MIN_POOL_SIZE

	if IsExcess and IsGraceExpired and IsAboveFloor then
		self._Pool[self._PoolSize] = nil
		self._PoolSize            -= 1
	end
end

--[[
    _EnsureConnected

    Creates the Heartbeat connection for this instance if it does not already
    exist. Uses a closure so the tick callback always references this specific
    instance's state — no shared globals.
]]
function PoolerClass:_EnsureConnected()
	if self._HeartbeatConnection then return end
	self._IdleWindowCount = 0
	self._WindowStart     = os.clock()
	self._HeartbeatConnection = RunService.Heartbeat:Connect(function()
		self:_HeartbeatTick()
	end)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--[=[
    Seed

    Pre-loads the EMA with a known expected demand and fills the pool
    synchronously to the resulting target. Call during initialisation when the
    expected fire rate is known ahead of time.

    Parameters:
        ExpectedDemand: number
            Expected acquisitions per SampleWindow (0.5s by default).
]=]
function PoolerClass:Seed(ExpectedDemand: number)
	ExpectedDemand = math.max(ExpectedDemand, 0)

	self._DemandEMA = ExpectedDemand

	self._TargetSize = math.clamp(
		math.ceil(self._DemandEMA * self._HEADROOM),
		self._MIN_POOL_SIZE,
		self._MAX_POOL_SIZE
	)

	local Deficit = self._TargetSize - self._PoolSize
	for _ = 1, Deficit do
		if self._PoolSize >= self._MAX_POOL_SIZE then break end
		self._PoolSize            += 1
		self._Pool[self._PoolSize] = _MakeParams()
	end

	self:_EnsureConnected()
end

--[=[
    Acquire

    Pops a RaycastParams from the pool and copies fields from `src` if provided.
    On a miss (empty pool), allocates fresh and increments both miss counters.

    Parameters:
        src: RaycastParams?
            Template to copy. FilterDescendantsInstances is cloned.

    Returns:
        RaycastParams — ready for use.
]=]
function PoolerClass:Acquire(src: RaycastParams?): RaycastParams
	self:_EnsureConnected()

	self._WindowAcquisitions += 1

	local Params: RaycastParams
	if self._PoolSize > 0 then
		Params                    = self._Pool[self._PoolSize]
		self._Pool[self._PoolSize] = nil
		self._PoolSize            -= 1
	else
		Params                  = _MakeParams()
		self._MissCount        += 1
		self._MissesThisWindow += 1
	end

	if src then
		Params.CollisionGroup             = src.CollisionGroup
		Params.FilterType                 = src.FilterType
		Params.FilterDescendantsInstances = table.clone(src.FilterDescendantsInstances)
		Params.RespectCanCollide          = src.RespectCanCollide
		Params.BruteForceAllSlow          = src.BruteForceAllSlow
		Params.IgnoreWater                = src.IgnoreWater
	end

	return Params
end

--[=[
    Release

    Returns a used RaycastParams to the pool after resetting all fields.
    The object must not be used after this call.

    Parameters:
        Params: RaycastParams — must not be accessed after this call.
]=]
function PoolerClass:Release(Params: RaycastParams)
	if self._PoolSize >= self._MAX_POOL_SIZE then return end
	_ResetParams(Params)
	self._PoolSize            += 1
	self._Pool[self._PoolSize] = Params
end

--[=[
    Destroy

    Fully tears down this pool instance: disconnects the Heartbeat connection,
    clears all pooled objects, and resets all state. The instance should not
    be used after this call.
]=]
function PoolerClass:Destroy()
	if self._HeartbeatConnection then
		self._HeartbeatConnection:Disconnect()
		self._HeartbeatConnection = nil
	end

	for i = 1, self._PoolSize do
		self._Pool[i] = nil :: any
	end

	self._PoolSize              = 0
	self._DemandEMA             = 0.0
	self._WindowAcquisitions    = 0
	self._WindowStart           = os.clock()
	self._TargetSize            = self._MIN_POOL_SIZE
	self._LastDemandSatisfiedTime = os.clock()
	self._IdleWindowCount       = 0
	self._MissCount             = 0
	self._MissesThisWindow      = 0
end

--[=[
    GetStats

    Returns a snapshot of this pool's state for live debugging and tuning.

    Fields:
        PoolSize          — objects currently available
        TargetSize        — EMA-derived pre-warm target
        DemandEMA         — smoothed acquisitions-per-window
        MissCount         — lifetime total pool misses
        MissesThisWindow  — misses since last window reset (primary tuning signal)
        IsActive          — true if Heartbeat connection is live
]=]
function PoolerClass:GetStats(): PoolerStats
	return {
		PoolSize         = self._PoolSize,
		TargetSize       = self._TargetSize,
		DemandEMA        = self._DemandEMA,
		MissCount        = self._MissCount,
		MissesThisWindow = self._MissesThisWindow,
		IsActive         = self._HeartbeatConnection ~= nil,
	}
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return PoolerClass