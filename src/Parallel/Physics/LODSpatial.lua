--!native
--!optimize 2
--!strict

local LODSpatial = {}


local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core


local Constants      = require(Core.Constants)
local TypeDefinition = require(Vetra.Types)


local SPATIAL_TIERS = Constants.SPATIAL_TIERS
local CELL_STRIDE    = Constants.SPATIAL_CELL_STRIDE
local CELL_OFFSET    = Constants.SPATIAL_CELL_OFFSET
local CELL_STRIDE_SQ = Constants.SPATIAL_CELL_STRIDE_SQ
local math_floor     = math.floor


type CastSnapshot = TypeDefinition.CastSnapshot


local Grid         : { [number]: number }? = nil
local CellSize     : number = Constants.SPATIAL_DEFAULT_CELL_SIZE
local FallbackTier : number = SPATIAL_TIERS.HOT

function LODSpatial.SetGrid(
	NewGrid         : { [number]: number }?,
	NewCellSize     : number?,
	NewFallbackTier : number?
)
	Grid = NewGrid
	if NewCellSize     then CellSize     = NewCellSize     end
	if NewFallbackTier then FallbackTier = NewFallbackTier end
end



function LODSpatial.Resolve(
	Snapshot        : CastSnapshot,
	FrameDelta      : number,
	CurrentPosition : Vector3?
): (boolean, number, number, number, number, number, boolean, number)

	local IsLOD                   = Snapshot.IsLOD
	local LODFrameAccumulator     = Snapshot.LODFrameAccumulator
	local LODDeltaAccumulator     = Snapshot.LODDeltaAccumulator
	local SpatialFrameAccumulator = Snapshot.SpatialFrameAccumulator
	local SpatialDeltaAccumulator = Snapshot.SpatialDeltaAccumulator

	if Snapshot.LODDistance > 0 and Snapshot.LODOrigin and CurrentPosition then
		local Delta = CurrentPosition - Snapshot.LODOrigin
		local ShouldBeInLOD = Delta.X * Delta.X + Delta.Y * Delta.Y + Delta.Z * Delta.Z
			> Snapshot.LODDistance * Snapshot.LODDistance
		if ShouldBeInLOD ~= IsLOD then
			IsLOD                   = ShouldBeInLOD
			LODFrameAccumulator     = 0
			LODDeltaAccumulator     = 0
			SpatialFrameAccumulator = 0
			SpatialDeltaAccumulator = 0
		end
	end

	if IsLOD then
		LODFrameAccumulator += 1
		LODDeltaAccumulator  = (LODDeltaAccumulator or 0) + FrameDelta
		if LODFrameAccumulator >= (Snapshot.LODInterval or 3) then
			local AccumulatedDelta = LODDeltaAccumulator
			return false, AccumulatedDelta, 0, 0, 0, 0, IsLOD, AccumulatedDelta
		end
		return true, FrameDelta, LODFrameAccumulator, LODDeltaAccumulator,
		SpatialFrameAccumulator, SpatialDeltaAccumulator, IsLOD, 0
	end

	local Tier = SPATIAL_TIERS.HOT
	if Grid and CurrentPosition then
		local cx  = math_floor(CurrentPosition.X / CellSize) + CELL_OFFSET
		local cy  = math_floor(CurrentPosition.Y / CellSize) + CELL_OFFSET
		local cz  = math_floor(CurrentPosition.Z / CellSize) + CELL_OFFSET
		local Key = cx + cy * CELL_STRIDE + cz * CELL_STRIDE_SQ
		Tier      = Grid[Key] or FallbackTier
	end
	Snapshot.SpatialTier = Tier

	if Tier > SPATIAL_TIERS.HOT then
		SpatialFrameAccumulator = (SpatialFrameAccumulator or 0) + 1
		SpatialDeltaAccumulator = (SpatialDeltaAccumulator or 0) + FrameDelta
		if SpatialFrameAccumulator < Tier then
			return true, FrameDelta, LODFrameAccumulator, LODDeltaAccumulator,
			SpatialFrameAccumulator, SpatialDeltaAccumulator, IsLOD, 0
		end
		local AccumulatedDelta = SpatialDeltaAccumulator
		return false, AccumulatedDelta, LODFrameAccumulator, LODDeltaAccumulator,
		0, 0, IsLOD, AccumulatedDelta
	end

	return false, FrameDelta, LODFrameAccumulator, LODDeltaAccumulator, 0, 0, IsLOD, 0
end

return table.freeze(LODSpatial)
