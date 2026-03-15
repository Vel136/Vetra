--!native
--!optimize 2
--!strict

-- ─── ResimulateHighFidelity ──────────────────────────────────────────────────
--[[
    Sub-segment resimulation loop with adaptive segment sizing.
]]

local Identity              = "ResimulateHighFidelity"
local ResimulateHighFidelity = {}
ResimulateHighFidelity.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra      = script.Parent.Parent
local Core       = Vetra.Core
local Simulation = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Enums		   = require(Core.Enums)
local LogService   = require(Core.Logger)
local Constants    = require(Core.Constants)
local SimulateCast = require(Simulation.SimulateCast)
local FrameBudget  = require(Simulation.FrameBudget)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Constants ───────────────────────────────────────────────────────────────

local TERMINATE_REASON = Enums.TerminateReason

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local os_clock = os.clock
local math_clamp = math.clamp
local math_floor = math.floor
local math_min   = math.min
local math_max   = math.max

-- ─── Module ──────────────────────────────────────────────────────────────────

function ResimulateHighFidelity.Execute(Solver: any,Cast: any,FrameDelta: number,FrameDisplacement: number): boolean
	local Terminate = Solver._Terminate

	if Cast.Runtime.IsActivelyResimulating then
		Terminate(Solver, Cast, TERMINATE_REASON.Manual)
		Logger:Error("ResimulateHighFidelity: cascade resimulation detected")
		return false
	end

	Cast.Runtime.IsActivelyResimulating = true
	Cast.Runtime.CancelResimulation     = false

	local Behavior = Cast.Behavior
	local Budget   = Solver._FrameBudget

	local SubSegmentCount = math_clamp(
		math_floor(FrameDisplacement / Cast.Runtime.CurrentSegmentSize),
		1,
		Constants.MAX_SUBSEGMENTS
	)

	if SubSegmentCount >= Constants.MAX_SUBSEGMENTS then
		Cast.Runtime.CurrentSegmentSize = Cast.Runtime.CurrentSegmentSize * Behavior.AdaptiveScaleFactor * 2
		Logger:Warn(string.format("ResimulateHighFidelity: SubSegmentCount capped at %d",Constants.MAX_SUBSEGMENTS))
	end

	local SubSegmentDelta       = FrameDelta / SubSegmentCount
	local HitOccurred           = false
	local ResimulationStartTime = os_clock()

	for _ = 1, SubSegmentCount do
		if Cast.Runtime.CancelResimulation then break end

		local SegmentStartTime = os_clock()
		SimulateCast.StepProjectile(Solver, Cast, SubSegmentDelta, true)
		FrameBudget.Consume(Budget, os_clock() - SegmentStartTime)

		if not Cast.Alive then HitOccurred = true break end

		if FrameBudget.IsExhausted(Budget) then break end
	end

	Cast.Runtime.CancelResimulation = false

	local ResimulationElapsedMs = (os_clock() - ResimulationStartTime) * 1000
	local IsOverBudget          = ResimulationElapsedMs > Behavior.HighFidelityFrameBudget
	-- Only shrink the segment size if this cast actually ran long enough to
	-- consume real budget time. When the shared FrameBudget is depleted by
	-- earlier casts in the same frame, ResimulationElapsedMs ≈ 0 — treating
	-- that as "under half budget" would drive CurrentSegmentSize toward
	-- MinSegmentSize on every frame, creating a positive feedback loop where
	-- more sub-segments are requested next frame, consuming even more budget.
	local WasBudgetLimited  = FrameBudget.IsExhausted(Budget)
	local IsUnderHalfBudget = (not WasBudgetLimited) and ResimulationElapsedMs < Behavior.HighFidelityFrameBudget * 0.5

	if IsOverBudget then
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

-- ─── Module Return ───────────────────────────────────────────────────────────

local ResimMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("ResimulateHighFidelity: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"ResimulateHighFidelity: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(ResimulateHighFidelity, ResimMetatable)