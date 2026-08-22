--!strict
--!optimize 2
--!native

local CastPool  = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local Dependencies = Vetra.Dependencies

local Constants = require(Core.Constants)
local Enums     = require(Core.Enums)
local Fluix     = require(Dependencies.Fluix)

local MAX_POOL_SIZE = 2048

local function NewRuntime(): any
	return {
		TotalRuntime             = 0,
		ConfirmedRuntime         = nil,
		IsThrottled              = false,
		DistanceCovered          = 0,
		SpawnOrigin              = Vector3.zero,
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
		CanHomeThisFrame         = true,
		LastDragRecalculateTime  = 0,
		CrossedThresholds        = {},
		IsSupersonic             = false,
		IsActivelyResimulating   = false,
		CurrentSegmentSize       = 0,
		IsLOD                    = false,
		LODFrameAccumulator      = 0,
		LODDeltaAccumulator      = 0,
		SpatialFrameAccumulator  = 0,
		SpatialDeltaAccumulator  = 0,
		SuspendFramesRemaining   = 0,
		SuspendTimeRemaining     = 0,
		SuspendDeltaAccumulator  = 0,
		CosmeticBulletObject     = nil,
		ParentCastId             = nil,
		PierceForceRemaining     = nil,
		IsTumbling               = false,
		TumbleRandom             = nil,
		BounceRandom             = nil,
		Orientation              = CFrame.identity,
		AngularVelocity          = Vector3.zero,
		AngleOfAttack            = 0,
		SixDOFAccumulator        = 0,
	}
end

local function NewBehavior(): any
	return {
		Acceleration               = Vector3.zero,
		MaxDistance                = 0,
		MaxDisplacement            = 0,
		MaxSpeed                   = math.huge,
		MinSpeed                   = 0,
		Gravity                    = Vector3.new(0, -workspace.Gravity, 0),
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
		PierceSpeedRetention       = 0,
		PierceNormalBias           = 0,
		PierceDepth                = 0,
		PierceForce                = 0,
		PierceThicknessLimit       = 500,
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
		LODInterval                = 3,
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
		StaticOccupancy            = nil,
		DynamicOccupancy           = nil,
		FireTravelEvents           = true,
	}
end

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

local function _TombstoneCast(Cast: any)
	Cast.Alive = false
end

local function ResetRuntime(Runtime: any, Behavior: any, InitialTrajectory: any, InitialSegmentSize: number, IsSupersonic: boolean)
	Behavior.CanPierceFunction          = nil
	Behavior.CanBounceFunction          = nil
	Runtime.TotalRuntime                = 0
	Runtime.ConfirmedRuntime            = nil
	Runtime.IsThrottled                 = false
	Runtime.DistanceCovered             = 0
	Runtime.SpawnOrigin                 = InitialTrajectory.Origin
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
	Runtime.CanHomeThisFrame            = true
	Runtime.HomingProviderThread        = nil
	Runtime.TrajectoryProviderThread    = nil
	Runtime.LastDragRecalculateTime     = 0
	table.clear(Runtime.CrossedThresholds)
	Runtime.IsSupersonic                = IsSupersonic
	Runtime.IsActivelyResimulating      = false
	Runtime.CurrentSegmentSize          = InitialSegmentSize
	Runtime.IsLOD                       = false
	Runtime.LODFrameAccumulator         = 0
	Runtime.LODDeltaAccumulator         = 0
	Runtime.SpatialFrameAccumulator     = 0
	Runtime.SpatialDeltaAccumulator     = 0
	Runtime.SuspendFramesRemaining      = 0
	Runtime.SuspendTimeRemaining        = 0
	Runtime.SuspendDeltaAccumulator     = 0
	Runtime.CosmeticBulletObject        = nil
	Runtime.ParentCastId                = nil
	Runtime.PierceForceRemaining        = nil
	Runtime.IsTumbling                  = false
	Runtime.TumbleRandom                = nil
	Runtime.BounceRandom                = nil
	Runtime.Orientation                 = CFrame.identity
	Runtime.AngularVelocity             = Vector3.zero
	Runtime.AngleOfAttack               = 0
	Runtime.SixDOFAccumulator           = 0
end

function CastPool.new(): any
	return Fluix.new({
		Factory = NewCast,
		Reset   = _TombstoneCast,
		MinSize = 8,
		MaxSize = MAX_POOL_SIZE,
	})
end

function CastPool.Acquire(
	Pool              : any,
	Id                : number,
	StartTime         : number,
	InitialTrajectory : any,
	InitialSegmentSize: number,
	IsSupersonic      : boolean,
	SharedMetatable   : any
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

function CastPool.Release(Pool: any, Cast: any)
	Pool:Release(Cast)
end

return table.freeze(CastPool)
