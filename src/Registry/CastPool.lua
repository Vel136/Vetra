--!native
--!optimize 2
--!strict

-- ─── CastPool ────────────────────────────────────────────────────────────────
--[[
    Pre-allocated cast object pool.

    Problem: Fire() previously allocated a fresh Cast table tree on every call
    and let Terminate() discard it to GC. At high fire rates (miniguns, AOE
    explosions spawning many fragments) this creates measurable GC pressure —
    hundreds of table allocations and collections per second.

    Solution: Keep a free list of Cast tables that have already been allocated.
    Acquire() pops from the list (or allocates if empty). Release() resets all
    fields and pushes back onto the list. The allocator runs at most once per
    unique Cast table for the lifetime of the solver.

    Reset strategy — why we reset field-by-field rather than table.clear():
        Cast.Runtime is a nested table that itself contains nested tables
        (Trajectories, PiercedInstances, etc.). If we table.clear(Runtime) we
        lose the references to those inner tables and must reallocate them
        anyway — defeating the point. Instead we preserve the sub-table
        references and clear/reset their contents explicitly. This way the
        entire tree is reused without any allocation.

    Metatable sharing:
        The original code did setmetatable(Cast, { __index = CAST_STATE_METHODS })
        inside Fire(), allocating a new metatable table on every call even though
        every cast uses the identical methods table. CastPool accepts the shared
        metatable once at Acquire() time and stamps it onto every pooled object,
        eliminating that allocation entirely.

    Pool size:
        Bounded by MAX_POOL_SIZE. If the free list is full when Release() is
        called, the cast is simply discarded — no error, no leak. If the free
        list is empty when Acquire() is called, a fresh cast is allocated. The
        pool grows organically up to the cap during bursts and shrinks back as
        demand falls.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local Identity = "CastPool"
local CastPool  = {}
CastPool.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Maximum number of Cast tables kept in the free list between firings.
-- Beyond this cap, released casts are discarded rather than pooled.
-- 128 covers most realistic simultaneous-fire scenarios without holding
-- excessive memory when activity is low.
local MAX_POOL_SIZE = 2048

-- ─── Private ─────────────────────────────────────────────────────────────────

-- Construct the inner Runtime table shell. Fields are populated by ResetCast.
-- Called only when the pool is empty and a fresh allocation is unavoidable.
local function NewRuntime(): any
	return {
		TotalRuntime             = 0,
		DistanceCovered          = 0,
		Trajectories             = {},       -- array of trajectory tables
		ActiveTrajectory         = nil,
		TerminationCancelCounts  = {},
		PierceCount              = 0,
		PiercedInstances         = {},
		PierceCallbackThread     = nil,
		BounceCount              = 0,
		BouncesThisFrame         = 0,
		LastBounceTime           = -math.huge,
		BouncePositionHistory    = {},        -- ring buffer of recent contact positions
		BouncePositionHead       = 0,         -- ring buffer write cursor
		VelocityDirectionEMA     = Vector3.zero,
		FirstBouncePosition      = nil,           -- set once on first bounce by RecordBounceState
		CornerBounceCount        = 0,             -- pass 4 bounce counter
		BounceCallbackThread     = nil,
		CanHomeCallbackThread    = nil,
		CastFunctionThread       = nil,

		HomingProviderThread 	  = nil,
		TrajectoryProviderThread  = nil,
		HomingElapsed             = 0,
		HomingDisengaged          = false,
		HomingAcquired            = false,
		LastDragRecalculateTime        = 0,
		CrossedThresholds         = {},
		IsSupersonic              = false,
		IsActivelyResimulating    = false,
		CancelResimulation        = false,
		CurrentSegmentSize        = 0,
		IsLOD                     = false,
		LODFrameAccumulator       = 0,
		LODDeltaAccumulator       = 0,
		SpatialFrameAccumulator   = 0,
		SpatialDeltaAccumulator   = 0,
		CosmeticBulletObject      = nil,
		ParentCastId              = nil,
		PenetrationForceRemaining = nil,
		IsTumbling                = false,
		TumbleRandom              = nil,
	}
end

-- Construct the inner Behavior table shell. Fields are populated by Fire().
local function NewBehavior(): any
	return {
		Acceleration               = Vector3.zero,
		MaxDistance                = 0,
		MaxSpeed                   = math.huge,
		MinSpeed                   = 0,
		Gravity                    = Vector3.zero,
		RaycastParams              = nil,
		OriginalFilter             = nil,
		ResetPierceOnBounce        = false,
		DragCoefficient            = 0,
		DragModel                  = Constants.DRAG_MODEL.Quadratic,
		DragSegmentInterval        = 0,
		GyroDriftRate              = nil,
		GyroDriftAxis              = nil,
		TumbleSpeedThreshold       = nil,
		TumbleDragMultiplier       = nil,
		TumbleLateralStrength      = nil,
		TumbleOnPierce             = false,
		TumbleRecoverySpeed        = nil,
		SpeedThresholds            = nil,
		SupersonicProfile          = nil,
		SpinVector        		   = Vector3.zero,
		MagnusCoefficient          = 0,
		SpinDecayRate              = 0,
		SubsonicProfile            = nil,
		WindResponse               = 1,
		HomingPositionProvider     = nil,
		CanHomeFunction            = nil,
		TrajectoryPositionProvider = nil,
		HomingStrength             = 0,
		HomingMaxDuration          = 0,
		HomingAcquisitionRadius    = 0,
		BulletMass                 = 0,
		CanPierceFunction          = nil,
		MaxPierceCount             = 0,
		PierceSpeedThreshold       = 0,
		PenetrationSpeedRetention  = 0,
		PierceNormalBias           = 0,
		PenetrationDepth           = 0,
		PenetrationForce           = 0,
		PenetrationThicknessLimit  = 500,
		FragmentOnPierce           = false,
		FragmentCount              = 0,
		FragmentDeviation          = 0,
		CanBounceFunction          = nil,
		MaxBounces                 = 0,
		BounceSpeedThreshold       = 0,
		Restitution                = 0,
		MaterialRestitution        = nil,
		NormalPerturbation         = 0,
		HighFidelitySegmentSize    = 0,
		HighFidelityFrameBudget    = 0,
		AdaptiveScaleFactor        = 0,
		MinSegmentSize             = 0,
		MaxBouncesPerFrame         = 0,
		CornerTimeThreshold        = 0,
		CornerPositionHistorySize  = 0,
		CornerDisplacementThreshold= 0,
		LODDistance                = 0,
		BatchTravel                = false,
		VisualizeCasts             = false,
	}
end

-- Allocate a brand new Cast table tree. Called only when pool is empty.
local function NewCast(): any
	return {
		Alive     = false,
		Paused    = false,
		StartTime = 0,
		Id        = 0,
		Runtime   = NewRuntime(),
		Behavior  = NewBehavior(),
		UserData  = {},
	}
end

-- Reset all Runtime fields to their initial values, reusing the existing
-- nested tables (Trajectories, PiercedInstances, etc.) rather than
-- replacing them. This is the critical path — every field must be listed
-- explicitly. A missed field means stale state bleeds into the next cast.
local function ResetRuntime(Runtime: any, Behavior: any, InitialTrajectory: any, InitialSegmentSize: number, IsSupersonic: boolean)
	-- Reset callback fields that Fire() assigns with bare assignment (no nil fallback).
	-- Without this, a pooled cast that had a pierce/bounce function would bleed it
	-- into a new cast that passes nil for those fields.
	Behavior.CanPierceFunction = nil
	Behavior.CanBounceFunction = nil
	Runtime.TotalRuntime            = 0
	Runtime.DistanceCovered         = 0
	-- Reuse the Trajectories array: clear it and insert the new initial segment.
	table.clear(Runtime.Trajectories)
	Runtime.Trajectories[1]         = InitialTrajectory
	Runtime.ActiveTrajectory        = InitialTrajectory
	-- Clear the cancel count map without replacing it.
	table.clear(Runtime.TerminationCancelCounts)
	Runtime.PierceCount             = 0
	table.clear(Runtime.PiercedInstances)
	Runtime.PierceCallbackThread    = nil
	Runtime.BounceCount             = 0
	Runtime.BouncesThisFrame        = 0
	Runtime.LastBounceTime          = -math.huge
	table.clear(Runtime.BouncePositionHistory)
	Runtime.BouncePositionHead      = 0
	Runtime.VelocityDirectionEMA    = Constants.ZERO_VECTOR
	Runtime.FirstBouncePosition     = nil
	Runtime.CornerBounceCount       = 0
	Runtime.BounceCallbackThread    = nil
	Runtime.CanHomeCallbackThread   = nil
	Runtime.CastFunctionThread      = nil
	Runtime.HomingElapsed              = 0
	Runtime.HomingDisengaged           = false
	Runtime.HomingAcquired             = false
	Runtime.HomingProviderThread       = nil
	Runtime.TrajectoryProviderThread   = nil
	Runtime.LastDragRecalculateTime         = 0
	table.clear(Runtime.CrossedThresholds)
	Runtime.IsSupersonic               = IsSupersonic
	Runtime.IsActivelyResimulating     = false
	Runtime.CancelResimulation         = false
	Runtime.CurrentSegmentSize         = InitialSegmentSize
	Runtime.IsLOD                      = false
	Runtime.LODFrameAccumulator        = 0
	Runtime.LODDeltaAccumulator        = 0
	Runtime.SpatialFrameAccumulator    = 0
	Runtime.SpatialDeltaAccumulator    = 0
	Runtime.CosmeticBulletObject       = nil
	Runtime.ParentCastId               = nil
	Runtime.PenetrationForceRemaining  = nil
	Runtime.IsTumbling                 = false
	Runtime.TumbleRandom               = nil
end

-- ─── Module ──────────────────────────────────────────────────────────────────

-- ─── Pool Construction ───────────────────────────────────────────────────────

-- Create a new pool instance. Each Solver gets its own pool so pools
-- never share state across solver instances.
function CastPool.new(): any
	return {
		_FreeList = {},
		_Size     = 0,
	}
end

-- ─── Acquire ─────────────────────────────────────────────────────────────────

-- Pop a Cast table from the pool and stamp it with the provided state.
-- If the pool is empty, allocates a fresh Cast table tree.
--
-- InitialTrajectory, InitialSegmentSize, and IsSupersonic are the only
-- Runtime fields that cannot be defaulted to zero — they depend on the
-- specific FireBulletContext and FireBehavior passed to Fire().
-- All other Runtime fields are reset to their initial values here.
--
-- SharedMetatable must be the frozen { __index = CAST_STATE_METHODS } table.
-- Passing it in from Fire() avoids allocating a new metatable per cast.
function CastPool.Acquire(
	Pool             : any,
	Id               : number,
	StartTime        : number,
	InitialTrajectory: any,
	InitialSegmentSize: number,
	IsSupersonic     : boolean,
	SharedMetatable  : any
): any
	local FreeList = Pool._FreeList
	local Cast: any

	if Pool._Size > 0 then
		-- Pop from the top of the free list (LIFO — most recently released
		-- cast is most likely still warm in CPU cache).
		Cast          = FreeList[Pool._Size]
		FreeList[Pool._Size] = nil
		Pool._Size    -= 1
	else
		-- Pool exhausted — allocate a fresh shell.
		Cast = NewCast()
	end

	-- Stamp top-level identity fields.
	Cast.Alive     = true
	Cast.Paused    = false
	Cast.StartTime = StartTime
	Cast.Id        = Id

	-- Reset all Runtime fields, reusing nested tables.
	-- Also resets Behavior callback fields that Fire() assigns without a nil fallback.
	ResetRuntime(Cast.Runtime, Cast.Behavior, InitialTrajectory, InitialSegmentSize, IsSupersonic)

	-- Behavior fields are written directly by Fire() after Acquire() returns,
	-- so we only need to clear the fields that Fire() might not overwrite —
	-- specifically UserData, which is consumer-owned and must be empty for
	-- each new cast.
	table.clear(Cast.UserData)

	-- Stamp the shared metatable. This replaces the per-cast metatable
	-- allocation that previously happened inside Fire().
	setmetatable(Cast, SharedMetatable)

	return Cast
end

-- ─── Release ─────────────────────────────────────────────────────────────────

-- Return a terminated Cast to the pool for reuse.
-- Does NOT reset fields here — Reset happens at Acquire() time, not Release()
-- time. This keeps Release() as cheap as possible since it sits in the
-- hot path of Terminate(), which fires on every cast termination.
--
-- If the pool is already at capacity, the cast is silently discarded.
-- The consumer holds no other reference to it after Terminate() returns,
-- so it will be collected normally by GC.
function CastPool.Release(Pool: any, Cast: any)
	if Pool._Size >= MAX_POOL_SIZE then
		-- Pool full — let GC handle this one.
		return
	end

	Pool._Size             += 1
	Pool._FreeList[Pool._Size] = Cast
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local CastPoolMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("CastPool: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"CastPool: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(CastPool, CastPoolMetatable)