--!optimize 2
--!strict
--!native


local Parallel = script.Parent.Parent
local Vetra    = Parallel.Parent
local Core     = Vetra.Core
local Physics  = Vetra.Physics
local Signals  = Vetra.Signals


local Constants     = require(Core.Constants)
local Kinematics    = require(Physics.Kinematics)
local BouncePhysics = require(Physics.Bounce)
local PiercePhysics = require(Physics.Pierce)
local Fragmentation = require(Physics.Fragmentation)
local SixDOFPhysics = require(Physics.SixDOF)
local TumblePhysics = require(Physics.Tumble)
local FireHelpers   = require(Signals.FireHelpers)
local HookHelpers   = require(Signals.HookHelpers)
local Visualizer    = require(Core.TrajectoryVisualizer)
local TypeDefinition = require(Vetra.Types)
local Enums			= require(Core.Enums)

type VetraCast      = TypeDefinition.VetraCast
type ResumeSyncData = TypeDefinition.ResumeSyncData
type ParallelResult = TypeDefinition.ParallelResult

local cframe_new     = CFrame.new
local table_insert   = table.insert
local math_abs       = math.abs
local ZERO_VECTOR          = Constants.ZERO_VECTOR
local PARALLEL_EVENT       = Constants.PARALLEL_EVENT
local VISUALIZER_HIT_TYPE  = Constants.VISUALIZER_HIT_TYPE
local TERMINATE_REASON     = Enums.TerminateReason
local MIN_DOT_SQ          = Constants.MIN_DOT_SQ
local NUDGE               = Constants.NUDGE
local LOOK_AT_FALLBACK    = Constants.LOOK_AT_FALLBACK
local SPEED_OF_SOUND      = Constants.SPEED_OF_SOUND
local THRESHOLD_DIRECTION = Constants.THRESHOLD_DIRECTION

local StepSpeedProfiles: (any, VetraCast, Vector3) -> ()

local function ApplyRuntimeUpdate(Cast: VetraCast, EventData: ParallelResult)
	local Runtime                   = Cast.Runtime
	Runtime.TotalRuntime            = EventData.TotalRuntime
	Runtime.ConfirmedRuntime        = EventData.TotalRuntime
	Runtime.DistanceCovered         = EventData.DistanceCovered
	Runtime.IsSupersonic            = EventData.IsSupersonic
	Runtime.LastDragRecalculateTime = EventData.LastDragRecalcTime
	Runtime.HomingElapsed           = EventData.HomingElapsed
	Runtime.HomingDisengaged        = EventData.HomingDisengaged
	Runtime.HomingAcquired          = EventData.HomingAcquired
	Runtime.CurrentSegmentSize      = EventData.CurrentSegmentSize
	Runtime.BouncesThisFrame        = EventData.BouncesThisFrame
	Runtime.IsLOD                   = EventData.IsLOD
	Runtime.LODFrameAccumulator     = EventData.LODFrameAccumulator
	Runtime.LODDeltaAccumulator     = EventData.LODDeltaAccumulator
	Runtime.SpatialFrameAccumulator = EventData.SpatialFrameAccumulator
	Runtime.SpatialDeltaAccumulator = EventData.SpatialDeltaAccumulator
	Cast.Behavior.SpinVector        = EventData.SpinVector
	if EventData.Orientation ~= nil then
		Runtime.Orientation     = EventData.Orientation
		Runtime.AngularVelocity = EventData.AngularVelocity
		Runtime.AngleOfAttack   = EventData.AngleOfAttack
	end
end

local function ApplyTrajectory(Cast: VetraCast, Trajectory: TypeDefinition.ParallelTrajectorySegment?)
	if not Trajectory then return end
	local Runtime = Cast.Runtime
	local Last    = Runtime.ActiveTrajectory
	Last.EndTime  = Runtime.TotalRuntime
	local Segment = {
		StartTime       = Trajectory.StartTime,
		EndTime         = -1,
		Origin          = Trajectory.Origin,
		InitialVelocity = Trajectory.InitialVelocity,
		Acceleration    = Trajectory.Acceleration,
	}
	table_insert(Runtime.Trajectories, Segment)
	Runtime.ActiveTrajectory = Segment
end

