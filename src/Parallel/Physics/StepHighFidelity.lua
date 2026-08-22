--!native
--!optimize 2
--!strict

local StepHighFidelity = {}

local ParallelPhysicsFolder = script.Parent
local Vetra                 = ParallelPhysicsFolder.Parent.Parent
local Core                  = Vetra.Core
local Physics               = Vetra.Physics
local Pure                  = Physics.Pure

local Constants      = require(Core.Constants)
local TypeDefinition = require(Vetra.Types)

local Kinematics   = require(Physics.Kinematics)
local PureBounce   = require(Pure.Bounce)
local PureHoming   = require(Pure.Homing)
local PureCoriolis = require(Pure.Coriolis)
local PureTumble   = require(Pure.Tumble)

local DragRecalc = require(ParallelPhysicsFolder.DragRecalc)

local Profiler = require(Vetra.Profiler)

local math_abs   = math.abs
local math_floor = math.floor
local math_clamp = math.clamp
local math_min   = math.min
local math_max   = math.max
local os_clock   = os.clock

local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MAX_SUBSEGMENTS  = Constants.MAX_SUBSEGMENTS
local HF_SUBSEGMENT_SOFT_CAP = Constants.HF_SUBSEGMENT_SOFT_CAP
local RAY_ORIGIN_EPSILON     = Constants.RAY_ORIGIN_EPSILON
local PARALLEL_EVENT   = Constants.PARALLEL_EVENT


type TrajectorySegment = TypeDefinition.ParallelTrajectorySegment
type CastSnapshot      = TypeDefinition.CastSnapshot
type ParallelResult    = TypeDefinition.ParallelResult


local PositionAtTime = Kinematics.PositionAtTime
local VelocityAtTime = Kinematics.VelocityAtTime

