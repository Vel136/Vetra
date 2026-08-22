--!native
--!optimize 2
--!strict

local ResolveHitscan = {}

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals

local Enums         = require(Core.Enums)
local Constants     = require(Core.Constants)
local Visualizer    = require(Core.TrajectoryVisualizer)
local BouncePhysics = require(Physics.Bounce)
local PiercePhysics = require(Physics.Pierce)
local Kinematics    = require(Physics.Kinematics)
local FireHelpers   = require(Signals.FireHelpers)
local HookHelpers   = require(Signals.HookHelpers)

local TERMINATE_REASON    = Enums.TerminateReason
local VISUALIZER_HIT_TYPE = Constants.VISUALIZER_HIT_TYPE
local NUDGE               = Constants.NUDGE
local MIN_DOT_SQ          = Constants.MIN_DOT_SQ

local math_abs   = math.abs
local cframe_new = CFrame.new

local function HandleTermination(
	Solver    : any,
	Cast      : any,
	Reason    : string,
	HitResult : RaycastResult?,
	Velocity  : Vector3
)
	local Terminate = Solver._Terminate

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

function ResolveHitscan.Execute(Solver: any, Cast: any)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local ActiveTrajectory = Runtime.ActiveTrajectory
	local CurrentVelocity  = ActiveTrajectory.InitialVelocity
	local CurrentSpeed     = CurrentVelocity.Magnitude

	if CurrentSpeed < 1e-6 then
		HandleTermination(Solver, Cast, TERMINATE_REASON.Speed, nil, CurrentVelocity)
		return
	end

	local CurrentPosition = ActiveTrajectory.Origin
	local Direction       = CurrentVelocity.Unit

	for _ = 1, Behavior.MaxBounces + 1 do
		local RemainingDistance = Behavior.MaxDistance - Runtime.DistanceCovered
		if RemainingDistance <= 0 then
			HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
			return
		end

		local RayVector     = Direction * RemainingDistance
		local RaycastResult = Behavior.CastFunction(CurrentPosition, RayVector, Behavior.RaycastParams)

		local SegmentEnd: Vector3 = RaycastResult and RaycastResult.Position
			or (CurrentPosition + RayVector)
		local SegmentLength = (SegmentEnd - CurrentPosition).Magnitude
		Runtime.DistanceCovered += SegmentLength

		if Behavior.VisualizeCasts and SegmentLength > 0 then
			Visualizer.Segment(cframe_new(CurrentPosition, SegmentEnd), SegmentLength)
		end

		FireHelpers.FireOnTravel(Solver, Cast, SegmentEnd, CurrentVelocity)
		if not Cast.Alive then return end

		local MaxDisplacement = Behavior.MaxDisplacement
		if MaxDisplacement > 0 and (SegmentEnd - Runtime.SpawnOrigin).Magnitude >= MaxDisplacement then
			if Behavior.VisualizeCasts then
				Visualizer.Hit(cframe_new(SegmentEnd), VISUALIZER_HIT_TYPE.Terminal)
			end
			HandleTermination(Solver, Cast, TERMINATE_REASON.Displacement, nil, CurrentVelocity)
			return
		end

		if RaycastResult then
			local ImpactDot          = math_abs(Direction:Dot(RaycastResult.Normal))
			local IsAbovePierceSpeed = CurrentSpeed >= Behavior.PierceSpeedThreshold
			local IsBelowMaxPierce   = Runtime.PierceCount < Behavior.MaxPierceCount
			local MeetsNormalBias    = ImpactDot >= (1.0 - Behavior.PierceNormalBias)
			local EligibleForPierce  = IsAbovePierceSpeed and IsBelowMaxPierce and MeetsNormalBias

			local CanPierceCallback = Behavior.CanPierceFunction
			local LinkedContext     = Solver._CastToBulletContext[Cast]
			local CanPierce         = CanPierceCallback and CanPierceCallback(LinkedContext, RaycastResult, CurrentVelocity)

			if CanPierce and EligibleForPierce then
				local FoundSolid, SolidResult, PostVelocity = PiercePhysics.ResolveChain(
					Solver, Cast, RaycastResult, Direction, CurrentVelocity
				)

				if not Cast.Alive then return end

				CurrentVelocity = PostVelocity
				CurrentSpeed    = CurrentVelocity.Magnitude
				Direction       = if CurrentSpeed > 1e-6 then CurrentVelocity.Unit else Direction

				if FoundSolid and SolidResult then
					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(SolidResult.Position), VISUALIZER_HIT_TYPE.Terminal)
					end
					HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, SolidResult, CurrentVelocity)
					return
				end

				CurrentPosition = (SolidResult and SolidResult.Position or SegmentEnd) + Direction * NUDGE

			else
				local IsAboveBounceSpeed = CurrentSpeed >= Behavior.BounceSpeedThreshold
				local IsBelowMaxBounce   = Runtime.BounceCount < Behavior.MaxBounces
				local EligibleForBounce  = IsAboveBounceSpeed and IsBelowMaxBounce

				local CanBounceCallback = Behavior.CanBounceFunction
				LinkedContext           = Solver._CastToBulletContext[Cast]
				local CanBounce         = CanBounceCallback and CanBounceCallback(LinkedContext, RaycastResult, CurrentVelocity)

				if CanBounce and EligibleForBounce then
					local EffectiveNormal, EffectiveIncomingVelocity = HookHelpers.FireOnPreBounce(
						Solver, Cast, RaycastResult, CurrentVelocity
					)

					local IsCornerTrapped = BouncePhysics.IsCornerTrap(Cast, EffectiveNormal, RaycastResult.Position)
					if IsCornerTrapped then
						if Behavior.VisualizeCasts then
							Visualizer.CornerTrap(RaycastResult.Position)
						end
						HandleTermination(Solver, Cast, TERMINATE_REASON.CornerTrap, RaycastResult, CurrentVelocity)
						return
					end

					local PreBounceVelocity = EffectiveIncomingVelocity
					local ReflectedVelocity = BouncePhysics.Reflect(EffectiveIncomingVelocity, EffectiveNormal)
					local FinalVelocity, BaseRestitution, NormalPerturbation = HookHelpers.FireOnMidBounce(
						Solver, Cast, RaycastResult, ReflectedVelocity
					)

					local MaterialMultiplier = BouncePhysics.GetMaterialMultiplier(Cast, RaycastResult.Material)
					FinalVelocity = BouncePhysics.ApplyRestitution(
						Cast, FinalVelocity, EffectiveNormal, BaseRestitution, MaterialMultiplier, NormalPerturbation
					)

					local PostBounceOrigin = RaycastResult.Position + EffectiveNormal * NUDGE

					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(RaycastResult.Position), VISUALIZER_HIT_TYPE.Bounce)
						Visualizer.Normal(RaycastResult.Position, EffectiveNormal)
						Visualizer.Velocity(RaycastResult.Position, FinalVelocity)
					end

					local FreshSegment = Kinematics.OpenFreshSegment(Cast, PostBounceOrigin, FinalVelocity, Vector3.zero)
					FireHelpers.FireOnSegmentOpen(Solver, Cast, FreshSegment)

					if EffectiveNormal:Dot(EffectiveNormal) > MIN_DOT_SQ then
						BouncePhysics.RecordBounceState(Cast, EffectiveNormal, RaycastResult.Position, FinalVelocity)
					end

					if Behavior.ResetPierceOnBounce then
						Cast:ResetPierceState()
					end

					FireHelpers.FireOnBounce(Solver, Cast, RaycastResult, FinalVelocity, PreBounceVelocity)
					if not Cast.Alive then return end

					local NewSpeed = FinalVelocity.Magnitude
					if NewSpeed < Behavior.MinSpeed then
						HandleTermination(Solver, Cast, TERMINATE_REASON.Speed, nil, FinalVelocity)
						return
					end

					CurrentVelocity = FinalVelocity
					CurrentSpeed    = NewSpeed
					Direction       = FinalVelocity.Unit
					CurrentPosition = PostBounceOrigin

				else
					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(RaycastResult.Position), VISUALIZER_HIT_TYPE.Terminal)
					end
					HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, RaycastResult, CurrentVelocity)
					return
				end
			end

		else
			if Behavior.VisualizeCasts then
				Visualizer.Hit(cframe_new(SegmentEnd), VISUALIZER_HIT_TYPE.Terminal)
			end
			HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
			return
		end
	end

	HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, nil, CurrentVelocity)
end

return table.freeze(ResolveHitscan)
