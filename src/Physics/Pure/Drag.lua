--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Drag ───────────────────────────────────────────────────────
--[[
    Pure drag math — no Cast references, no signal calls, no Instance writes.

    Safe to call from both the serial simulation and the parallel Actor context.
    The serial Drag wrapper and ParallelPhysics both delegate here so the two
    paths share a single implementation rather than each keeping a private copy.
]]

local PureDrag   = {}
PureDrag.__type  = "PureDrag"

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants = require(Core.Constants)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_exp         = math.exp

local DRAG_MODEL       = Constants.DRAG_MODEL
local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND

-- MachTables is re-exported by Constants so no separate require is needed.
local MachTables       = Constants.MACH_TABLES

-- Dispatch table: DRAG_MODEL enum value → built-in Mach/Cd table.
-- Custom (13) is intentionally absent — it is handled via the CustomMachTable
-- parameter passed directly to ComputeDragDeceleration.
local G_SERIES_TABLES = {
	[DRAG_MODEL.G1] = MachTables.G1,
	[DRAG_MODEL.G2] = MachTables.G2,
	[DRAG_MODEL.G3] = MachTables.G3,
	[DRAG_MODEL.G4] = MachTables.G4,
	[DRAG_MODEL.G5] = MachTables.G5,
	[DRAG_MODEL.G6] = MachTables.G6,
	[DRAG_MODEL.G7] = MachTables.G7,
	[DRAG_MODEL.G8] = MachTables.G8,
	[DRAG_MODEL.GL] = MachTables.GL,
}

local LerpMachTable = MachTables.Lerp

-- ─── Module ──────────────────────────────────────────────────────────────────

--[[
    Returns the drag deceleration vector for the given velocity.
    Returns Vector3.zero when speed is negligible.

    CustomMachTable is only consulted when Model == DRAG_MODEL.Custom.
    For all other models it may be nil and is ignored.
]]
function PureDrag.ComputeDragDeceleration(
	Velocity        : Vector3,
	Coefficient     : number,
	Model           : number,
	CustomMachTable : { { number } }?
): Vector3
	local Speed = Velocity.Magnitude
	if Speed * Speed < MIN_MAGNITUDE_SQ then return ZERO_VECTOR end

	local DragMagnitude: number
	if Model == DRAG_MODEL.Linear then
		DragMagnitude = Coefficient * Speed
	elseif Model == DRAG_MODEL.Exponential then
		DragMagnitude = Coefficient * Speed * math_exp(Speed / SPEED_OF_SOUND)
	elseif Model == DRAG_MODEL.Custom then
		-- User-supplied Mach/Cd table. Falls back to Quadratic if none provided
		-- so a misconfigured behavior degrades gracefully rather than erroring.
		if CustomMachTable then
			local Cd = LerpMachTable(CustomMachTable, Speed / SPEED_OF_SOUND)
			DragMagnitude = Coefficient * Cd * Speed * Speed
		else
			DragMagnitude = Coefficient * Speed * Speed
		end
	else
		-- G-series empirical lookup — all nine models share the same formula:
		--   DragMagnitude = Coefficient * Cd(Mach) * Speed²
		-- Falls through to plain Quadratic when the model ID is unrecognised.
		local GTable = G_SERIES_TABLES[Model]
		if GTable then
			local Cd = LerpMachTable(GTable, Speed / SPEED_OF_SOUND)
			DragMagnitude = Coefficient * Cd * Speed * Speed
		else
			-- Quadratic (default / unrecognised model)
			DragMagnitude = Coefficient * Speed * Speed
		end
	end

	return -(Velocity.Unit * DragMagnitude)
end

--[[
    Selects the effective drag coefficient and model based on the current
    supersonic/subsonic state and optional override profiles.

    Parameters mirror the snapshot fields used by both serial and parallel paths
    so neither path needs an adapter layer.
]]
function PureDrag.GetEffectiveDragParameters(
	IsSupersonic        : boolean,
	SupersonicCoeff     : number?,
	SupersonicModel     : number?,
	SubsonicCoeff       : number?,
	SubsonicModel       : number?,
	BaseCoeff           : number,
	BaseModel           : number
): (number, number)
	if IsSupersonic and SupersonicCoeff then
		return SupersonicCoeff, SupersonicModel or BaseModel
	elseif not IsSupersonic and SubsonicCoeff then
		return SubsonicCoeff, SubsonicModel or BaseModel
	end
	return BaseCoeff, BaseModel
end

--[[
    Returns true when enough simulation time has passed since the last
    drag segment recalculation to warrant a new one.
]]
function PureDrag.ShouldRecalculate(
	LastRecalcTime : number,
	CurrentTime    : number,
	Interval       : number
): boolean
	return (CurrentTime - LastRecalcTime) >= Interval
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(PureDrag)
