--!strict
--!optimize 2
--!native

local PureDrag   = {}

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)
local Enums     = require(Core.Enums)


local DRAG_MODEL       = Enums.DragModel
local ZERO_VECTOR      = Constants.ZERO_VECTOR
local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local SPEED_OF_SOUND   = Constants.SPEED_OF_SOUND

local MachTables = Constants.MACH_TABLES

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
	elseif Model == DRAG_MODEL.Custom then
		if CustomMachTable then
			local Cd = LerpMachTable(CustomMachTable, Speed / SPEED_OF_SOUND)
			DragMagnitude = Coefficient * Cd * Speed * Speed
		else
			DragMagnitude = Coefficient * Speed * Speed
		end
	else
		local GTable = G_SERIES_TABLES[Model]
		if GTable then
			local Cd = LerpMachTable(GTable, Speed / SPEED_OF_SOUND)
			DragMagnitude = Coefficient * Cd * Speed * Speed
		else
			DragMagnitude = Coefficient * Speed * Speed
		end
	end

	return -(Velocity.Unit * DragMagnitude)
end

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

function PureDrag.ShouldRecalculate(
	LastRecalcTime : number,
	CurrentTime    : number,
	Interval       : number
): boolean
	return (CurrentTime - LastRecalcTime) >= Interval
end

return table.freeze(PureDrag)