function StepHighFidelity.StepHighFidelity(
	Snapshot:               CastSnapshot,
	StepDelta:              number,
	IsLOD:                  boolean,
	LODFrameAccumulator:    number,
	LODDeltaAccumulator:    number,
	SpatialFrameAccumulator: number,
	SpatialDeltaAccumulator: number,
	Budget: { RemainingUs: number, TotalUs: number }?
): ParallelResult?
	local FastPathNotClear = false
	local OccStatic  = Snapshot.StaticOccupancy
	local OccDynamic = Snapshot.DynamicOccupancy
	if (OccStatic ~= nil or OccDynamic ~= nil)
		and (Snapshot.HomingTarget == nil or Snapshot.HomingDisengaged)
		and Snapshot.ProvidedLastPosition == nil
		and Snapshot.ProvidedCurrentPosition == nil
		and Snapshot.ProvidedCurrentVelocity == nil
		and (Snapshot.CoriolisOmega == nil or Snapshot.CoriolisOmega:Dot(Snapshot.CoriolisOmega) == 0)
	then
		local DragMayRecalc = ((Snapshot.DragCoefficient or 0) > 0 or (Snapshot.MagnusCoefficient or 0) ~= 0 or Snapshot.SixDOFEnabled == true)
			and (Snapshot.TotalRuntime + StepDelta - Snapshot.LastDragRecalculateTime) >= Snapshot.DragSegmentInterval
		local TumbleMayChange = (Snapshot.TumbleSpeedThreshold ~= nil and Snapshot.TumbleSpeedThreshold > 0)
			or Snapshot.TumbleOnPierce == true
		if not DragMayRecalc and not TumbleMayChange then
			local FastT0 = Budget and os_clock() or 0

			local Origin       = Snapshot.TrajectoryOrigin
			local InitVel      = Snapshot.TrajectoryInitialVelocity
			local Accel        = Snapshot.TrajectoryAcceleration
			local ElapsedStart = Snapshot.TotalRuntime - Snapshot.TrajectoryStartTime
			local ElapsedEnd   = ElapsedStart + StepDelta
			local StartPos     = PositionAtTime(ElapsedStart, Origin, InitVel, Accel)
			local EndPos       = PositionAtTime(ElapsedEnd,   Origin, InitVel, Accel)

			local SpanDisp = EndPos - StartPos
			local Clear
			if Profiler.Enabled then
				local _p = os_clock()
				Clear = (OccStatic == nil or OccStatic:SegmentClear(StartPos, SpanDisp))
					and (OccDynamic == nil or OccDynamic:SegmentClear(StartPos, SpanDisp))
				Profiler.Add(Profiler.Phase.HfDda, os_clock() - _p)
			else
				Clear = (OccStatic == nil or OccStatic:SegmentClear(StartPos, SpanDisp))
					and (OccDynamic == nil or OccDynamic:SegmentClear(StartPos, SpanDisp))
			end


			if Clear then
				local NewRuntime  = Snapshot.TotalRuntime + StepDelta
				local NewDistance = Snapshot.DistanceCovered + (EndPos - StartPos).Magnitude
				local EndVelocity = VelocityAtTime(ElapsedEnd, InitVel, Accel)
				local EndSpeed    = EndVelocity.Magnitude

				local Event = PARALLEL_EVENT.Travel
				local MaxDisplacement = Snapshot.MaxDisplacement
				if NewDistance >= Snapshot.MaxDistance then
					Event = PARALLEL_EVENT.DistanceEnd
				elseif MaxDisplacement > 0 and (EndPos - Snapshot.SpawnOrigin).Magnitude >= MaxDisplacement then
					Event = PARALLEL_EVENT.DisplacementEnd
				elseif EndSpeed < Snapshot.MinSpeed or EndSpeed > Snapshot.MaxSpeed then
					Event = PARALLEL_EVENT.SpeedEnd
				end

				if Budget then
					Budget.RemainingUs -= (os_clock() - FastT0) * 1e6
				end

				local FR = Snapshot._FastResult
				if FR == nil then
					FR = {}
					Snapshot._FastResult = FR
				end
				FR.Id                      = Snapshot.Id
				FR.Event                   = Event
				FR.TotalRuntime            = NewRuntime
				FR.DistanceCovered         = NewDistance
				FR.IsSupersonic            = EndSpeed >= SPEED_OF_SOUND
				FR.LastDragRecalcTime      = Snapshot.LastDragRecalculateTime
				FR.SpinVector              = Snapshot.SpinVector
				FR.HomingElapsed           = Snapshot.HomingElapsed
				FR.HomingDisengaged        = Snapshot.HomingDisengaged
				FR.HomingAcquired          = Snapshot.HomingAcquired
				FR.CurrentSegmentSize      = Snapshot.CurrentSegmentSize
				FR.BouncesThisFrame        = Snapshot.BouncesThisFrame
				FR.IsLOD                   = IsLOD
				FR.LODFrameAccumulator     = LODFrameAccumulator
				FR.LODDeltaAccumulator     = LODDeltaAccumulator
				FR.SpatialFrameAccumulator = SpatialFrameAccumulator
				FR.SpatialDeltaAccumulator = SpatialDeltaAccumulator
				FR.Trajectory              = nil
				FR.IsTumbling              = Snapshot.IsTumbling
				FR.TumbleBegan             = false
				FR.TumbleRecovered         = false
				FR.TravelPosition          = EndPos
				FR.TravelVelocity          = EndVelocity
				FR.RayOrigin               = StartPos
				FR.VisualizationRayOrigin  = Snapshot.VisualizeCasts and StartPos or nil
				FR.HitInstance             = nil
				FR.HitPosition             = nil
				FR.HitNormal               = nil
				FR.HitMaterial             = nil
				FR.IsCornerTrap            = nil
				FR.RemainingResimDelta     = nil
				FR.FiredAccumulatedDelta   = nil
				if Snapshot.SixDOFEnabled then
					FR.Orientation     = Snapshot.Orientation
					FR.AngularVelocity = Snapshot.AngularVelocity
					FR.AngleOfAttack   = Snapshot.AngleOfAttack
				else
					FR.Orientation     = nil
					FR.AngularVelocity = nil
					FR.AngleOfAttack   = nil
				end
				return FR
			end

			FastPathNotClear = true
			if Budget then
				Budget.RemainingUs -= (os_clock() - FastT0) * 1e6
			end
		end
	end

	local TrajectoryOrigin          = Snapshot.TrajectoryOrigin
	local TrajectoryInitialVelocity = Snapshot.TrajectoryInitialVelocity
	local TrajectoryAcceleration    = Snapshot.TrajectoryAcceleration
	local TrajectoryStartTime       = Snapshot.TrajectoryStartTime
	local TotalRuntime              = Snapshot.TotalRuntime
	local DistanceCovered           = Snapshot.DistanceCovered
	local SpinVector                = Snapshot.SpinVector
	local LastDragRecalculateTime   = Snapshot.LastDragRecalculateTime
	local HomingElapsed             = Snapshot.HomingElapsed
	local HomingDisengaged          = Snapshot.HomingDisengaged
	local HomingAcquired            = Snapshot.HomingAcquired
	local BounceCount               = Snapshot.BounceCount
	local BouncesThisFrame          = Snapshot.BouncesThisFrame
	local PierceCount               = Snapshot.PierceCount
	local IsSupersonic              = Snapshot.IsSupersonic
	local CurrentSegmentSize        = Snapshot.CurrentSegmentSize
	local IsTumbling                = Snapshot.IsTumbling
	local TumbleBegan               = false
	local TumbleRecovered           = false
	local TumbleConfigured          = (Snapshot.TumbleSpeedThreshold ~= nil and Snapshot.TumbleSpeedThreshold > 0)
		or Snapshot.TumbleOnPierce == true
	local LatestTrajectory: TrajectorySegment? = nil

	local OriginalHistory = Snapshot.BouncePositionHistory
	local BounceHistory: { Vector3 } = {}
	for Index, Value in OriginalHistory do BounceHistory[Index] = Value end

	local BounceState: PureBounce.CornerState = {
		TotalRuntime                = Snapshot.TotalRuntime,
		LastBounceTime              = Snapshot.LastBounceTime,
		BouncePositionHistory       = BounceHistory,
		BouncePositionHead          = Snapshot.BouncePositionHead,
		CornerBounceCount           = Snapshot.CornerBounceCount,
		VelocityDirectionEMA        = Snapshot.VelocityDirectionEMA,
		FirstBouncePosition         = Snapshot.FirstBouncePosition,
		CornerTimeThreshold         = Snapshot.CornerTimeThreshold,
		CornerDisplacementThreshold = Snapshot.CornerDisplacementThreshold,
		CornerEMAAlpha              = Snapshot.CornerEMAAlpha,
		CornerEMAThreshold          = Snapshot.CornerEMAThreshold,
		CornerMinProgressPerBounce  = Snapshot.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = Snapshot.CornerPositionHistorySize or 4,
	}

	local Result = {
		Id                      = Snapshot.Id,
		Event                   = "travel",
		TotalRuntime            = TotalRuntime,
		DistanceCovered         = DistanceCovered,
		IsSupersonic            = IsSupersonic,
		LastDragRecalcTime      = LastDragRecalculateTime,
		SpinVector              = SpinVector,
		HomingElapsed           = HomingElapsed,
		HomingDisengaged        = HomingDisengaged,
		HomingAcquired          = HomingAcquired,
		CurrentSegmentSize      = CurrentSegmentSize,
		BouncesThisFrame        = BouncesThisFrame,
		IsTumbling              = IsTumbling,
		TumbleBegan             = TumbleBegan,
		TumbleRecovered         = TumbleRecovered,
		IsLOD                   = IsLOD,
		LODFrameAccumulator     = LODFrameAccumulator,
		LODDeltaAccumulator     = LODDeltaAccumulator,
		SpatialFrameAccumulator = SpatialFrameAccumulator,
		SpatialDeltaAccumulator = SpatialDeltaAccumulator,
		Trajectory              = nil :: TrajectorySegment?,
	}

	local function SyncResult()
		Result.TotalRuntime       = TotalRuntime
		Result.DistanceCovered    = DistanceCovered
		Result.IsSupersonic       = IsSupersonic
		Result.LastDragRecalcTime = LastDragRecalculateTime
		Result.SpinVector         = SpinVector
		Result.HomingElapsed      = HomingElapsed
		Result.HomingDisengaged   = HomingDisengaged
		Result.HomingAcquired     = HomingAcquired
		Result.CurrentSegmentSize = CurrentSegmentSize
		Result.BouncesThisFrame   = BouncesThisFrame
		Result.IsTumbling         = IsTumbling
		Result.TumbleBegan        = TumbleBegan
		Result.TumbleRecovered    = TumbleRecovered
		Result.Trajectory         = LatestTrajectory
		if Snapshot.SixDOFEnabled then
			Result.Orientation     = Snapshot.Orientation
			Result.AngularVelocity = Snapshot.AngularVelocity
			Result.AngleOfAttack   = Snapshot.AngleOfAttack
		end
	end

	local FrameFirstHitT = 0

	local function OpenTrajectorySegment(Origin: Vector3, InitialVelocity: Vector3, Acceleration: Vector3)
		TrajectoryOrigin          = Origin
		TrajectoryInitialVelocity = InitialVelocity
		TrajectoryAcceleration    = Acceleration
		TrajectoryStartTime       = TotalRuntime
		LatestTrajectory = {
			Origin          = Origin,
			InitialVelocity = InitialVelocity,
			Acceleration    = Acceleration,
			StartTime       = TotalRuntime,
		}
		FrameFirstHitT = 0
	end

	local ElapsedStart      = TotalRuntime - TrajectoryStartTime
	local PositionStart     = PositionAtTime(ElapsedStart, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local PositionEnd       = PositionAtTime(ElapsedStart + StepDelta, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local FrameDisplacement = (PositionEnd - PositionStart).Magnitude

	if (OccStatic ~= nil or OccDynamic ~= nil) and not FastPathNotClear then
		local _p; if Profiler.Enabled then _p = os_clock() end
		local FrameDisp = PositionEnd - PositionStart
		local StaticT  = OccStatic  == nil and math.huge or OccStatic:SegmentFirstHit(PositionStart, FrameDisp)
		local DynamicT = OccDynamic == nil and math.huge or OccDynamic:SegmentFirstHit(PositionStart, FrameDisp)
		FrameFirstHitT = StaticT < DynamicT and StaticT or DynamicT
		if Profiler.Enabled then Profiler.Add(Profiler.Phase.HfDda, os_clock() - _p) end
	else
		FrameFirstHitT = 0
	end

	local DesiredSubs = math_floor(FrameDisplacement / CurrentSegmentSize)
	local SubSegmentCount = math_clamp(DesiredSubs, 1, HF_SUBSEGMENT_SOFT_CAP)
	if DesiredSubs > MAX_SUBSEGMENTS then
		CurrentSegmentSize = math_min(
			CurrentSegmentSize * Snapshot.AdaptiveScaleFactor * 2,
			Snapshot.MaxDistance
		)
	end

	local SubSegmentDelta = StepDelta / SubSegmentCount
	local BudgetStartTime = os_clock()
	local BudgetLastMark  = BudgetStartTime
	local WasBudgetLimited = false

	for SubIndex = 1, SubSegmentCount do

		if Budget then
			local now = os_clock()
			Budget.RemainingUs -= (now - BudgetLastMark) * 1e6
			BudgetLastMark = now
			if Budget.RemainingUs <= 0 then
				WasBudgetLimited = true
				break
			end
		end

		local Recalculated, NewAcceleration, DragOrigin, DragVelocity, UpdatedSpin =
			DragRecalc.Step(
				Snapshot, TotalRuntime, LastDragRecalculateTime,
				{ Origin = TrajectoryOrigin, InitialVelocity = TrajectoryInitialVelocity,
					Acceleration = TrajectoryAcceleration, StartTime = TrajectoryStartTime },
				SpinVector
			)
		if Recalculated then
			SpinVector              = UpdatedSpin
			LastDragRecalculateTime = TotalRuntime
			OpenTrajectorySegment(DragOrigin, DragVelocity, NewAcceleration)
		end

		if Snapshot.HomingTarget and not HomingDisengaged then
			local Elapsed     = TotalRuntime - TrajectoryStartTime
			local SubVelocity = VelocityAtTime(Elapsed, TrajectoryInitialVelocity, TrajectoryAcceleration)
			local SubPosition = PositionAtTime(Elapsed, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)

			local HomingVelocity, HomingApplied, HomingTrajectory, NewElapsed, NewDisengaged =
				PureHoming.Step(
					HomingDisengaged,
					Snapshot.HomingTarget,
					HomingElapsed,
					Snapshot.HomingMaxDuration,
					Snapshot.HomingStrength,
					SubVelocity, SubPosition, SubSegmentDelta,
					TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration,
					TrajectoryStartTime, TotalRuntime
				)
			HomingElapsed    = NewElapsed
			HomingDisengaged = NewDisengaged
			if HomingApplied and HomingTrajectory then
				OpenTrajectorySegment(HomingTrajectory.Origin, HomingTrajectory.InitialVelocity, HomingTrajectory.Acceleration)
			end
		end

		local ElapsedBefore  = TotalRuntime - TrajectoryStartTime
		TotalRuntime        += SubSegmentDelta
		local ElapsedAfter   = TotalRuntime - TrajectoryStartTime

		local LastPosition: Vector3
		if SubIndex == 1 and Snapshot.ProvidedLastPosition then
			LastPosition = Snapshot.ProvidedLastPosition
		else
			LastPosition = PositionAtTime(ElapsedBefore, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
		end

		local CurrentTarget   = PositionAtTime(ElapsedAfter, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
		local CurrentVelocity = (SubIndex == 1 and Snapshot.ProvidedCurrentVelocity)
			or VelocityAtTime(ElapsedAfter, TrajectoryInitialVelocity, TrajectoryAcceleration)

		local CoriolisOmega = Snapshot.CoriolisOmega
		if CoriolisOmega and CoriolisOmega:Dot(CoriolisOmega) > 0 then
			local CoriolisAccel = PureCoriolis.ComputeAcceleration(CoriolisOmega, CurrentVelocity)
			CurrentVelocity     = CurrentVelocity + CoriolisAccel * SubSegmentDelta
			CurrentTarget      += CoriolisAccel * (SubSegmentDelta * SubSegmentDelta * 0.5)
		end

		local CurrentSpeed    = CurrentVelocity.Magnitude
		IsSupersonic          = CurrentSpeed >= SPEED_OF_SOUND

		if TumbleConfigured then
			if not IsTumbling then
				if PureTumble.ShouldBeginFromSpeed(CurrentSpeed, Snapshot.TumbleSpeedThreshold) then
					IsTumbling            = true
					Snapshot.IsTumbling   = true
					Snapshot.TumbleRandom = PureTumble.CreateRandom(Snapshot.Id)
					TumbleBegan           = true
				end
			elseif PureTumble.ShouldRecover(CurrentSpeed, Snapshot.TumbleRecoverySpeed) then
				IsTumbling            = false
				Snapshot.IsTumbling   = false
				Snapshot.TumbleRandom = nil
				TumbleRecovered       = true
			end
		end

		local Displacement = CurrentTarget - LastPosition
		if Displacement:Dot(Displacement) < MIN_MAGNITUDE_SQ then continue end

		local RaycastResult

		local SubSegEndT = SubIndex / SubSegmentCount

		if SubSegEndT <= FrameFirstHitT then
			RaycastResult = nil
		else
			local OriginMagnitude = math_max(
				math_abs(LastPosition.X), math_abs(LastPosition.Y), math_abs(LastPosition.Z)
			)
			local RayOrigin = LastPosition
				- Displacement.Unit * (math_max(OriginMagnitude, 1) * RAY_ORIGIN_EPSILON)
			local RayDisplacement = CurrentTarget - RayOrigin

			if Profiler.Enabled then
				local _p = os_clock()
				RaycastResult = workspace:Raycast(RayOrigin, RayDisplacement, Snapshot.RaycastParams)
				Profiler.Add(Profiler.Phase.HfRaycast, os_clock() - _p)
			else
				RaycastResult = workspace:Raycast(RayOrigin, RayDisplacement, Snapshot.RaycastParams)
			end
		end

		local HitPoint      = RaycastResult and RaycastResult.Position or CurrentTarget
		DistanceCovered    += (HitPoint - LastPosition).Magnitude

		if DistanceCovered >= Snapshot.MaxDistance then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.DistanceEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
			return Result
		end
		local MaxDisplacement = Snapshot.MaxDisplacement
		if MaxDisplacement > 0 and (HitPoint - Snapshot.SpawnOrigin).Magnitude >= MaxDisplacement then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.DisplacementEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
			return Result
		end
		if CurrentSpeed < Snapshot.MinSpeed or CurrentSpeed > Snapshot.MaxSpeed then
			SyncResult()
			Result.Event          = PARALLEL_EVENT.SpeedEnd
			Result.TravelPosition = CurrentTarget
			Result.TravelVelocity = CurrentVelocity
			Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
			return Result
		end

		if not RaycastResult then continue end

		local HitPosition = RaycastResult.Position
		local HitNormal   = RaycastResult.Normal
		local HitMaterial = RaycastResult.Material
		local HitInstance = RaycastResult.Instance

		local ImpactDot = math_abs(Displacement.Unit:Dot(HitNormal))

		local IsAbovePierceSpeed = CurrentSpeed >= Snapshot.PierceSpeedThreshold
		local IsBelowMaxPierce   = PierceCount < Snapshot.MaxPierceCount
		local MeetsNormalBias    = ImpactDot >= (1.0 - Snapshot.PierceNormalBias)
		local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

		local IsAboveBounceSpeed = CurrentSpeed >= Snapshot.BounceSpeedThreshold
		local IsBelowMaxBounce   = BounceCount < Snapshot.MaxBounces
		local IsBelowFrameBounce = BouncesThisFrame < Snapshot.MaxBouncesPerFrame
		local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

		if EligibleForPierce and Snapshot.HasCanPierceCallback then
			local RemainingDelta = SubSegmentDelta * (SubSegmentCount - SubIndex)
			SyncResult()
			Result.Event               = PARALLEL_EVENT.PiercePending
			Result.HitPosition         = HitPosition
			Result.HitNormal           = HitNormal
			Result.HitMaterial         = HitMaterial
			Result.HitInstance         = HitInstance
			Result.TravelPosition      = CurrentTarget
			Result.TravelVelocity      = CurrentVelocity
			Result.RemainingResimDelta = RemainingDelta
			Result.RayOrigin           = LastPosition
			Result.ImpactDot           = ImpactDot
			Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
			return Result
		end

		if EligibleForBounce then
			local ReflectedVel  = PureBounce.Reflect(CurrentVelocity, HitNormal)
			local MaterialMult  = Snapshot.MaterialRestitution and (Snapshot.MaterialRestitution[tostring(HitMaterial)] or 1.0) or 1.0
			local BounceRandom = Snapshot.BounceRandom
			if not BounceRandom and Snapshot.NormalPerturbation > 0 then
				BounceRandom          = PureBounce.CreateRandom(Snapshot.Id)
				Snapshot.BounceRandom = BounceRandom
			end
			local FinalVelocity = PureBounce.ApplyRestitution(
				ReflectedVel, HitNormal, Snapshot.Restitution, MaterialMult, Snapshot.NormalPerturbation, BounceRandom
			)

			local CornerTrap = PureBounce.IsCornerTrap(BounceState, HitPosition, TotalRuntime)

			local NewLastBounceTime, NewBouncePositionHead, NewBouncePositionHistory,
			NewCornerBounceCount, NewVelocityDirectionEMA, NewFirstBouncePosition =
				PureBounce.RecordBounceState(BounceState, HitPosition, FinalVelocity, TotalRuntime)

			BounceState.LastBounceTime          = NewLastBounceTime
			BounceState.BouncePositionHead      = NewBouncePositionHead
			BounceState.BouncePositionHistory   = NewBouncePositionHistory
			BounceState.CornerBounceCount       = NewCornerBounceCount
			BounceState.VelocityDirectionEMA    = NewVelocityDirectionEMA
			BounceState.FirstBouncePosition     = NewFirstBouncePosition

			if Snapshot.HasCanBounceCallback then
				local RemainingDelta = SubSegmentDelta * (SubSegmentCount - SubIndex)
				SyncResult()
				Result.Event                  = PARALLEL_EVENT.BouncePending
				Result.HitPosition            = HitPosition
				Result.HitNormal              = HitNormal
				Result.HitMaterial            = HitMaterial
				Result.HitInstance            = HitInstance
				Result.PreBounceVelocity      = CurrentVelocity
				Result.ReflectedVelocity      = FinalVelocity
				Result.IsCornerTrap           = CornerTrap
				Result.BounceCount            = BounceCount
				Result.LastBounceTime         = NewLastBounceTime
				Result.BouncePositionHistory  = NewBouncePositionHistory
				Result.BouncePositionHead     = NewBouncePositionHead
				Result.VelocityDirectionEMA   = NewVelocityDirectionEMA
				Result.FirstBouncePosition    = NewFirstBouncePosition
				Result.CornerBounceCount      = NewCornerBounceCount
				Result.BouncesThisFrame       = BouncesThisFrame + 1
				Result.TravelPosition         = CurrentTarget
				Result.TravelVelocity         = CurrentVelocity
				Result.RemainingResimDelta    = RemainingDelta
				Result.RayOrigin              = LastPosition
				Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
				return Result
			end

			if CornerTrap then
				SyncResult()
				Result.Event          = "hit"
				Result.IsCornerTrap   = true
				Result.HitPosition    = HitPosition
				Result.HitNormal      = HitNormal
				Result.HitMaterial    = HitMaterial
				Result.HitInstance    = HitInstance
				Result.TravelPosition = CurrentTarget
				Result.TravelVelocity = CurrentVelocity
				Result.RayOrigin      = LastPosition
				Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
				return Result
			end
		end

		SyncResult()
		Result.Event          = PARALLEL_EVENT.Hit
		Result.HitPosition    = HitPosition
		Result.HitNormal      = HitNormal
		Result.HitMaterial    = HitMaterial
		Result.HitInstance    = HitInstance
		Result.TravelPosition = CurrentTarget
		Result.TravelVelocity = CurrentVelocity
		Result.RayOrigin      = LastPosition
		Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and LastPosition or nil
		return Result
	end


	if Budget then
		Budget.RemainingUs -= (os_clock() - BudgetLastMark) * 1e6
	end

	local FinalElapsed  = TotalRuntime - TrajectoryStartTime
	local FinalPosition = PositionAtTime(FinalElapsed, TrajectoryOrigin, TrajectoryInitialVelocity, TrajectoryAcceleration)
	local FinalVelocity = VelocityAtTime(FinalElapsed, TrajectoryInitialVelocity, TrajectoryAcceleration)

	local ElapsedMs = (os_clock() - BudgetStartTime) * 1000
	if ElapsedMs > Snapshot.HighFidelityFrameBudget then
		CurrentSegmentSize = math_min(
			CurrentSegmentSize * Snapshot.AdaptiveScaleFactor,
			Snapshot.MaxDistance
		)
	elseif not WasBudgetLimited and ElapsedMs < Snapshot.HighFidelityFrameBudget * 0.5 then
		CurrentSegmentSize = math_max(
			CurrentSegmentSize / Snapshot.AdaptiveScaleFactor,
			Snapshot.MinSegmentSize
		)
	end

	SyncResult()
	Result.Event          = PARALLEL_EVENT.Travel
	Result.TravelPosition = FinalPosition
	Result.TravelVelocity = FinalVelocity
	Result.RayOrigin      = PositionStart
	Result.VisualizationRayOrigin = Snapshot.VisualizeCasts and PositionStart or nil
	return Result
end


return table.freeze(StepHighFidelity)