local function ParallelTerminate(
	Coord       : any,
	Solver      : any,
	Cast        : VetraCast,
	Terminate   : any,
	Reason      : string,
	HitResult   : any,
	Velocity    : Vector3,
	WasSuspended: boolean
)
	local Cancelled, MutatedReason = HookHelpers.FireOnPreTermination(Solver, Cast, Reason)
	local EffectiveReason          = MutatedReason or Reason

	if Cancelled then
		local Counts = Cast.Runtime.TerminationCancelCounts
		local Count  = (Counts[Reason] or 0) + 1
		Counts[Reason] = Count
		if Count >= 3 then
			Counts[Reason] = nil
			FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
			Terminate(Solver, Cast, EffectiveReason)
		elseif WasSuspended then
			local Runtime = Cast.Runtime
			Coord:_ResumeCast(Cast, {
				TotalRuntime    = Runtime.TotalRuntime,
				DistanceCovered = Runtime.DistanceCovered,
				PierceCount     = Runtime.PierceCount,
			})
		end
	else
		Cast.Runtime.TerminationCancelCounts[Reason] = nil
		FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
		Terminate(Solver, Cast, EffectiveReason)
	end
end

local function HandleHit(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any, Ctx: any)
	StepSpeedProfiles(Solver, Cast, EventData.TravelVelocity or ZERO_VECTOR)

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	local HitInstance = (Ctx and Ctx.HitInstance)
	local FakeResult
	if HitInstance then
		FakeResult = {
			Position = EventData.HitPosition,
			Normal   = EventData.HitNormal,
			Material = EventData.HitMaterial,
			Instance = HitInstance,
		}
	end

	local Velocity = EventData.TravelVelocity or ZERO_VECTOR

	if Cast.Behavior.VisualizeCasts then
		local HitPoint = EventData.HitPosition or EventData.TravelPosition
		if HitPoint then
			if EventData.VisualizationRayOrigin then
				local SegmentVector = HitPoint - EventData.VisualizationRayOrigin
				local SegmentLength = SegmentVector.Magnitude
				if SegmentLength > 0.001 then
					Visualizer.Segment(cframe_new(EventData.VisualizationRayOrigin, HitPoint), SegmentLength)
				end
			end
			if EventData.IsCornerTrap then
				Visualizer.CornerTrap(HitPoint)
			else
				Visualizer.Hit(cframe_new(HitPoint), VISUALIZER_HIT_TYPE.Terminal)
			end
		end
	end

	local Reason = EventData.IsCornerTrap and TERMINATE_REASON.CornerTrap or TERMINATE_REASON.Hit
	ParallelTerminate(Coord, Solver, Cast, Terminate, Reason, FakeResult, Velocity, false)
end

