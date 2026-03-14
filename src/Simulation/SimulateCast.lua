--!native
--!optimize 2
--!strict

-- ─── SimulateCast ────────────────────────────────────────────────────────────
--[[
    Per-cast simulation step — raycast, pierce/bounce/hit resolution.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local Identity      = "SimulateCast"
local SimulateCast  = {}
SimulateCast.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals
local Simulation = script.Parent

-- ─── Module References ──────────────────────────────────────────────

-- Core Section
local LogService    = require(Core.Logger)
local Constants     = require(Core.Constants)
local t             = require(Core.TypeCheck)
local Visualizer    = require(Core.TrajectoryVisualizer)
-- Physics Section
local Magnus 		= require(Physics.Magnus)
local Kinematics    = require(Physics.Kinematics)
local BouncePhysics = require(Physics.Bounce)
local PiercePhysics = require(Physics.Pierce)
local DragPhysics   = require(Physics.Drag)
local HomingPhysics = require(Physics.Homing)
local Fragmentation = require(Physics.Fragmentation)
local CoriolisPhysics = require(Physics.Coriolis)  -- [CORIOLIS]
local PureGyroDrift = require(Physics.Pure.GyroDrift)
local TumblePhysics = require(Physics.Tumble)
local PureTumble    = require(Physics.Pure.Tumble)

-- Signals Section
local FireHelpers   = require(Signals.FireHelpers)
local HookHelpers   = require(Signals.HookHelpers)

-- ─── Constants ───────────────────────────────────────────────────────

local THRESHOLD_DIRECTION       = Constants.THRESHOLD_DIRECTION
local LOOK_AT_FALLBACK          = Constants.LOOK_AT_FALLBACK
local MIN_MAGNITUDE_SQ          = Constants.MIN_MAGNITUDE_SQ
local MIN_DOT_SQ                = Constants.MIN_DOT_SQ
local PROVIDER_VELOCITY_EPSILON = Constants.PROVIDER_VELOCITY_EPSILON
local VISUALIZER_HIT_TYPE       = Constants.VISUALIZER_HIT_TYPE
local TERMINATE_REASON          = Constants.TERMINATE_REASON

-- ─── Cached Globals ──────────────────────────────────────────────────

local cframe_new        = CFrame.new
local math_abs          = math.abs


-- Logging purposes
local Logger = LogService.new("Vetra.SimulateCast", true)

-- ─── Private Helpers ─────────────────────────────────────────────────────────

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
			-- Force-terminate: consumer has cancelled this specific reason three
			-- times in a row.  Reset only this reason's counter.
			Counts[Reason] = nil
			FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
			FireHelpers.FireOnTerminated(Solver, Cast)
			Terminate(Solver, Cast, EffectiveReason)
		end
	else
		-- Successful non-cancelled termination — clear this reason's counter.
		Cast.Runtime.TerminationCancelCounts[Reason] = nil
		FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
		FireHelpers.FireOnTerminated(Solver, Cast)
		Terminate(Solver, Cast, EffectiveReason)
	end
end

-- ─── Module ──────────────────────────────────────────────────────────────────

function SimulateCast.StepProjectile(Solver: any,Cast: any,Delta: number,IsSubSegment: boolean)
	local Terminate      = Solver._Terminate

	local Runtime          = Cast.Runtime
	local Behavior         = Cast.Behavior
	local ActiveTrajectory = Runtime.ActiveTrajectory

	local BaseAcceleration = Solver._BaseAccelerationCache[Cast]

	local ShouldRecalculate = DragPhysics.ShouldRecalculate(Runtime, Runtime.TotalRuntime, Behavior.DragSegmentInterval)

	-- ── Drag + Magnus combined recalc ────────────────────────────────────────
	-- Both forces are evaluated together each interval so neither can be
	-- accidentally omitted when the other is active. Wind and GyroDrift are
	-- applied once at the end, outside any per-force branch.
	local NeedsDrag   = Behavior.DragCoefficient > 0
	local NeedsMagnus = Magnus.IsActive(Behavior)

	if ShouldRecalculate and (NeedsDrag or NeedsMagnus) then
		if not BaseAcceleration then
			Logger:Warn("_BaseAccelerationCache miss — recalc skipped this frame to avoid compounding deceleration")
		else
			local Elapsed         = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CurrentVelocity = VelocityAtTime(Elapsed, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
			local CurrentOrigin   = PositionAtTime(Elapsed, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)

			local NewAcceleration = BaseAcceleration

			if NeedsDrag then
				local Coeff, Model = DragPhysics.GetEffectiveDragCoefficient(Cast)
				-- Scale coefficient by tumble multiplier (1.0 when not tumbling)
				local TumbleMult = TumblePhysics.GetDragMultiplier(Cast)
				NewAcceleration += DragPhysics.ComputeDragDeceleration(CurrentVelocity, Coeff * TumbleMult, Model, Behavior.CustomMachTable)
			end

			if NeedsMagnus then
				Magnus.StepSpinDecay(Behavior, Behavior.DragSegmentInterval)
				NewAcceleration += Magnus.ComputeForce(Behavior.SpinVector, CurrentVelocity, Behavior.MagnusCoefficient)
			end

			local WindEffect = (Solver._Wind and Solver._Wind:Dot(Solver._Wind) > 0)
				and (Solver._Wind * Behavior.WindResponse) or Constants.ZERO_VECTOR
			NewAcceleration += WindEffect

			if Behavior.GyroDriftRate then
				NewAcceleration += PureGyroDrift.ComputeForce(CurrentVelocity, Behavior.GyroDriftRate, Behavior.GyroDriftAxis)
			end

			-- Tumble lateral force — seeded PRNG advances once per interval
			if Runtime.IsTumbling then
				NewAcceleration += TumblePhysics.StepLateralForce(Cast, CurrentVelocity)
			end

			Kinematics.OpenFreshSegment(Cast, CurrentOrigin, CurrentVelocity, NewAcceleration)
			ActiveTrajectory = Runtime.ActiveTrajectory
			Runtime.LastDragRecalculateTime = Runtime.TotalRuntime
		end
	end

	local ElapsedBeforeAdvance = Runtime.TotalRuntime - ActiveTrajectory.StartTime
	local PreviouslySupersonic = Runtime.IsSupersonic

	Runtime.TotalRuntime      += Delta
	local ElapsedAfterAdvance  = Runtime.TotalRuntime - ActiveTrajectory.StartTime

	local LastPosition, CurrentTargetPosition, CurrentVelocity

	local Provider			   = Behavior.TrajectoryPositionProvider
	if Provider then
		local HasHanging = IsThreadHanging(Runtime.TrajectoryProviderThread)
		if not IsSubSegment and HasHanging then
			Logger:Warn(" TrajectoryPositionProvider yielded — falling back to kinematic this frame")
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
			Logger:Warn("TrajectoryPositionProvider returned non-Vector3 for last position — falling back to kinematic")
			LastPosition = PositionAtTime(ElapsedBeforeAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		end

		Runtime.TrajectoryProviderThread = coroutine.running()
		local ProvidedCurrent = Provider(ElapsedCurrent)
		Runtime.TrajectoryProviderThread = nil


		if t.Vector3(ProvidedCurrent) then
			CurrentTargetPosition = ProvidedCurrent
		else	
			Logger:Warn("TrajectoryPositionProvider returned non-Vector3 for current position — falling back to kinematic")
			CurrentTargetPosition = PositionAtTime(ElapsedAfterAdvance, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
		end

		Runtime.TrajectoryProviderThread = coroutine.running()
		local ProvidedForward = Provider(ElapsedCurrent + PROVIDER_VELOCITY_EPSILON)
		Runtime.TrajectoryProviderThread = nil
		if t.Vector3(ProvidedForward) then
			CurrentVelocity = (ProvidedForward - CurrentTargetPosition) / PROVIDER_VELOCITY_EPSILON
		else
			Logger:Warn("TrajectoryPositionProvider returned non-Vector3 for velocity probe — using kinematic velocity")
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

	-- ── Coriolis deflection ───────────────────────────────────────────────────
	-- Applied after homing (which may have replaced CurrentVelocity) but before
	-- the raycast direction is computed from FrameDisplacement.
	--
	-- We nudge CurrentVelocity directly rather than baking into the trajectory's
	-- stored Acceleration, because Coriolis is velocity-dependent (a = -2*(Ω×v))
	-- and must be recomputed every step as v changes. Baking it once would
	-- permanently apply the step-0 deflection direction to all future steps,
	-- which is physically wrong and accumulates error rapidly.
	--
	-- The dot-product guard is a fast-exit when CoriolisOmega is zero (i.e.
	-- Coriolis is disabled). It avoids the cross product entirely and costs
	-- only a single multiply + compare on the common code path.
	local CoriolisOmega = Solver._CoriolisOmega
	if CoriolisOmega and CoriolisOmega:Dot(CoriolisOmega) > 0 then
		local CoriolisAccel   = CoriolisPhysics.ComputeAcceleration(CoriolisOmega, CurrentVelocity)
		CurrentVelocity       = CurrentVelocity + CoriolisAccel * Delta
		-- Recompute CurrentTargetPosition so the raycast direction agrees
		-- with the Coriolis-deflected velocity.
		CurrentTargetPosition = LastPosition + CurrentVelocity * Delta
	end

	local CurrentSpeed         = CurrentVelocity.Magnitude
	local FrameDisplacement    = CurrentTargetPosition - LastPosition

	StepSpeedProfiles(Solver, Cast, CurrentSpeed)
	StepSonicTransition(Solver, Cast, CurrentSpeed, PreviouslySupersonic)

	-- Tumble speed trigger — fires OnTumbleBegin exactly once per tumble onset.
	-- Recovery check — fires OnTumbleEnd if speed climbs back above TumbleRecoverySpeed.
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

	-- ── CastFunction yield guard ──────────────────────────────────────────────
	if IsThreadHanging(Runtime.CastFunctionThread) then
		Runtime.CastFunctionThread = nil
		Terminate(Solver, Cast, TERMINATE_REASON.Manual)
		Logger:Error("CastFunction yielded — cast terminated")
		return
	end

	Runtime.CastFunctionThread = coroutine.running()
	local RaycastResult = Behavior.CastFunction(LastPosition, RayDirection, Behavior.RaycastParams)
	Runtime.CastFunctionThread = nil

	local BulletHitPoint          = RaycastResult and RaycastResult.Position or CurrentTargetPosition
	local FrameRayDisplacement    = (BulletHitPoint - LastPosition).Magnitude

	Runtime.DistanceCovered += FrameRayDisplacement
	FireHelpers.FireOnTravel(Solver, Cast, BulletHitPoint, CurrentVelocity)

	if Runtime.CosmeticBulletObject then
		local LookAtPoint = BulletHitPoint + (CurrentVelocity:Dot(CurrentVelocity) > MIN_DOT_SQ and CurrentVelocity.Unit or LOOK_AT_FALLBACK)
		Runtime.CosmeticBulletObject.CFrame = cframe_new(BulletHitPoint, LookAtPoint)
	end

	if Behavior.VisualizeCasts and Delta > 0 then
		Visualizer.Segment(cframe_new(LastPosition, LastPosition + RayDirection), FrameRayDisplacement)
	end

	local IsHitOnCosmetic = RaycastResult and RaycastResult.Instance == Runtime.CosmeticBulletObject
	local IsValidHit      = RaycastResult ~= nil and not IsHitOnCosmetic

	if IsValidHit then
		local LinkedBulletContext = Solver._CastToBulletContext[Cast]
		local CanPierceCallback   = Behavior.CanPierceFunction


		local HasHangingPierce = IsThreadHanging(Runtime.PierceCallbackThread)
		if not IsSubSegment and CanPierceCallback and HasHangingPierce then
			Terminate(Solver, Cast, TERMINATE_REASON.Manual)
			Logger:Error("CanPierceFunction yielded")
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

		-- Pierce tumble trigger — TumbleOnPierce begins tumble regardless of speed.
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
				Logger:Error("CanBounceFunction yielded")
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

					FinalVelocity = BouncePhysics.ApplyRestitution(FinalVelocity, BaseRestitution, MaterialMultiplier, NormalPerturbationAmount)

					local PostBounceOrigin = RaycastResult.Position + EffectiveNormal * Constants.NUDGE

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

					FireHelpers.FireOnBounce(Solver, Cast, RaycastResult, FinalVelocity, PreBounceVelocity)
					return
				else
					if Behavior.VisualizeCasts then
						Visualizer.CornerTrap(RaycastResult.Position)
					end
				end
			end

			-- Terminal hit (no valid pierce or bounce)
			HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, RaycastResult, CurrentVelocity)
			return
		end
	end

	-- Distance termination
	if Runtime.DistanceCovered >= Behavior.MaxDistance then
		if Behavior.VisualizeCasts then
			Visualizer.Hit(cframe_new(CurrentTargetPosition), VISUALIZER_HIT_TYPE.Terminal)
		end
		HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
		return
	end

	-- Speed termination
	if CurrentSpeed < Behavior.MinSpeed or CurrentSpeed > Behavior.MaxSpeed then
		HandleTermination(Solver, Cast, TERMINATE_REASON.Speed, nil, CurrentVelocity)
		return
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local SimulateCastMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("SimulateCast: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"SimulateCast: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(SimulateCast, SimulateCastMetatable)