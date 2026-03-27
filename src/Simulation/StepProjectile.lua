--!native
--!optimize 2
--!strict

-- ─── StepProjectile ──────────────────────────────────────────────────────────
--[[
    Frame driver — iterates active casts, dispatches high-fidelity or standard step.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local Identity       = "StepProjectile"
local StepProjectile = {}
StepProjectile.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Physics    = Vetra.Physics
local Signals    = Vetra.Signals
local Simulation = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Constants		         = require(Core.Constants)
local LogService             = require(Core.Logger)
local t	 					 = require(Core.TypeCheck)
local SimulateCast           = require(Simulation.SimulateCast)
local ResimulateHighFidelity = require(Simulation.ResimulateHighFidelity)
local FrameBudget            = require(Simulation.FrameBudget)
local SpatialPartition       = require(Simulation.SpatialPartition)

local FireHelpers            = require(Signals.FireHelpers)
local Kinematics             = require(Physics.Kinematics)
-- ─── Cached Globals ──────────────────────────────────────────────────────────

local PositionAtTime    = Kinematics.PositionAtTime

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local function IsThreadHanging(Thread: thread?): boolean
	return Thread ~= nil and Thread ~= coroutine.running()
end

-- ─── Module ──────────────────────────────────────────────────────────────────

function StepProjectile.StepProjectile(Solver: any, FrameDelta: number)
	FrameBudget.Reset(Solver._FrameBudget)

	-- ── Spatial partition grid rebuild ───────────────────────────────────────
	-- Rebuild every UpdateInterval frames. Done once per Step call, not per
	-- cast, so the cost is amortized across all active casts.
	local SpatialConfig  = Solver._SpatialConfig
	local SpatialEnabled = SpatialConfig and SpatialConfig.Enabled
	if SpatialEnabled then
		Solver._SpatialFrameCounter += 1
		if Solver._SpatialFrameCounter >= SpatialConfig.UpdateInterval then
			Solver._SpatialFrameCounter = 0
			SpatialPartition.Rebuild(Solver)
		end
	end

	local ActiveCasts = Solver._ActiveCasts
	local ActiveCount = #ActiveCasts
	local LODOrigin   = Solver._LODOrigin

	-- Iterate backwards so that CastRegistry's swap-remove (which moves the
	-- last element into the terminated cast's slot) never skips a cast.
	for CastIndex = ActiveCount, 1, -1 do
		local Cast = ActiveCasts[CastIndex]
		if not Cast or not Cast.Alive then continue end
		if Cast.Paused then continue end

		local Runtime  = Cast.Runtime
		local Behavior = Cast.Behavior

		Runtime.BouncesThisFrame = 0

		-- ── LOD check ────────────────────────────────────────────────────────
		-- LOD is evaluated first and takes full priority over spatial tier.
		-- A cast that is IsLOD will never reach the spatial branch below.
		if Behavior.LODDistance > 0 and LODOrigin then
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local ElapsedTime      = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CastPosition     = PositionAtTime(ElapsedTime, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration)
			local DistanceToOrigin = (CastPosition - LODOrigin).Magnitude
			local ShouldLOD        = DistanceToOrigin > Behavior.LODDistance
			if ShouldLOD ~= Runtime.IsLOD then
				Runtime.IsLOD               = ShouldLOD
				Runtime.LODFrameAccumulator = 0
				Runtime.LODDeltaAccumulator = 0
				-- Also reset spatial accumulator when LOD state changes so the
				-- cast does not carry stale skipped-frame debt into either mode.
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			end
		end

		-- ── Spatial tier skip ────────────────────────────────────────────────
		-- Only checked when spatial partition is enabled AND the cast is not
		-- already handled by LOD. LOD is more aggressive (skip 2 of 3 frames)
		-- so there is no benefit in layering spatial on top of it.
		local StepDelta = FrameDelta
		if SpatialEnabled and not Runtime.IsLOD then
			local ActiveTrajectory  = Runtime.ActiveTrajectory
			local ElapsedTime       = Runtime.TotalRuntime - ActiveTrajectory.StartTime
			local CastPosition      = PositionAtTime(
				ElapsedTime,
				ActiveTrajectory.Origin,
				ActiveTrajectory.InitialVelocity,
				ActiveTrajectory.Acceleration
			)
			local Tier = SpatialPartition.GetTier(Solver, CastPosition)

			if Tier > Constants.SPATIAL_TIERS.HOT then
				-- Cast is WARM or COLD — accumulate and possibly skip this frame.
				Runtime.SpatialFrameAccumulator = (Runtime.SpatialFrameAccumulator or 0) + 1
				Runtime.SpatialDeltaAccumulator = (Runtime.SpatialDeltaAccumulator or 0) + FrameDelta

				if Runtime.SpatialFrameAccumulator < Tier then
					-- Not enough frames accumulated yet — skip this cast entirely.
					continue
				end

				-- Tier threshold reached — step with the true accumulated delta
				-- rather than the current FrameDelta alone. This mirrors the LOD
				-- using only the current frame's delta would under-
				-- simulate by the skipped frames' elapsed time.
				StepDelta                       = Runtime.SpatialDeltaAccumulator
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			else
				-- HOT tier — reset accumulators so a previous WARM period does
				-- not leave stale counts that trigger an early double-step.
				Runtime.SpatialFrameAccumulator = 0
				Runtime.SpatialDeltaAccumulator = 0
			end
		end

		local UseHighFidelity = Behavior.HighFidelitySegmentSize > 0 and Runtime.CurrentSegmentSize > 0 and not Runtime.IsLOD

		if UseHighFidelity then
			local ActiveTrajectory = Runtime.ActiveTrajectory
			local Provider         = Behavior.TrajectoryPositionProvider
			local PositionAtStart, PositionAtEnd

			if Provider then
				-- Guard against a provider that yielded on a previous probe and
				-- never returned. Nil it out and fall back to kinematic this frame.
				if IsThreadHanging(Runtime.TrajectoryProviderThread) then
					Runtime.TrajectoryProviderThread = nil
					Logger:Warn("TrajectoryPositionProvider yielded during probe — falling back to kinematic")
					Provider = nil
				end
			end

			if Provider then
				Runtime.TrajectoryProviderThread = coroutine.running()
				PositionAtStart = Provider(Runtime.TotalRuntime)
				Runtime.TotalRuntime += StepDelta
				
				PositionAtEnd   = Provider(Runtime.TotalRuntime)
				Runtime.TotalRuntime -= StepDelta
				Runtime.TrajectoryProviderThread = nil
				
				-- Fallback to kinematic if provider returns invalid values
				if not PositionAtStart or not PositionAtEnd or not t.Vector3(PositionAtStart) or not t.Vector3(PositionAtEnd)  then
					Logger:Warn("StepProjectile: TrajectoryPositionProvider returned invalid value during probe — falling back to kinematic")
					Provider = nil
				end
			end

			if not Provider then
				local ElapsedAtStart = Runtime.TotalRuntime - ActiveTrajectory.StartTime
				PositionAtStart = PositionAtTime(
					ElapsedAtStart, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
				)
				Runtime.TotalRuntime += StepDelta
				local ElapsedAtEnd = Runtime.TotalRuntime - ActiveTrajectory.StartTime
				PositionAtEnd = PositionAtTime(
					ElapsedAtEnd, ActiveTrajectory.Origin, ActiveTrajectory.InitialVelocity, ActiveTrajectory.Acceleration
				)
				Runtime.TotalRuntime -= StepDelta
			end

			local TotalFrameDisplacement = (PositionAtEnd - PositionAtStart).Magnitude

			ResimulateHighFidelity.Execute(Solver, Cast, StepDelta, TotalFrameDisplacement)

			Cast.Runtime.CancelResimulation = false
		elseif Runtime.IsLOD then
			Runtime.LODFrameAccumulator += 1
			Runtime.LODDeltaAccumulator  = (Runtime.LODDeltaAccumulator or 0) + StepDelta

			if Runtime.LODFrameAccumulator >= 3 then
				local AccumulatedDelta      = Runtime.LODDeltaAccumulator
				Runtime.LODFrameAccumulator = 0
				Runtime.LODDeltaAccumulator = 0
				SimulateCast.StepProjectile(Solver, Cast, AccumulatedDelta, false)
			end
		else
			SimulateCast.StepProjectile(Solver, Cast, StepDelta, false)
		end
	end

	-- Flush batch travel
	if #Solver._TravelBatch > 0 then
		FireHelpers.FlushTravelBatch(Solver)
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local StepMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("StepProjectile: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"StepProjectile: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(StepProjectile, StepMetatable)