local function HandleBounce(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any, Ctx: any)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local HitInstance = (Ctx and Ctx.HitInstance)
	local FakeResult  = {
		Position = EventData.HitPosition,
		Normal   = EventData.HitNormal,
		Material = EventData.HitMaterial,
		Instance = HitInstance,
	}

	local CurrentVelocity = EventData.PreBounceVelocity or ZERO_VECTOR

	StepSpeedProfiles(Solver, Cast, CurrentVelocity)

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	local Context   = Solver._CastToBulletContext[Cast]

	local CanBounce = Behavior.CanBounceFunction and Behavior.CanBounceFunction(Context, FakeResult, CurrentVelocity)


	if Behavior.VisualizeCasts and EventData.VisualizationRayOrigin and EventData.HitPosition then
		local SegmentVector = EventData.HitPosition - EventData.VisualizationRayOrigin
		local SegmentLength = SegmentVector.Magnitude
		if SegmentLength > 0.001 then
			Visualizer.Segment(cframe_new(EventData.VisualizationRayOrigin, EventData.HitPosition), SegmentLength)
		end
	end

	if not CanBounce or EventData.IsCornerTrap then
		if Behavior.VisualizeCasts and EventData.HitPosition then
			if EventData.IsCornerTrap then
				Visualizer.CornerTrap(EventData.HitPosition)
			else
				Visualizer.Hit(cframe_new(EventData.HitPosition), VISUALIZER_HIT_TYPE.Terminal)
			end
		end
		local Reason = EventData.IsCornerTrap and TERMINATE_REASON.CornerTrap or TERMINATE_REASON.Hit
		ParallelTerminate(Coord, Solver, Cast, Terminate, Reason, FakeResult, CurrentVelocity, true)
		return
	end

	local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(Solver, Cast, FakeResult, CurrentVelocity)
	local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
	local FinalVelocity, BaseRestitution, NormalPerturbation = HookHelpers.FireOnMidBounce(Solver, Cast, FakeResult, ReflectedVelocity)
	local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, EventData.HitMaterial)

	FinalVelocity = BouncePhysics.ApplyRestitution(
		Cast, FinalVelocity, EffectiveNormal, BaseRestitution, MaterialMultiplier, NormalPerturbation
	)

	local PostBounceOrigin = EventData.HitPosition + EffectiveNormal * NUDGE

	if Behavior.VisualizeCasts and EventData.HitPosition then
		Visualizer.Hit(cframe_new(EventData.HitPosition), VISUALIZER_HIT_TYPE.Bounce)
		Visualizer.Normal(EventData.HitPosition, EffectiveNormal)
		Visualizer.Velocity(EventData.HitPosition, FinalVelocity)
	end

	Runtime.BounceCount += 1

	if EffectiveNormal:Dot(EffectiveNormal) > MIN_DOT_SQ then
		BouncePhysics.RecordBounceState(Cast, EffectiveNormal, EventData.HitPosition, FinalVelocity)
	end

	Runtime.LastBounceTime = Runtime.TotalRuntime

	local NewSegment = Kinematics.OpenFreshSegment(
		Cast, PostBounceOrigin, FinalVelocity, Runtime.ActiveTrajectory.Acceleration
	)
	FireHelpers.FireOnSegmentOpen(Solver, Cast, NewSegment)

	if Behavior.ResetPierceOnBounce then
		Cast:ResetPierceState()
	end

	local SixDOFOrientation, SixDOFAngularVelocity = nil, nil
	if Behavior.SixDOFEnabled then
		SixDOFPhysics.OnBounce(Cast, EffectiveNormal, FinalVelocity, BaseRestitution * MaterialMultiplier)
		SixDOFOrientation     = Runtime.Orientation
		SixDOFAngularVelocity = Runtime.AngularVelocity
	end

	FireHelpers.FireOnBounce(Solver, Cast, FakeResult, FinalVelocity, CurrentVelocity)

	Coord:_ResumeCast(Cast, {
		TrajectoryOrigin          = NewSegment.Origin,
		TrajectoryInitialVelocity = NewSegment.InitialVelocity,
		TrajectoryAcceleration    = NewSegment.Acceleration,
		TrajectoryStartTime       = NewSegment.StartTime,

		TotalRuntime     = Runtime.TotalRuntime,
		DistanceCovered  = Runtime.DistanceCovered,
		BounceCount      = Runtime.BounceCount,
		BouncesThisFrame = Runtime.BouncesThisFrame,
		LastBounceTime   = Runtime.LastBounceTime,

		BouncePositionHistory = Runtime.BouncePositionHistory,
		BouncePositionHead    = Runtime.BouncePositionHead,
		VelocityDirectionEMA  = Runtime.VelocityDirectionEMA,
		FirstBouncePosition   = Runtime.FirstBouncePosition,
		CornerBounceCount     = Runtime.CornerBounceCount,

		Orientation     = SixDOFOrientation,
		AngularVelocity = SixDOFAngularVelocity,

		RemainingResimDelta = EventData.RemainingResimDelta or nil,
	})
end

