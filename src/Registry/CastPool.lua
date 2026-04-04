--!native
--!optimize 2
--!strict

-- ─── CastPool ────────────────────────────────────────────────────────────────
--[[
    Pre-allocated cast object pool backed by Fluix.

    Problem: Fire() previously allocated a fresh Cast table tree on every call
    and let Terminate() discard it to GC. At high fire rates (miniguns, AOE
    explosions spawning many fragments) this creates measurable GC pressure —
    hundreds of table allocations and collections per second.

    Solution: Keep a pool of Cast tables that have already been allocated.
    Acquire() pops from the pool (or allocates if empty). Release() marks the
    cast dead and returns it. The full reset happens inside the Acquire Apply
    callback — same timing as before — so Release stays cheap.

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

    Reset timing:
        Fluix calls Reset (a lightweight tombstone) at Release time.
        The full ResetRuntime — which needs Fire()-specific parameters
        (InitialTrajectory, InitialSegmentSize, IsSupersonic) — runs inside
        the Acquire Apply callback, preserving the original acquire-time reset
        behaviour and keeping Release as cheap as a single field write.
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
local Enums      = require(Core.Enums)
local Fluix      = require(Core.Fluix)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Maximum number of Cast tables kept in the pool between firings.
-- Beyond this cap Fluix will not grow the pool further.
local MAX_POOL_SIZE = 2048

-- ─── Private — Cast Tree Allocation ─────────────────────────────────────────

-- Construct the inner Runtime table shell. Fields are populated by ResetRuntime.
-- Called only when the pool is empty and a fresh allocation is unavoidable.
local function NewRuntime(): any
	return {
		TotalRuntime             = 0,
		DistanceCovered          = 0,
		Trajectories             = {},
		ActiveTrajectory         = nil,
		TerminationCancelCounts  = {},
		PierceCount              = 0,
		PiercedInstances         = {},
		PierceCallbackThread     = nil,
		BounceCount              = 0,
		BouncesThisFrame         = 0,
		LastBounceTime           = -math.huge,
		BouncePositionHistory    = {},
		BouncePositionHead       = 0,
		VelocityDirectionEMA     = Vector3.zero,
		FirstBouncePosition      = nil,
		CornerBounceCount        = 0,
		BounceCallbackThread     = nil,
		CanHomeCallbackThread    = nil,
		CastFunctionThread       = nil,
		HomingProviderThread     = nil,
		TrajectoryProviderThread = nil,
		HomingElapsed            = 0,
		HomingDisengaged         = false,
		HomingAcquired           = false,
		LastDragRecalculateTime  = 0,
		CrossedThresholds        = {},
		IsSupersonic             = false,
		IsActivelyResimulating   = false,
		CancelResimulation       = false,
		CurrentSegmentSize       = 0,
		IsLOD                    = false,
		LODFrameAccumulator      = 0,
		LODDeltaAccumulator      = 0,
		SpatialFrameAccumulator  = 0,
		SpatialDeltaAccumulator  = 0,
		CosmeticBulletObject     = nil,
		ParentCastId             = nil,
		PenetrationForceRemaining= nil,
		IsTumbling               = false,
		TumbleRandom             = nil,
		Orientation              = CFrame.identity,
		AngularVelocity          = Vector3.zero,
		AngleOfAttack            = 0,
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
		DragModel                  = Enums.DragModel.Quadratic,
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
		SpinVector                 = Vector3.zero,
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
		SixDOFEnabled              = false,
		LiftCoefficientSlope       = 0,
		PitchingMomentSlope        = 0,
		PitchDampingCoeff          = 0,
		RollDampingCoeff           = 0,
		AoADragFactor              = 0,
		ReferenceArea              = 0,
		ReferenceLength            = 0,
		AirDensity                 = 0,
		MomentOfInertia            = 0,
		SpinMOI                    = 0,
		MaxAngularSpeed            = 0,
		InitialOrientation         = nil,
		InitialAngularVelocity     = nil,
	}
end

-- Allocate a brand new Cast table tree. Called only when the pool is empty.
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

-- Lightweight tombstone called by Fluix at Release time.
-- Marks the cast dead; the full field reset happens at Acquire time via Apply.
local function _TombstoneCast(Cast: any)
	Cast.Alive = false
end

-- Reset all Runtime fields to their initial values, reusing existing nested
-- tables (Trajectories, PiercedInstances, etc.) rather than replacing them.
-- Every field must be listed explicitly — a missed field means stale state
-- bleeds into the next cast.
local function ResetRuntime(Runtime: any, Behavior: any, InitialTrajectory: any, InitialSegmentSize: number, IsSupersonic: boolean)
	-- Reset callback fields that Fire() assigns with bare assignment (no nil fallback).
	Behavior.CanPierceFunction          = nil
	Behavior.CanBounceFunction          = nil
	Runtime.TotalRuntime                = 0
	Runtime.DistanceCovered             = 0
	table.clear(Runtime.Trajectories)
	Runtime.Trajectories[1]             = InitialTrajectory
	Runtime.ActiveTrajectory            = InitialTrajectory
	table.clear(Runtime.TerminationCancelCounts)
	Runtime.PierceCount                 = 0
	table.clear(Runtime.PiercedInstances)
	Runtime.PierceCallbackThread        = nil
	Runtime.BounceCount                 = 0
	Runtime.BouncesThisFrame            = 0
	Runtime.LastBounceTime              = -math.huge
	table.clear(Runtime.BouncePositionHistory)
	Runtime.BouncePositionHead          = 0
	Runtime.VelocityDirectionEMA        = Constants.ZERO_VECTOR
	Runtime.FirstBouncePosition         = nil
	Runtime.CornerBounceCount           = 0
	Runtime.BounceCallbackThread        = nil
	Runtime.CanHomeCallbackThread       = nil
	Runtime.CastFunctionThread          = nil
	Runtime.HomingElapsed               = 0
	Runtime.HomingDisengaged            = false
	Runtime.HomingAcquired              = false
	Runtime.HomingProviderThread        = nil
	Runtime.TrajectoryProviderThread    = nil
	Runtime.LastDragRecalculateTime     = 0
	table.clear(Runtime.CrossedThresholds)
	Runtime.IsSupersonic                = IsSupersonic
	Runtime.IsActivelyResimulating      = false
	Runtime.CancelResimulation          = false
	Runtime.CurrentSegmentSize          = InitialSegmentSize
	Runtime.IsLOD                       = false
	Runtime.LODFrameAccumulator         = 0
	Runtime.LODDeltaAccumulator         = 0
	Runtime.SpatialFrameAccumulator     = 0
	Runtime.SpatialDeltaAccumulator     = 0
	Runtime.CosmeticBulletObject        = nil
	Runtime.ParentCastId                = nil
	Runtime.PenetrationForceRemaining   = nil
	Runtime.IsTumbling                  = false
	Runtime.TumbleRandom                = nil
	Runtime.Orientation                 = CFrame.identity
	Runtime.AngularVelocity             = Vector3.zero
	Runtime.AngleOfAttack               = 0
end

-- ─── Pool Construction ───────────────────────────────────────────────────────

-- Create a new Fluix-backed pool. Each Solver gets its own pool so pools
-- never share state across solver instances.
function CastPool.new(): any
	return Fluix.new({
		Factory = NewCast,
		Reset   = _TombstoneCast,
		MinSize = 8,
		MaxSize = MAX_POOL_SIZE,
	})
end

-- ─── Acquire ─────────────────────────────────────────────────────────────────

-- Pop a Cast from the pool and stamp it with the provided state via an Apply
-- callback. If the pool is empty, Fluix allocates a fresh Cast tree.
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
	return Pool:Acquire(function(Cast: any)
		Cast.Alive     = true
		Cast.Paused    = false
		Cast.StartTime = StartTime
		Cast.Id        = Id
		ResetRuntime(Cast.Runtime, Cast.Behavior, InitialTrajectory, InitialSegmentSize, IsSupersonic)
		table.clear(Cast.UserData)
		setmetatable(Cast, SharedMetatable)
	end)
end

-- ─── Release ─────────────────────────────────────────────────────────────────

-- Return a terminated Cast to the pool for reuse.
-- Fluix calls _TombstoneCast (sets Alive = false) then enqueues the object.
-- Full reset happens at the next Acquire — Release stays cheap.
function CastPool.Release(Pool: any, Cast: any)
	Pool:Release(Cast)
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
