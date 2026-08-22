--!strict
--!optimize 2
--!native

local Pierce   = {}

local Vetra   = script.Parent.Parent
local Core    = Vetra.Core
local Signals = Vetra.Signals

local Constants           = require(Core.Constants)
local t                   = require(Core.TypeCheck)
local RaycastParamsPooler = require(Core.RaycastParamsPooler)
local Visualizer          = require(Core.TrajectoryVisualizer)
local HookHelpers         = require(Signals.HookHelpers)
local FireHelpers          = require(Signals.FireHelpers)

local ThicknessParamsPool = RaycastParamsPooler.new({ MinSize = 4, MaxSize = 32 })

local math_floor = math.floor
local math_sqrt  = math.sqrt

local MIN_MAGNITUDE_SQ      = Constants.MIN_MAGNITUDE_SQ
local PIERCE_MAX_ITERATIONS = Constants.PIERCE_MAX_ITERATIONS
local NUDGE                 = Constants.NUDGE
local VISUALIZER_HIT_TYPE   = Constants.VISUALIZER_HIT_TYPE

local function MeasureThickness(EntryPosition: Vector3, RayDirection: Vector3, HitInstance: Instance, ThicknessLimit: number): number
	if RayDirection:Dot(RayDirection) < MIN_MAGNITUDE_SQ then return 0 end

	local ExitParams = ThicknessParamsPool:Acquire()
	ExitParams.FilterType = Enum.RaycastFilterType.Include
	ExitParams.FilterDescendantsInstances = { HitInstance }

	local FarOrigin   = EntryPosition + RayDirection.Unit * ThicknessLimit
	local BackwardDir = -RayDirection.Unit * ThicknessLimit
	local ExitResult  = workspace:Raycast(FarOrigin, BackwardDir, ExitParams)

	ThicknessParamsPool:Release(ExitParams)
	if not ExitResult then return 0 end

	local Thickness = (ExitResult.Position - EntryPosition).Magnitude
	return Thickness
end

function Pierce.MutateFilter(RayParams: RaycastParams, Instance: Instance)
	local IncludeList = RayParams.IncludeInstances
	local ExcludeList = RayParams.ExcludeInstances
	local IsExclude, CurrentFilter, Kind
	if IncludeList ~= nil then
		IsExclude, CurrentFilter, Kind = false, IncludeList, 1
	elseif ExcludeList ~= nil then
		IsExclude, CurrentFilter, Kind = true, ExcludeList, 2
	else
		IsExclude     = RayParams.FilterType == Enum.RaycastFilterType.Exclude
		CurrentFilter = RayParams.FilterDescendantsInstances
		Kind          = 0
	end

	if IsExclude then
		CurrentFilter[#CurrentFilter + 1] = Instance
	else
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

	if Kind == 1 then
		RayParams.IncludeInstances = CurrentFilter
	elseif Kind == 2 then
		RayParams.ExcludeInstances = CurrentFilter
	else
		RayParams.FilterDescendantsInstances = CurrentFilter
	end
end

function Pierce.ResolveChain(
	Solver          : any,
	Cast            : any,
	InitialResult   : RaycastResult,
	RayDirection    : Vector3,
	CurrentVelocity : Vector3
): (boolean, RaycastResult?, Vector3)

	if RayDirection:Dot(RayDirection) < MIN_MAGNITUDE_SQ then
		warn("Pierce.ResolveChain: degenerate RayDirection")
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

		local PierceDepth = Behavior.PierceDepth
		local PierceForce = Behavior.PierceForce
		local NeedThickness = (PierceDepth and PierceDepth > 0) or (PierceForce and PierceForce > 0)

		if NeedThickness then
			local Thickness = MeasureThickness(CurrentResult.Position, RayDirection, PiercedInstance, Behavior.PierceThicknessLimit)
			if PierceDepth and PierceDepth > 0 and Thickness > PierceDepth then
				FoundSolid = true
				break
			end

			if PierceForce and PierceForce > 0 then
				Runtime.PierceForceRemaining = (Runtime.PierceForceRemaining or PierceForce) - Thickness
				if Runtime.PierceForceRemaining <= 0 then
					FoundSolid = true
					break
				end
			end
		end

		local SpeedRetention, ExitVelocity = HookHelpers.FireOnMidPierce(Solver, Cast, CurrentResult, CurrentVelocity)

		if not Cast.Alive then break end

		if ExitVelocity then
			CurrentVelocity = ExitVelocity
		else
			CurrentVelocity = CurrentVelocity.Unit * (CurrentVelocity.Magnitude * SpeedRetention)
		end
		Runtime.PierceCount += 1
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
			warn("Pierce.ResolveChain: exceeded 100 iterations")
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

return table.freeze(Pierce)