local function HandlePierce(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any, Ctx: any)
	local Behavior    = Cast.Behavior
	local HitInstance = (Ctx and Ctx.HitInstance)
	local FakeResult  = {
		Position = EventData.HitPosition,
		Normal   = EventData.HitNormal,
		Material = EventData.HitMaterial,
		Instance = HitInstance,
	}

	local CurrentVelocity = EventData.TravelVelocity or ZERO_VECTOR
	local Context         = Solver._CastToBulletContext[Cast]

	local PierceSpeed        = CurrentVelocity.Magnitude
	local IsAbovePierceSpeed = PierceSpeed >= Behavior.PierceSpeedThreshold
	local IsBelowMaxPierce   = Cast.Runtime.PierceCount < Behavior.MaxPierceCount

	local MeetsNormalBias = true
	local ImpactDot       = EventData.ImpactDot
	if ImpactDot == nil then
		local RayOrigin = EventData.RayOrigin
		local HitNormal = EventData.HitNormal
		if RayOrigin and HitNormal and EventData.HitPosition then
			local Incident = EventData.HitPosition - RayOrigin
			if Incident:Dot(Incident) > MIN_DOT_SQ then
				ImpactDot = math_abs(Incident.Unit:Dot(HitNormal))
			end
		end
	end
	if ImpactDot ~= nil then
		MeetsNormalBias = ImpactDot >= (1.0 - Behavior.PierceNormalBias)
	end

	local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

	local CanPierce = EligibleForPierce
		and Behavior.CanPierceFunction
		and Behavior.CanPierceFunction(Context, FakeResult, CurrentVelocity)

	StepSpeedProfiles(Solver, Cast, CurrentVelocity)

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData.Trajectory)

	if not CanPierce then
		local Runtime  = Cast.Runtime
		local CurrentSpeed = CurrentVelocity.Magnitude

		local IsAboveBounceSpeed = CurrentSpeed >= Behavior.BounceSpeedThreshold
		local IsBelowMaxBounce   = Runtime.BounceCount < Behavior.MaxBounces
		local IsBelowFrameBounce = Runtime.BouncesThisFrame < Behavior.MaxBouncesPerFrame
		local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

		local CanBounceCallback = Behavior.CanBounceFunction
		local CanBounce = CanBounceCallback and CanBounceCallback(Context, FakeResult, CurrentVelocity)

		local WasCornerTrapped = false
		if EligibleForBounce and CanBounce then
			local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(Solver, Cast, FakeResult, CurrentVelocity)
			local IsCornerTrap = BouncePhysics.IsCornerTrap(Cast, EffectiveNormal, EventData.HitPosition)
			WasCornerTrapped = IsCornerTrap

			if not IsCornerTrap then
				local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
				local FinalVelocity, BaseRestitution, NormalPerturbation = HookHelpers.FireOnMidBounce(Solver, Cast, FakeResult, ReflectedVelocity)
				local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, EventData.HitMaterial)
				FinalVelocity = BouncePhysics.ApplyRestitution(Cast, FinalVelocity, EffectiveNormal, BaseRestitution, MaterialMultiplier, NormalPerturbation)

				local PostBounceOrigin = EventData.HitPosition + EffectiveNormal * NUDGE

				Runtime.BounceCount      += 1
				Runtime.BouncesThisFrame += 1
				if EffectiveNormal:Dot(EffectiveNormal) > MIN_DOT_SQ then
					BouncePhysics.RecordBounceState(Cast, EffectiveNormal, EventData.HitPosition, FinalVelocity)
				end
				Runtime.LastBounceTime = Runtime.TotalRuntime

				local NewSegment = Kinematics.OpenFreshSegment(Cast, PostBounceOrigin, FinalVelocity, Runtime.ActiveTrajectory.Acceleration)
				FireHelpers.FireOnSegmentOpen(Solver, Cast, NewSegment)

				if Behavior.ResetPierceOnBounce then
					Cast:ResetPierceState()
				end

				local PierceBounceOrientation, PierceBounceAngVel = nil, nil
				if Behavior.SixDOFEnabled then
					SixDOFPhysics.OnBounce(Cast, EffectiveNormal, FinalVelocity, BaseRestitution * MaterialMultiplier)
					PierceBounceOrientation = Runtime.Orientation
					PierceBounceAngVel      = Runtime.AngularVelocity
				end

				FireHelpers.FireOnBounce(Solver, Cast, FakeResult, FinalVelocity, CurrentVelocity)
				Coord:_ResumeCast(Cast, {
					TrajectoryOrigin          = NewSegment.Origin,
					TrajectoryInitialVelocity = NewSegment.InitialVelocity,
					TrajectoryAcceleration    = NewSegment.Acceleration,
					TrajectoryStartTime       = NewSegment.StartTime,
					TotalRuntime              = Runtime.TotalRuntime,
					DistanceCovered           = Runtime.DistanceCovered,
					BounceCount               = Runtime.BounceCount,
					BouncesThisFrame          = Runtime.BouncesThisFrame,
					LastBounceTime            = Runtime.LastBounceTime,
					Orientation               = PierceBounceOrientation,
					AngularVelocity           = PierceBounceAngVel,
					BouncePositionHistory     = Runtime.BouncePositionHistory,
					BouncePositionHead        = Runtime.BouncePositionHead,
					VelocityDirectionEMA      = Runtime.VelocityDirectionEMA,
					FirstBouncePosition       = Runtime.FirstBouncePosition,
					CornerBounceCount         = Runtime.CornerBounceCount,
					RemainingResimDelta       = EventData.RemainingResimDelta or nil,
				})
				return
			end
		end

		if WasCornerTrapped and Behavior.VisualizeCasts and EventData.HitPosition then
			Visualizer.CornerTrap(EventData.HitPosition)
		end

		local Reason = WasCornerTrapped and TERMINATE_REASON.CornerTrap or TERMINATE_REASON.Hit
		ParallelTerminate(Coord, Solver, Cast, Terminate, Reason, FakeResult, CurrentVelocity, true)
		return
	end

	if Behavior.FragmentOnPierce and Behavior.FragmentCount > 0 then
		Fragmentation.SpawnFragments(
			Solver, Cast, EventData.HitPosition, CurrentVelocity
		)
	end


	local RayDirection = EventData.RayOrigin and (EventData.HitPosition - EventData.RayOrigin)

	if not RayDirection then
		RayDirection = CurrentVelocity
	end
	local FoundSolid, SolidResult, PostPierceVelocity = PiercePhysics.ResolveChain(
		Solver, Cast, FakeResult, RayDirection, CurrentVelocity
	)

	Coord:_UpdateFilter(Cast)

	if FoundSolid and SolidResult then
		ParallelTerminate(Coord, Solver, Cast, Terminate, TERMINATE_REASON.Hit, SolidResult, PostPierceVelocity, true)
		return
	end

	local Runtime = Cast.Runtime
	local TumbleBeganOnPierce = false
	if Behavior.TumbleOnPierce and not Runtime.IsTumbling then
		if TumblePhysics.CheckPierceTrigger(Cast) then
			TumbleBeganOnPierce = true
			FireHelpers.FireOnTumbleBegin(Solver, Cast, CurrentVelocity)
		end
	end

	Coord:_ResumeCast(Cast, {
		TotalRuntime    = Runtime.TotalRuntime,
		DistanceCovered = Runtime.DistanceCovered,
		PierceCount     = Runtime.PierceCount,

		IsTumbling = TumbleBeganOnPierce or nil,

		RemainingResimDelta = EventData.RemainingResimDelta or nil,
	})
