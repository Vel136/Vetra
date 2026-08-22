--!native
--!optimize 2
--!strict

local SimulateCast  = {}

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals
local Simulation = script.Parent

local Enums           = require(Core.Enums)
local Constants       = require(Core.Constants)
local t               = require(Core.TypeCheck)
local Visualizer      = require(Core.TrajectoryVisualizer)
local Magnus          = require(Physics.Magnus)
local Kinematics      = require(Physics.Kinematics)
local BouncePhysics   = require(Physics.Bounce)
local PiercePhysics   = require(Physics.Pierce)
local DragPhysics     = require(Physics.Drag)
local HomingPhysics   = require(Physics.Homing)
local Fragmentation   = require(Physics.Fragmentation)
local CoriolisPhysics = require(Physics.Coriolis)
local PureGyroDrift   = require(Physics.Pure.GyroDrift)
local TumblePhysics   = require(Physics.Tumble)
local PureTumble      = require(Physics.Pure.Tumble)
local SixDOFPhysics   = require(Physics.SixDOF)
local FireHelpers     = require(Signals.FireHelpers)
local HookHelpers     = require(Signals.HookHelpers)
local Profiler        = require(Vetra.Profiler)

local os_clock_prof = os.clock

local THRESHOLD_DIRECTION       = Constants.THRESHOLD_DIRECTION
local LOOK_AT_FALLBACK          = Constants.LOOK_AT_FALLBACK
local MIN_MAGNITUDE_SQ          = Constants.MIN_MAGNITUDE_SQ
local MIN_DOT_SQ                = Constants.MIN_DOT_SQ
local PROVIDER_VELOCITY_EPSILON = Constants.PROVIDER_VELOCITY_EPSILON
local VISUALIZER_HIT_TYPE       = Constants.VISUALIZER_HIT_TYPE
local TERMINATE_REASON          = Enums.TerminateReason

local cframe_new = CFrame.new
local math_abs   = math.abs
local math_max   = math.max

local RAY_ORIGIN_EPSILON = Constants.RAY_ORIGIN_EPSILON

local VelocityAtTime = Kinematics.VelocityAtTime
local PositionAtTime = Kinematics.PositionAtTime

local function IsThreadHanging(Thread: thread?): boolean
	return Thread ~= nil and Thread ~= coroutine.running()
end

local function StepSpeedProfiles(Solver, Cast, CurrentSpeed)
	local Behavior = Cast.Behavior
	local Runtime  = Cast.Runtime

	if #Behavior.SpeedThresholds == 0 then return end

	for _, Threshold in Behavior.SpeedThresholds do
		local WasCrossed = Runtime.CrossedThresholds[Threshold]
		local IsAbove    = CurrentSpeed >= Threshold

		if IsAbove and not WasCrossed then
			Runtime.CrossedThresholds[Threshold] = true
			FireHelpers.FireOnSpeedThresholdCrossed(Solver, Cast, Threshold, THRESHOLD_DIRECTION.Ascending, CurrentSpeed)
		elseif not IsAbove and WasCrossed then
			Runtime.CrossedThresholds[Threshold] = false
			FireHelpers.FireOnSpeedThresholdCrossed(Solver, Cast, Threshold, THRESHOLD_DIRECTION.Descending, CurrentSpeed)
		end
	end
end

local function StepSonicTransition(Solver, Cast, CurrentSpeed, PrevSupersonic)
	local Runtime        = Cast.Runtime
	local IsNowSupersonic = CurrentSpeed >= Constants.SPEED_OF_SOUND

	if IsNowSupersonic == PrevSupersonic then return end

	Runtime.IsSupersonic = IsNowSupersonic
	FireHelpers.FireOnSpeedThresholdCrossed(
		Solver, Cast,
		Constants.SPEED_OF_SOUND,
		IsNowSupersonic and THRESHOLD_DIRECTION.Ascending or THRESHOLD_DIRECTION.Descending,
		CurrentSpeed
	)
