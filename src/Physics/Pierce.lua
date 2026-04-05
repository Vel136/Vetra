--!native
--!optimize 2
--!strict

-- ─── Pierce ──────────────────────────────────────────────────────────────────
--[[
    Pierce chain resolution — filter mutation and per-instance tracking.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local Identity = "Pierce"
local Pierce   = {}
Pierce.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent
local Core    = Vetra.Core
local Signals = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService          = require(Core.Logger)
local Constants           = require(Core.Constants)
local t                   = require(Core.TypeCheck)
local RaycastParamsPooler = require(Core.RaycastParamsPooler)
local Visualizer    	  = require(Core.TrajectoryVisualizer)

local HookHelpers         = require(Signals.HookHelpers)
local FireHelpers		  =	require(Signals.FireHelpers)
-- Logging
local Logger = LogService.new(Identity, false)


-- Params Pooling
local ThicknessParamsPool = RaycastParamsPooler.new({ MinSize = 4, MaxSize = 32 })

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_floor = math.floor
local math_sqrt  = math.sqrt

local MIN_MAGNITUDE_SQ      = Constants.MIN_MAGNITUDE_SQ
local PIERCE_MAX_ITERATIONS = Constants.PIERCE_MAX_ITERATIONS
local NUDGE                 = Constants.NUDGE
local VISUALIZER_HIT_TYPE   = Constants.VISUALIZER_HIT_TYPE


-- ─── Pierce Thickness Measurement ────────────────────────────────────────────

local function MeasureThickness(EntryPosition: Vector3, RayDirection: Vector3, HitInstance: Instance, ThicknessLimit: number): number
	if RayDirection:Dot(RayDirection) < MIN_MAGNITUDE_SQ then return 0 end

	local ExitParams = ThicknessParamsPool:Acquire()
	ExitParams.FilterType = Enum.RaycastFilterType.Include
	ExitParams.FilterDescendantsInstances = { HitInstance }

	-- Shoot from far ahead BACKWARD toward entry point
	-- Ray starts outside the part → can detect the exit face
	local FarOrigin   = EntryPosition + RayDirection.Unit * ThicknessLimit
	local BackwardDir = -RayDirection.Unit * ThicknessLimit
	local ExitResult  = workspace:Raycast(FarOrigin, BackwardDir, ExitParams)

	ThicknessParamsPool:Release(ExitParams)
	if not ExitResult then return 0 end

	local Thickness = (ExitResult.Position - EntryPosition).Magnitude
	return Thickness
end

-- ─── Module ──────────────────────────────────────────────────────────────────


function Pierce.MutateFilter(RayParams: RaycastParams, Instance: Instance)
	local IsExclude     = RayParams.FilterType == Enum.RaycastFilterType.Exclude
	local CurrentFilter = RayParams.FilterDescendantsInstances

	if IsExclude then
		CurrentFilter[#CurrentFilter + 1] = Instance
	else
		-- For Include-type filters the table usually holds ancestor containers
		-- (e.g. a character Model), not individual BaseParts. A direct
		-- table.find for the BasePart finds nothing and silently leaves the
		-- filter unchanged, allowing the same part to be re-hit on every
		-- sub-segment. Walk up the ancestor chain to find the registered entry.
		local Candidate  = Instance :: Instance?
		local FoundIndex = nil
		while Candidate do
			FoundIndex = table.find(CurrentFilter, Candidate)
			if FoundIndex then break end
			Candidate = Candidate.Parent
		end
		if FoundIndex then
			CurrentFilter[FoundIndex]     = CurrentFilter[#CurrentFilter]
			CurrentFilter[#CurrentFilter] = nil
		end
	end

	RayParams.FilterDescendantsInstances = CurrentFilter
end

function Pierce.ResolveChain(
	Solver          : any,
	Cast            : any,
	InitialResult   : RaycastResult,
	RayDirection    : Vector3,
	CurrentVelocity : Vector3
): (boolean, RaycastResult?, Vector3)

	if RayDirection:Dot(RayDirection) < MIN_MAGNITUDE_SQ then
		Logger:Warn("ResolveChain: degenerate RayDirection")
		return false, nil, CurrentVelocity
	end

	local Runtime           = Cast.Runtime
	local Behavior          = Cast.Behavior
	local RayParams         = Behavior.RaycastParams
	local CanPierceCallback = Behavior.CanPierceFunction

	local EntryVelocity, MaxPierceOverride = HookHelpers.FireOnPrePierce(Solver, Cast, InitialResult, CurrentVelocity)

	if EntryVelocity then CurrentVelocity = EntryVelocity end

	local EffectiveMaxPierce = MaxPierceOverride or Behavior.MaxPierceCount

	local IterationCount = 0
	local CurrentResult  = InitialResult
	local FoundSolid     = false

	while true do
		if CurrentVelocity.Magnitude < Behavior.PierceSpeedThreshold then break end

		local PiercedInstance = CurrentResult.Instance
		local PiercedList     = Runtime.PiercedInstances
		PiercedList[#PiercedList + 1] = PiercedInstance

		Pierce.MutateFilter(RayParams, PiercedInstance)

		-- ── PierceDepth / PierceForce checks ───────────────────────
		-- Both checks require the material thickness, so we measure it once and
		-- share the result between both guards to avoid a redundant raycast.
		local PierceDepth = Behavior.PierceDepth
		local PierceForce = Behavior.PierceForce
		local NeedThickness    = (PierceDepth and PierceDepth > 0) or (PierceForce and PierceForce > 0)


		if NeedThickness then
			local Thickness = MeasureThickness(CurrentResult.Position, RayDirection, PiercedInstance, Behavior.PierceThicknessLimit)
			-- PierceDepth: if material is thicker than the limit, stop inside.
			if PierceDepth and PierceDepth > 0 and Thickness > PierceDepth then
				FoundSolid = true
				break
			end

			-- PierceForce: deduct thickness from the remaining energy budget.
			-- If the budget is exhausted, stop inside the material.
			if PierceForce and PierceForce > 0 then
				Runtime.PierceForceRemaining = (Runtime.PierceForceRemaining or PierceForce) - Thickness
				if Runtime.PierceForceRemaining <= 0 then
					FoundSolid = true
					break
				end
			end
		end

		local SpeedRetention, ExitVelocity = HookHelpers.FireOnMidPierce(Solver, Cast, CurrentResult, CurrentVelocity)

		-- An OnMidPierce handler may call BulletContext:Terminate(), which
		-- unlinks the context. Without this guard the loop would continue firing
		-- sub-raycasts and calling user callbacks (with a nil context) for up to
		-- 100 iterations on a cast that is already dead.
		if not Cast.Alive then break end

		if ExitVelocity then
			CurrentVelocity = ExitVelocity
		else
			CurrentVelocity = CurrentVelocity.Unit * (CurrentVelocity.Magnitude * SpeedRetention)
		end
		FireHelpers.FireOnPierce(Solver, Cast, CurrentResult, CurrentVelocity)

		if Behavior.VisualizeCasts then
			Visualizer.Hit(CFrame.new(CurrentResult.Position), VISUALIZER_HIT_TYPE.Pierce)
			Visualizer.Normal(CurrentResult.Position, CurrentResult.Normal)
		end

		if Runtime.PierceCount >= EffectiveMaxPierce then break end

		local NextRayOrigin = CurrentResult.Position + RayDirection.Unit * Constants.NUDGE
		local NextResult    = Behavior.CastFunction(NextRayOrigin, RayDirection, RayParams)

		if NextResult == nil then break end

		IterationCount += 1
		if IterationCount >= PIERCE_MAX_ITERATIONS then
			Logger:Warn("ResolveChain: exceeded 100 iterations")
			break
		end

		local LinkedBulletContext = Solver._CastToBulletContext and Solver._CastToBulletContext[Cast]
		local CanPierce           = CanPierceCallback and CanPierceCallback(LinkedBulletContext, NextResult, CurrentVelocity)

		if not CanPierce then
			FoundSolid    = true
			CurrentResult = NextResult
			break
		end

		CurrentResult = NextResult
	end

	return FoundSolid, CurrentResult, CurrentVelocity
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local PierceMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Pierce: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Pierce: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Pierce, PierceMetatable)