end

local function HandleTrajUpdateLite(
	Cast: VetraCast,
	TotalRuntime: number, DistanceCovered: number,
	Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3, StartTime: number,
	Orientation: CFrame?, AngularVelocity: Vector3?, AngleOfAttack: number?
)
	local Runtime = Cast.Runtime
	Runtime.TotalRuntime     = TotalRuntime
	Runtime.ConfirmedRuntime = TotalRuntime
	Runtime.DistanceCovered  = DistanceCovered

	if Orientation then
		Runtime.Orientation     = Orientation
		Runtime.AngularVelocity = AngularVelocity
		Runtime.AngleOfAttack   = AngleOfAttack
	end

	local Last   = Runtime.ActiveTrajectory
	Last.EndTime = TotalRuntime
	local Segment = {
		StartTime       = StartTime,
		EndTime         = -1,
		Origin          = Origin,
		InitialVelocity = InitialVelocity,
		Acceleration    = Acceleration,
	}
	table_insert(Runtime.Trajectories, Segment)
	Runtime.ActiveTrajectory = Segment
end

local function HandleTrajUpdate(_Coord: any, _Solver: any, Cast: VetraCast, EventData: ParallelResult, _Terminate: any, _Ctx: any)
	Cast.Runtime.TotalRuntime    = EventData["TotalRuntime"]
	Cast.Runtime.DistanceCovered = EventData["DistanceCovered"]
	ApplyTrajectory(Cast, EventData["Trajectory"])
	if EventData.Orientation ~= nil then
		Cast.Runtime.Orientation     = EventData.Orientation
		Cast.Runtime.AngularVelocity = EventData.AngularVelocity
		Cast.Runtime.AngleOfAttack   = EventData.AngleOfAttack
	end
end

