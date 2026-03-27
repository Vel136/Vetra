--!native
--!optimize 2
--!strict

-- ─── ResolveHitscan ──────────────────────────────────────────────────────────
--[[
    Synchronous hitscan resolver.

    Hitscan casts skip all frame-by-frame physics (drag, Magnus, 6DOF,
    kinematics) and resolve the full hit chain — pierce, bounce, corner-trap,
    signal emission — in a single frame.

    StepProjectile calls ResolveHitscan.Execute(Solver, Cast) instead of
    SimulateCast.StepProjectile when Behavior.IsHitscan is true.

    Reuse:
        Pierce.ResolveChain       — full pierce loop, thickness checks, OnPierce
        BouncePhysics.*           — Reflect, ApplyRestitution, IsCornerTrap,
                                    RecordBounceState, GetMaterialMultiplier
        HookHelpers.*             — OnPreBounce, OnMidBounce, OnPreTermination
        FireHelpers.*             — OnTravel, OnBounce, OnHit, OnTerminated,
                                    OnSegmentOpen
        Kinematics.OpenFreshSegment — zero-acceleration segment per bounce so
                                    VetraNet can reconstruct the full path
]]

local Identity       = "ResolveHitscan"
local ResolveHitscan = {}
ResolveHitscan.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService    = require(Core.Logger)
local Enums         = require(Core.Enums)
local Constants     = require(Core.Constants)
local Visualizer    = require(Core.TrajectoryVisualizer)
local BouncePhysics = require(Physics.Bounce)
local PiercePhysics = require(Physics.Pierce)
local Kinematics    = require(Physics.Kinematics)
local FireHelpers   = require(Signals.FireHelpers)
local HookHelpers   = require(Signals.HookHelpers)

-- ─── Constants ───────────────────────────────────────────────────────────────

local TERMINATE_REASON    = Enums.TerminateReason
local VISUALIZER_HIT_TYPE = Constants.VISUALIZER_HIT_TYPE
local NUDGE               = Constants.NUDGE
local MIN_DOT_SQ          = Constants.MIN_DOT_SQ

local math_abs = math.abs
local cframe_new = CFrame.new

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Private Helpers ─────────────────────────────────────────────────────────

--[[
    Mirrors the HandleTermination logic in SimulateCast — fires OnPreTermination
    hook (with cancel/mutate support), then OnHit + OnTerminated, then Terminate.
]]
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
			FireHelpers.FireOnTerminated(Solver, Cast)
			Terminate(Solver, Cast, EffectiveReason)
		end
	else
		Cast.Runtime.TerminationCancelCounts[Reason] = nil
		FireHelpers.FireOnHit(Solver, Cast, HitResult, Velocity)
		FireHelpers.FireOnTerminated(Solver, Cast)
		Terminate(Solver, Cast, EffectiveReason)
	end
end

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Execute the full hitscan chain for a single cast.

    Loops synchronously: raycast → pierce (via Pierce.ResolveChain) →
    bounce (reflect + new raycast origin) → terminal hit or distance exhaust.
    All signals and hooks fire identically to the physics path.
]]
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

	-- Loop once per bounce budget (+ 1 for the initial ray).
	-- Each iteration raycasts from CurrentPosition in Direction.
	for _ = 1, Behavior.MaxBounces + 1 do
		local RemainingDistance = Behavior.MaxDistance - Runtime.DistanceCovered
		if RemainingDistance <= 0 then
			HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
			return
		end

		local RayVector     = Direction * RemainingDistance
		local RaycastResult = Behavior.CastFunction(CurrentPosition, RayVector, Behavior.RaycastParams)

		-- Accumulate distance: to the hit point, or to the end of the remaining range.
		local SegmentEnd: Vector3 = RaycastResult and RaycastResult.Position
			or (CurrentPosition + RayVector)
		local SegmentLength = (SegmentEnd - CurrentPosition).Magnitude
		Runtime.DistanceCovered += SegmentLength

		if Behavior.VisualizeCasts and SegmentLength > 0 then
			Visualizer.Segment(cframe_new(CurrentPosition, SegmentEnd), SegmentLength)
		end

		FireHelpers.FireOnTravel(Solver, Cast, SegmentEnd, CurrentVelocity)
		if not Cast.Alive then return end

		if RaycastResult then
			-- ── Pierce check ─────────────────────────────────────────────────
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

				-- Bullet exited all pierceable geometry — continue from exit point.
				CurrentPosition = (SolidResult and SolidResult.Position or SegmentEnd) + Direction * NUDGE
				-- Loop continues with updated position/direction.

			else
				-- ── Bounce check ─────────────────────────────────────────────
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
						FinalVelocity, EffectiveNormal, BaseRestitution, MaterialMultiplier, NormalPerturbation
					)

					local PostBounceOrigin = RaycastResult.Position + EffectiveNormal * NUDGE

					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(RaycastResult.Position), VISUALIZER_HIT_TYPE.Bounce)
						Visualizer.Normal(RaycastResult.Position, EffectiveNormal)
						Visualizer.Velocity(RaycastResult.Position, FinalVelocity)
					end

					-- Write a zero-acceleration trajectory segment so VetraNet can
					-- reconstruct the full path for server-side hit validation.
					local FreshSegment = Kinematics.OpenFreshSegment(Cast, PostBounceOrigin, FinalVelocity, Vector3.zero)
					FireHelpers.FireOnSegmentOpen(Solver, Cast, FreshSegment)

					if EffectiveNormal:Dot(EffectiveNormal) > MIN_DOT_SQ then
						BouncePhysics.RecordBounceState(Cast, EffectiveNormal, RaycastResult.Position, FinalVelocity)
					end

					if Behavior.ResetPierceOnBounce then
						Cast:ResetPierceState()
					end

					-- FireOnBounce increments BounceCount internally.
					FireHelpers.FireOnBounce(Solver, Cast, RaycastResult, FinalVelocity, PreBounceVelocity)
					if not Cast.Alive then return end

					-- MinSpeed check — bullet may have lost too much energy on bounce.
					local NewSpeed = FinalVelocity.Magnitude
					if NewSpeed < Behavior.MinSpeed then
						HandleTermination(Solver, Cast, TERMINATE_REASON.Speed, nil, FinalVelocity)
						return
					end

					CurrentVelocity = FinalVelocity
					CurrentSpeed    = NewSpeed
					Direction       = FinalVelocity.Unit
					CurrentPosition = PostBounceOrigin
					-- Loop continues with reflected direction.

				else
					-- Terminal hit — no valid pierce or bounce.
					if Behavior.VisualizeCasts then
						Visualizer.Hit(cframe_new(RaycastResult.Position), VISUALIZER_HIT_TYPE.Terminal)
					end
					HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, RaycastResult, CurrentVelocity)
					return
				end
			end

		else
			-- No geometry hit — MaxDistance exhausted on this segment.
			if Behavior.VisualizeCasts then
				Visualizer.Hit(cframe_new(SegmentEnd), VISUALIZER_HIT_TYPE.Terminal)
			end
			HandleTermination(Solver, Cast, TERMINATE_REASON.Distance, nil, CurrentVelocity)
			return
		end
	end

	-- MaxBounces budget exhausted without a terminal hit.
	HandleTermination(Solver, Cast, TERMINATE_REASON.Hit, nil, CurrentVelocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local ResolveHitscanMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("ResolveHitscan: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"ResolveHitscan: write to protected key '%s' = '%s'",
			tostring(Key), tostring(Value)
		))
	end,
})

return setmetatable(ResolveHitscan, ResolveHitscanMetatable)