end


local function HandleTermination(Solver: any,Cast: any,Reason: string,HitResult: RaycastResult?,Velocity: Vector3)
	local Terminate      = Solver._Terminate

	local Cancelled, MutatedReason = HookHelpers.FireOnPreTermination(Solver, Cast, Reason)
	local EffectiveReason = MutatedReason or Reason

	if Cancelled then
		local Counts = Cast.Runtime.TerminationCancelCounts
		local Count  = (Counts[Reason] or 0) + 1
		Counts[Reason] = Count
		if Count >= 3 then
			Counts[Reason] = nil
			FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
			Terminate(Solver, Cast, EffectiveReason)
		end
	else
		Cast.Runtime.TerminationCancelCounts[Reason] = nil
		FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
		Terminate(Solver, Cast, EffectiveReason)
	end
end


function SimulateCast.StepProjectile(Solver: any,Cast: any,Delta: number,IsSubSegment: boolean)
	local Terminate      = Solver._Terminate

	local Runtime          = Cast.Runtime
	local Behavior         = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory

	local BaseAcceleration = Solver._BaseAccelerationCache[Cast]

	local ShouldRecalculate = DragPhysics.ShouldRecalculate(Runtime, Runtime.TotalRuntime, Behavior.DragSegmentInterval)

	local NeedsDrag   = Behavior.DragCoefficient > 0
	local NeedsMagnus = Magnus.IsActive(Behavior)
	local Needs6DOF   = SixDOFPhysics.IsEnabled(Behavior)

	local _pDrag; if Profiler.Enabled then _pDrag = os_clock_prof() end
	if ShouldRecalculate and (NeedsDrag or NeedsMagnus or Needs6DOF) then
		if not BaseAcceleration then
			warn("_BaseAccelerationCache miss — recalc skipped this frame to avoid compounding deceleration")
		else
			local Elapsed         = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CurrentVelocity = VelocityAtTime(Elapsed, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
			local CurrentOrigin   = PositionAtTime(Elapsed, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)

			local NewAcceleration = BaseAcceleration

			local SixDOFDragMult = 1.0
			if Needs6DOF then
				local LiftAccel, DragMult = SixDOFPhysics.StepAngularState(
					Cast, CurrentVelocity, Behavior.DragSegmentInterval
				)
				NewAcceleration += LiftAccel
				SixDOFDragMult   = DragMult
			end

			if NeedsDrag then
				local Coeff, Model = DragPhysics.GetEffectiveDragCoefficient(Cast)
				local TumbleMult = TumblePhysics.GetDragMultiplier(Cast)
				NewAcceleration += DragPhysics.ComputeDragDeceleration(CurrentVelocity, Coeff * TumbleMult * SixDOFDragMult, Model, Behavior.CustomMachTable)
			end

			if NeedsMagnus then
				if Needs6DOF then
					local BodyFwd  = SixDOFPhysics.GetBodyForward(Cast)
					local SpinRate = BodyFwd:Dot(Cast.Runtime.AngularVelocity)
					NewAcceleration += Magnus.ComputeForce(BodyFwd * SpinRate, CurrentVelocity, Behavior.MagnusCoefficient)
				else
					Magnus.StepSpinDecay(Behavior, Behavior.DragSegmentInterval)
					NewAcceleration += Magnus.ComputeForce(Behavior.SpinVector, CurrentVelocity, Behavior.MagnusCoefficient)
				end
			end

			local WindEffect = (Solver._Wind and Solver._Wind:Dot(Solver._Wind) > 0)
				and (Solver._Wind * Behavior.WindResponse) or Constants.ZERO_VECTOR
			NewAcceleration += WindEffect

			if Behavior.GyroDriftRate then
				NewAcceleration += PureGyroDrift.ComputeForce(CurrentVelocity, Behavior.GyroDriftRate, Behavior.GyroDriftAxis)
			end

			if Runtime.IsTumbling then
				NewAcceleration += TumblePhysics.StepLateralForce(Cast, CurrentVelocity)
			end

			Kinematics.OpenFreshSegment(Cast, CurrentOrigin, CurrentVelocity, NewAcceleration)
			ActiveTrajectory = Runtime.ActiveTrajectory
			Runtime.LastDragRecalculateTime = Runtime.TotalRuntime
		end
	end
	if Profiler.Enabled then Profiler.Add(Profiler.Phase.DragRecalc, os_clock_prof() - _pDrag) end

	local _pKin; if Profiler.Enabled then _pKin = os_clock_prof() end
	local ElapsedBeforeAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime
	local PreviouslySupersonic = Runtime.IsSupersonic

	Runtime.TotalRuntime      += Delta
	local ElapsedAfterAdvance  = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	local LastPosition, CurrentTargetPosition, CurrentVelocity

	local Provider			   = Behavior.TrajectoryPositionProvider
	if Provider then
		local HasHanging = IsThreadHanging(Runtime.TrajectoryProviderThread)
		if not IsSubSegment and HasHanging then
			warn("TrajectoryPositionProvider yielded — falling back to kinematic this frame")
			Runtime.TrajectoryProviderThread = nil
			Provider = nil
		end
	end

	if Provider then
		local ElapsedLast    = Runtime.TotalRuntime - Delta
		local ElapsedCurrent = Runtime.TotalRuntime

		Runtime.TrajectoryProviderThread = coroutine.running()
		local ProvidedLast = Provider(ElapsedLast)
		Runtime.TrajectoryProviderThread = nil

		if t.Vector3(ProvidedLast) then
			LastPosition = ProvidedLast
		else
			warn("TrajectoryPositionProvider returned non-Vector3 for last position — falling back to kinematic")
			LastPosition = PositionAtTime(ElapsedBeforeAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		end

		Runtime.TrajectoryProviderThread = coroutine.running()
		local ProvidedCurrent = Provider(ElapsedCurrent)
		Runtime.TrajectoryProviderThread = nil


		if t.Vector3(ProvidedCurrent) then
			CurrentTargetPosition = ProvidedCurrent
		else
			warn("TrajectoryPositionProvider returned non-Vector3 for current position — falling back to kinematic")
			CurrentTargetPosition = PositionAtTime(ElapsedAfterAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		end

		Runtime.TrajectoryProviderThread = coroutine.running()
		local ProvidedForward = Provider(ElapsedCurrent + PROVIDER_VELOCITY_EPSILON)
		Runtime.TrajectoryProviderThread = nil
		if t.Vector3(ProvidedForward) then
			CurrentVelocity = (ProvidedForward - CurrentTargetPosition) / PROVIDER_VELOCITY_EPSILON
		else
			warn("TrajectoryPositionProvider returned non-Vector3 for velocity probe — using kinematic velocity")
			CurrentVelocity = VelocityAtTime(ElapsedAfterAdvance, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		end
	else
		LastPosition          = PositionAtTime(ElapsedBeforeAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		CurrentTargetPosition = PositionAtTime(ElapsedAfterAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		CurrentVelocity       = VelocityAtTime(ElapsedAfterAdvance, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
	end

	if HomingPhysics.IsActive(Cast) then
		local NewVelocity, HomingApplied = HomingPhysics.StepHoming(
			Cast,CurrentVelocity,LastPosition,Delta,Kinematics,Solver,IsSubSegment
		)
		if HomingApplied then
			CurrentVelocity  = NewVelocity
			ActiveTrajectory = Runtime.ActiveTrajectory
			FireHelpers.FireOnSegmentOpen(Solver, Cast, ActiveTrajectory)
			ElapsedAfterAdvance   = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			CurrentTargetPosition = PositionAtTime(ElapsedAfterAdvance,ActiveTrajectory.Origin,ActiveTrajectory.InitialVelocity,ActiveTrajectory.Acceleration)
		end
	end


	local CoriolisOmega = Solver._CoriolisOmega
	if CoriolisOmega and CoriolisOmega:Dot(CoriolisOmega) > 0 then
		local CoriolisAccel    = CoriolisPhysics.ComputeAcceleration(CoriolisOmega, CurrentVelocity)
		CurrentVelocity        = CurrentVelocity + CoriolisAccel * Delta
		CurrentTargetPosition += CoriolisAccel * (Delta * Delta * 0.5)
	end

	local CurrentSpeed         = CurrentVelocity.Magnitude
	local FrameDisplacement    = CurrentTargetPosition - LastPosition

	StepSpeedProfiles(Solver, Cast, CurrentSpeed)
	StepSonicTransition(Solver, Cast, CurrentSpeed, PreviouslySupersonic)

	if TumblePhysics.IsConfigured(Behavior) then
		if not Runtime.IsTumbling then
			if TumblePhysics.CheckSpeedTrigger(Cast, CurrentSpeed) then
				FireHelpers.FireOnTumbleBegin(Solver, Cast, CurrentVelocity)
			end
		else
			if TumblePhysics.CheckRecovery(Cast, CurrentSpeed) then
				FireHelpers.FireOnTumbleEnd(Solver, Cast, CurrentVelocity)
			end
		end
	end
	if not Cast.Alive then return end

	if FrameDisplacement:Dot(FrameDisplacement) < MIN_MAGNITUDE_SQ then return end

	local RayDirection = FrameDisplacement

	if IsThreadHanging(Runtime.CastFunctionThread) then
		Runtime.CastFunctionThread = nil
		Terminate(Solver, Cast, TERMINATE_REASON.Manual)
		error("CastFunction yielded — cast terminated")
		return
	end

	if Profiler.Enabled then Profiler.Add(Profiler.Phase.Kinematics, os_clock_prof() - _pKin) end

	local RaycastResult
	local S = Behavior.StaticOccupancy
	local D = Behavior.DynamicOccupancy
	local _pOcc; if Profiler.Enabled then _pOcc = os_clock_prof() end
	local ClearedByGrid = (S ~= nil or D ~= nil)
		and (S == nil or S:SegmentClear(LastPosition, RayDirection))
		and (D == nil or D:SegmentClear(LastPosition, RayDirection))
	if Profiler.Enabled then Profiler.Add(Profiler.Phase.Occupancy, os_clock_prof() - _pOcc) end
	if ClearedByGrid then
		RaycastResult = nil
	else
		local OriginMagnitude = math_max(
			math_abs(LastPosition.X), math_abs(LastPosition.Y), math_abs(LastPosition.Z)
		)
		local CastOrigin = LastPosition
			- RayDirection.Unit * (math_max(OriginMagnitude, 1) * RAY_ORIGIN_EPSILON)
		local CastDirection = CurrentTargetPosition - CastOrigin

		Runtime.CastFunctionThread = coroutine.running()
		local _pRay; if Profiler.Enabled then _pRay = os_clock_prof() end
		RaycastResult = Behavior.CastFunction(CastOrigin, CastDirection, Behavior.RaycastParams)
		if Profiler.Enabled then Profiler.Add(Profiler.Phase.Raycast, os_clock_prof() - _pRay) end
		Runtime.CastFunctionThread = nil
	end

	local _pPost; if Profiler.Enabled then _pPost = os_clock_prof() end
	local BulletHitPoint          = RaycastResult and RaycastResult.Position or CurrentTargetPosition
	local FrameRayDisplacement    = (BulletHitPoint - LastPosition).Magnitude

	Runtime.DistanceCovered += FrameRayDisplacement
	FireHelpers.FireOnTravel(Solver, Cast, BulletHitPoint, CurrentVelocity)

	if Runtime.CosmeticBulletObject then
		if SixDOFPhysics.IsEnabled(Behavior) then
			Runtime.CosmeticBulletObject.CFrame = SixDOFPhysics.ComposeCosmeticCFrame(BulletHitPoint, Runtime.Orientation)
		else
			local LookAtPoint = BulletHitPoint + (CurrentVelocity:Dot(CurrentVelocity) > MIN_DOT_SQ and CurrentVelocity.Unit or LOOK_AT_FALLBACK)
			Runtime.CosmeticBulletObject.CFrame = cframe_new(BulletHitPoint, LookAtPoint)
		end
	end

	if Behavior.VisualizeCasts and Delta > 0 then
		Visualizer.Segment(cframe_new(LastPosition, LastPosition + RayDirection), FrameRayDisplacement)
	end
	if Profiler.Enabled then Profiler.Add(Profiler.Phase.Signals, os_clock_prof() - _pPost) end

	if Runtime.DistanceCovered >= Behavior.MaxDistance then
		if Behavior.VisualizeCasts then
			Visualizer.Hit(cframe_new(CurrentTargetPosition), VISUALIZER_HIT_TYPE.Terminal)
		end
		HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
		return
	end

	local MaxDisplacement = Behavior.MaxDisplacement
	if MaxDisplacement > 0 then
		local Displacement = (BulletHitPoint - Runtime.SpawnOrigin).Magnitude
		if Displacement >= MaxDisplacement then
			if Behavior.VisualizeCasts then
				Visualizer.Hit(cframe_new(CurrentTargetPosition), VISUALIZER_HIT_TYPE.Terminal)
			end
			HandleTermination(Solver, Cast, TERMINATE_REASON.Displacement, nil, CurrentVelocity)
			return
		end
	end

	if CurrentSpeed < Behavior.MinSpeed or CurrentSpeed > Behavior.MaxSpeed then
		HandleTermination(Solver, Cast, TERMINATE_REASON.Speed, nil, CurrentVelocity)
		return
	end

	local IsHitOnCosmetic = RaycastResult and RaycastResult.Instance == Runtime.CosmeticBulletObject
	local IsValidHit      = RaycastResult ~= nil and not IsHitOnCosmetic

	if IsValidHit then
		local LinkedBulletContext = Solver._CastToBulletContext[Cast]
		local CanPierceCallback   = Behavior.CanPierceFunction


		local HasHangingPierce = IsThreadHanging(Runtime.PierceCallbackThread)
		if not IsSubSegment and CanPierceCallback and HasHangingPierce then
			Terminate(Solver, Cast, TERMINATE_REASON.Manual)
			error("CanPierceFunction yielded")
			return
		end

		local ImpactDot       	 = math_abs(RayDirection.Unit:Dot(RaycastResult.Normal))
		local IsAbovePierceSpeed = CurrentSpeed >= Behavior.PierceSpeedThreshold
		local IsBelowMaxPierce   = Runtime.PierceCount < Behavior.MaxPierceCount
		local MeetsNormalBias    = ImpactDot >= (1.0 - Behavior.PierceNormalBias)
		local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

		Runtime.PierceCallbackThread = coroutine.running()
		local CanPierce = CanPierceCallback and CanPierceCallback(LinkedBulletContext, RaycastResult, CurrentVelocity)
		Runtime.PierceCallbackThread = nil

		local PierceConditionsMet = CanPierce and EligibleForPierce

		local PierceResolved = false

		if PierceConditionsMet then
			if Behavior.FragmentOnPierce and Behavior.FragmentCount > 0 then
				Fragmentation.SpawnFragments(Solver,Cast,RaycastResult.Position,CurrentVelocity)
			end

			local FoundSolid, SolidResult, PostPierceVelocity = PiercePhysics.ResolveChain(Solver,Cast,RaycastResult,RayDirection,CurrentVelocity)

			if FoundSolid and SolidResult then
				if Behavior.VisualizeCasts then
					Visualizer.Hit(cframe_new(SolidResult.Position), VISUALIZER_HIT_TYPE.Terminal)
				end

				HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, SolidResult, PostPierceVelocity)
				return
			end
			PierceResolved = true

		if Behavior.TumbleOnPierce and not Runtime.IsTumbling then
			if TumblePhysics.CheckPierceTrigger(Cast) then
				FireHelpers.FireOnTumbleBegin(Solver, Cast, CurrentVelocity)
			end
		end
		end

		if not PierceResolved then
			local CanBounceCallback = Behavior.CanBounceFunction

			local HasHangingBounce = IsThreadHanging(Runtime.BounceCallbackThread)
			if not IsSubSegment and CanBounceCallback and HasHangingBounce then
				Terminate(Solver, Cast, TERMINATE_REASON.Manual)
				error("CanBounceFunction yielded")
				return
			end

			local IsAboveBounceSpeed = CurrentSpeed >= Behavior.BounceSpeedThreshold
			local IsBelowMaxBounce   = Runtime.BounceCount < Behavior.MaxBounces
			local IsBelowFrameBounce = Runtime.BouncesThisFrame < Behavior.MaxBouncesPerFrame
			local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce and IsBelowFrameBounce

			Runtime.BounceCallbackThread = coroutine.running()
			local CanBounce = CanBounceCallback and CanBounceCallback(LinkedBulletContext, RaycastResult, CurrentVelocity)
			Runtime.BounceCallbackThread = nil

			local BounceConditionsMet = CanBounce and EligibleForBounce

			if BounceConditionsMet then
				local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(Solver, Cast, RaycastResult, CurrentVelocity)

				local IsCornerTrapped = BouncePhysics.IsCornerTrap(Cast, EffectiveNormal, RaycastResult.Position)

				if not IsCornerTrapped then
					local PreBounceVelocity = EffectiveIncomingVelocity
					local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
					local FinalVelocity, BaseRestitution, NormalPerturbationAmount = HookHelpers.FireOnMidBounce(Solver, Cast, RaycastResult, ReflectedVelocity)

					local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, RaycastResult.Material)

					FinalVelocity = BouncePhysics.ApplyRestitution(Cast, FinalVelocity, EffectiveNormal, BaseRestitution, MaterialMultiplier, NormalPerturbationAmount)

					local PostBounceOrigin = RaycastResult.Position + EffectiveNormal * Constants.NUDGE

					if SixDOFPhysics.IsEnabled(Behavior) then
						SixDOFPhysics.OnBounce(Cast, EffectiveNormal, FinalVelocity, BaseRestitution * MaterialMultiplier)
					end

					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(RaycastResult.Position), VISUALIZER_HIT_TYPE.Bounce)
						Visualizer.Normal(RaycastResult.Position, EffectiveNormal)
						Visualizer.Velocity(RaycastResult.Position, FinalVelocity)
					end

					local FreshSegment = Kinematics.OpenFreshSegment(Cast, PostBounceOrigin, FinalVelocity, ActiveTrajectory.Acceleration)
					FireHelpers.FireOnSegmentOpen(Solver, Cast, FreshSegment)

					if EffectiveNormal:Dot(EffectiveNormal) > MIN_DOT_SQ then
						BouncePhysics.RecordBounceState(Cast, EffectiveNormal, RaycastResult.Position, FinalVelocity)
					end

					Runtime.BouncesThisFrame += 1

					if Behavior.ResetPierceOnBounce then
						Cast:ResetPierceState()
					end

					Runtime.BounceCount += 1
					FireHelpers.FireOnBounce(Solver, Cast, RaycastResult, FinalVelocity, PreBounceVelocity)
					return
				else
					if Behavior.VisualizeCasts then
						Visualizer.CornerTrap(RaycastResult.Position)
					end
					HandleTermination(Solver, Cast, TERMINATE_REASON.CornerTrap, RaycastResult, CurrentVelocity)
					return
				end
			end

			HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, RaycastResult, CurrentVelocity)
			return
		end
	end
end

return table.freeze(SimulateCast)