function StepSpeedProfiles(Solver: any, Cast: VetraCast, Velocity: Vector3)
	local Runtime      = Cast.Runtime
	local CurrentSpeed = Velocity.Magnitude

	local SpeedThresholds = Cast.Behavior.SpeedThresholds
	if SpeedThresholds and #SpeedThresholds > 0 then
		local CrossedThresholds = Runtime.CrossedThresholds
		for _, Threshold in SpeedThresholds do
			local WasAbove   = CrossedThresholds[Threshold] == true
			local IsNowAbove = CurrentSpeed >= Threshold
			if IsNowAbove ~= WasAbove then
				CrossedThresholds[Threshold] = IsNowAbove
				FireHelpers.FireOnSpeedThresholdCrossed(
					Solver, Cast, Threshold,
					IsNowAbove and THRESHOLD_DIRECTION.Ascending
						or THRESHOLD_DIRECTION.Descending,
					CurrentSpeed
				)
			end
		end
	end

	local IsNowSupersonic = CurrentSpeed >= SPEED_OF_SOUND
	if IsNowSupersonic ~= Runtime.IsSupersonic then
		Runtime.IsSupersonic = IsNowSupersonic
		FireHelpers.FireOnSpeedThresholdCrossed(
			Solver, Cast,
			SPEED_OF_SOUND,
			IsNowSupersonic and THRESHOLD_DIRECTION.Ascending
				or THRESHOLD_DIRECTION.Descending,
			CurrentSpeed
		)
	end
end

local function PlaceCosmetic(Cast: VetraCast, Position: Vector3, Velocity: Vector3, Orientation: CFrame?, Ctx: any)
	local CosmeticObject = Cast.Runtime.CosmeticBulletObject
	if not CosmeticObject then return end

	local CF
	if Orientation ~= nil then
		CF = cframe_new(Position) * (Orientation - Orientation.Position)
	else
		local LookDirection = Velocity:Dot(Velocity) > MIN_DOT_SQ
			and Velocity.Unit
			or LOOK_AT_FALLBACK
		CF = cframe_new(Position, Position + LookDirection)
	end

	if Ctx and CosmeticObject:IsA("BasePart") then
		table_insert(Ctx.CosmeticParts,   CosmeticObject)
		table_insert(Ctx.CosmeticCFrames, CF)
	else
		CosmeticObject:PivotTo(CF)
	end
end

local function HandleTravel(_Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, _Terminate: any, Ctx: any)
	if EventData["TotalRuntime"] ~= nil then
		Cast.Runtime.TotalRuntime    = EventData["TotalRuntime"]
		Cast.Runtime.ConfirmedRuntime = EventData["TotalRuntime"]
	end
	if EventData["Trajectory"] then
		ApplyTrajectory(Cast, EventData["Trajectory"])
	end

	if EventData.TumbleBegan or EventData.TumbleRecovered then
		Cast.Runtime.IsTumbling = EventData.IsTumbling
		local Velocity = EventData["TravelVelocity"] or ZERO_VECTOR
		if EventData.TumbleBegan then
			FireHelpers.FireOnTumbleBegin(Solver, Cast, Velocity)
		else
			FireHelpers.FireOnTumbleEnd(Solver, Cast, Velocity)
		end
	end

	if EventData.Orientation ~= nil then
		Cast.Runtime.Orientation     = EventData.Orientation
		Cast.Runtime.AngularVelocity = EventData.AngularVelocity
		Cast.Runtime.AngleOfAttack   = EventData.AngleOfAttack
	end

	local Position = EventData["TravelPosition"]
	local Velocity = EventData["TravelVelocity"]

	local HomingDisengaged = EventData["HomingDisengaged"]
	if HomingDisengaged ~= nil then
		if HomingDisengaged == true and not Cast.Runtime.HomingDisengaged then
			Cast.Runtime.HomingDisengaged = true
			FireHelpers.FireOnHomingDisengaged(Solver, Cast)
		else
			Cast.Runtime.HomingDisengaged = HomingDisengaged
		end
	end
	local HomingElapsed = EventData["HomingElapsed"]
	if HomingElapsed ~= nil then
		Cast.Runtime.HomingElapsed = HomingElapsed
	end

	if not (Position and Velocity) then return end

	if Cast.Behavior.VisualizeCasts then
		local VisualizationRayOrigin = EventData["VisualizationRayOrigin"]
		if VisualizationRayOrigin then
			local SegmentLength = (Position - VisualizationRayOrigin).Magnitude
			if SegmentLength > 0.001 then
				Visualizer.Segment(cframe_new(VisualizationRayOrigin, Position), SegmentLength)
			end
		end
	end

	StepSpeedProfiles(Solver, Cast, Velocity)

	FireHelpers.FireOnTravel(Solver, Cast, Position, Velocity)

	PlaceCosmetic(Cast, Position, Velocity, EventData.Orientation, Ctx)
end

