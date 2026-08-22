--!native
--!optimize 2
--!strict

local ResimulateHighFidelity = {}

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Simulation = script.Parent

local Enums        = require(Core.Enums)
local Constants    = require(Core.Constants)
local SimulateCast = require(Simulation.SimulateCast)
local FrameBudget  = require(Simulation.FrameBudget)

local Physics       = Vetra.Physics
local Magnus        = require(Physics.Magnus)
local DragPhysics   = require(Physics.Drag)
local HomingPhysics = require(Physics.Homing)
local SixDOFPhysics = require(Physics.SixDOF)

local TERMINATE_REASON = Enums.TerminateReason

local os_clock   = os.clock
local math_clamp = math.clamp
local math_floor = math.floor
local math_min   = math.min
local math_max   = math.max

function ResimulateHighFidelity.Execute(
	Solver: any,
	Cast: any,
	FrameDelta: number,
	FrameDisplacement: number,
	PositionAtStart: Vector3?,
	PositionAtEnd: Vector3?
): boolean
	local Terminate = Solver._Terminate

	if Cast.Runtime.IsActivelyResimulating then
		Terminate(Solver, Cast, TERMINATE_REASON.Manual)
		error("ResimulateHighFidelity: cascade resimulation detected")
		return false
	end

	Cast.Runtime.IsActivelyResimulating = true

	local Behavior = Cast.Behavior
	local Budget   = Solver._FrameBudget

	local DesiredSubs = math_floor(FrameDisplacement / Cast.Runtime.CurrentSegmentSize)
	local SubSegmentCount = math_clamp(DesiredSubs, 1, Constants.HF_SUBSEGMENT_SOFT_CAP)

	if DesiredSubs > Constants.MAX_SUBSEGMENTS then
		Cast.Runtime.CurrentSegmentSize = math_min(
			Cast.Runtime.CurrentSegmentSize * Behavior.AdaptiveScaleFactor * 2,
			Behavior.MaxDistance
		)
	end

	local Collapsed = false
	if PositionAtStart and PositionAtEnd and SubSegmentCount > 1 then
		local S = Behavior.StaticOccupancy
		local D = Behavior.DynamicOccupancy
		if (S ~= nil or D ~= nil)
			and not HomingPhysics.IsActive(Cast)
			and not (
				(Behavior.DragCoefficient > 0 or Magnus.IsActive(Behavior) or SixDOFPhysics.IsEnabled(Behavior))
				and DragPhysics.ShouldRecalculate(Cast.Runtime, Cast.Runtime.TotalRuntime + FrameDelta, Behavior.DragSegmentInterval)
			)
			and (S == nil or S:SegmentClear(PositionAtStart, PositionAtEnd - PositionAtStart))
			and (D == nil or D:SegmentClear(PositionAtStart, PositionAtEnd - PositionAtStart))
		then
			SubSegmentCount = 1
			Collapsed = true
		end
	end

	local SubSegmentDelta       = FrameDelta / SubSegmentCount
	local HitOccurred           = false
	local ResimulationStartTime = os_clock()

	for _ = 1, SubSegmentCount do
		local SegmentStartTime = os_clock()
		SimulateCast.StepProjectile(Solver, Cast, SubSegmentDelta, true)
		FrameBudget.Consume(Budget, os_clock() - SegmentStartTime)

		if not Cast.Alive then HitOccurred = true break end

		if FrameBudget.IsExhausted(Budget) then break end
	end


	local ResimulationElapsedMs = (os_clock() - ResimulationStartTime) * 1000
	local IsOverBudget          = ResimulationElapsedMs > Behavior.HighFidelityFrameBudget
	local WasBudgetLimited  = FrameBudget.IsExhausted(Budget)
	local IsUnderHalfBudget = (not Collapsed) and (not WasBudgetLimited)
		and ResimulationElapsedMs < Behavior.HighFidelityFrameBudget * 0.5

	if not Collapsed and IsOverBudget then
		Cast.Runtime.CurrentSegmentSize = math_min(
			Cast.Runtime.CurrentSegmentSize * Behavior.AdaptiveScaleFactor,
			Behavior.MaxDistance
		)
	elseif IsUnderHalfBudget then
		Cast.Runtime.CurrentSegmentSize = math_max(
			Cast.Runtime.CurrentSegmentSize / Behavior.AdaptiveScaleFactor,
			Behavior.MinSegmentSize
		)
	end

	Cast.Runtime.IsActivelyResimulating = false
	return HitOccurred
end

return table.freeze(ResimulateHighFidelity)