local function HandleTravelLite(
	Solver: any, Cast: VetraCast,
	Position: Vector3, Velocity: Vector3, TotalRuntime: number, Ctx: any
)
	Cast.Runtime.TotalRuntime     = TotalRuntime
	Cast.Runtime.ConfirmedRuntime = TotalRuntime

	StepSpeedProfiles(Solver, Cast, Velocity)
	FireHelpers.FireOnTravel(Solver, Cast, Position, Velocity)
	PlaceCosmetic(Cast, Position, Velocity, nil, Ctx)
end

local function HandleTravelHomingLite(
	Solver: any, Cast: VetraCast,
	Position: Vector3, Velocity: Vector3, TotalRuntime: number,
	HomingElapsed: number, TrajOrigin: Vector3, TrajStartTime: number,
	Ctx: any
)
	local Runtime = Cast.Runtime
	Runtime.TotalRuntime     = TotalRuntime
	Runtime.ConfirmedRuntime = TotalRuntime
	Runtime.HomingElapsed    = HomingElapsed

	local Last   = Runtime.ActiveTrajectory
	Last.EndTime = TotalRuntime
	local Segment = {
		StartTime       = TrajStartTime,
		EndTime         = -1,
		Origin          = TrajOrigin,
		InitialVelocity = Velocity,
		Acceleration    = Last.Acceleration,
	}
	table_insert(Runtime.Trajectories, Segment)
	Runtime.ActiveTrajectory = Segment

	StepSpeedProfiles(Solver, Cast, Velocity)
	FireHelpers.FireOnTravel(Solver, Cast, Position, Velocity)
	PlaceCosmetic(Cast, Position, Velocity, nil, Ctx)
end

local function HandleTerminalEnd(Coord: any, Solver: any, Cast: VetraCast, EventData: ParallelResult, Terminate: any, _Ctx: any)
	local Velocity  = EventData["TravelVelocity"] or ZERO_VECTOR

	StepSpeedProfiles(Solver, Cast, Velocity)

	ApplyRuntimeUpdate(Cast, EventData)
	ApplyTrajectory(Cast, EventData["Trajectory"])

	local EventType = EventData["Event"]
	local Reason
	if EventType == PARALLEL_EVENT.DistanceEnd then
		Reason = TERMINATE_REASON.Distance
	elseif EventType == PARALLEL_EVENT.DisplacementEnd then
		Reason = TERMINATE_REASON.Displacement
	else
		Reason = TERMINATE_REASON.Speed
	end

	if Cast.Behavior.VisualizeCasts then
		local EndPosition            = EventData["TravelPosition"]
		local VisualizationRayOrigin = EventData["VisualizationRayOrigin"]
		if EndPosition then
			if VisualizationRayOrigin then
				local SegmentLength = (EndPosition - VisualizationRayOrigin).Magnitude
				if SegmentLength > 0.001 then
					Visualizer.Segment(cframe_new(VisualizationRayOrigin, EndPosition), SegmentLength)
				end
			end
			Visualizer.Hit(cframe_new(EndPosition), VISUALIZER_HIT_TYPE.Terminal)
		end
	end

	ParallelTerminate(Coord, Solver, Cast, Terminate, Reason, nil, Velocity, false)
end

return {
	[PARALLEL_EVENT.Hit]           = HandleHit,
	[PARALLEL_EVENT.Bounce]        = HandleBounce,
	[PARALLEL_EVENT.BouncePending] = HandleBounce,
	[PARALLEL_EVENT.PiercePending] = HandlePierce,

	[PARALLEL_EVENT.TrajUpdate]    = HandleTrajUpdate,
	[PARALLEL_EVENT.Travel]        = HandleTravel,
	[PARALLEL_EVENT.DistanceEnd]   = HandleTerminalEnd,
	[PARALLEL_EVENT.DisplacementEnd] = HandleTerminalEnd,
	[PARALLEL_EVENT.SpeedEnd]      = HandleTerminalEnd,

	HandleTravelLite       = HandleTravelLite,
	HandleTravelHomingLite = HandleTravelHomingLite,
	HandleTrajUpdateLite   = HandleTrajUpdateLite,

	StepSpeedProfiles = StepSpeedProfiles,
	PlaceCosmetic     = PlaceCosmetic,
	ApplyRuntimeUpdate = ApplyRuntimeUpdate,
	ApplyTrajectory    = ApplyTrajectory,
	ParallelTerminate  = ParallelTerminate,
}
