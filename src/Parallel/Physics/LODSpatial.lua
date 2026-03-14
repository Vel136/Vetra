--!native
--!optimize 2
--!strict

-- ─── LODSpatial ──────────────────────────────────────────────────────────────
--[[
    LOD distance and spatial tier skip logic.

    Determines whether a cast should be skipped this frame, and computes the
    effective StepDelta (which may be an accumulated delta from skipped frames).
    Both Step and StepHighFidelity run this before doing any physics work.

    Returns a LODResult table rather than multiple return values — the 8-value
    tuple was unwieldy at every call site.
]]

local Identity   = "LODSpatial"
local LODSpatial = {}
LODSpatial.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants      = require(Core.Constants)
local TypeDefinition = require(Core.TypeDefinition)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local SPATIAL_TIERS = Constants.SPATIAL_TIERS

-- ─── Types ───────────────────────────────────────────────────────────────────

type CastSnapshot = TypeDefinition.CastSnapshot

export type LODResult = {
	ShouldSkip              : boolean,
	StepDelta               : number,
	LODFrameAccumulator     : number,
	LODDeltaAccumulator     : number,
	SpatialFrameAccumulator : number,
	SpatialDeltaAccumulator : number,
	IsLOD                   : boolean,
	FiredAccumulatedDelta   : number,
}

-- ─── Module ──────────────────────────────────────────────────────────────────

function LODSpatial.Resolve(
	Snapshot        : CastSnapshot,
	FrameDelta      : number,
	CurrentPosition : Vector3
): LODResult

	local IsLOD                   = Snapshot.IsLOD
	local LODFrameAccumulator     = Snapshot.LODFrameAccumulator
	local LODDeltaAccumulator     = Snapshot.LODDeltaAccumulator
	local SpatialFrameAccumulator = Snapshot.SpatialFrameAccumulator
	local SpatialDeltaAccumulator = Snapshot.SpatialDeltaAccumulator

	-- ── LOD distance check ────────────────────────────────────────────────────
	if Snapshot.LODDistance > 0 and Snapshot.LODOrigin then
		local DistanceToOrigin = (CurrentPosition - Snapshot.LODOrigin).Magnitude
		local ShouldBeInLOD    = DistanceToOrigin > Snapshot.LODDistance
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
		if LODFrameAccumulator >= 3 then
			local AccumulatedDelta = LODDeltaAccumulator
			return {
				ShouldSkip              = false,
				StepDelta               = AccumulatedDelta,
				LODFrameAccumulator     = 0,
				LODDeltaAccumulator     = 0,
				SpatialFrameAccumulator = 0,
				SpatialDeltaAccumulator = 0,
				IsLOD                   = IsLOD,
				FiredAccumulatedDelta   = AccumulatedDelta,
			}
		end
		return {
			ShouldSkip              = true,
			StepDelta               = FrameDelta,
			LODFrameAccumulator     = LODFrameAccumulator,
			LODDeltaAccumulator     = LODDeltaAccumulator,
			SpatialFrameAccumulator = SpatialFrameAccumulator,
			SpatialDeltaAccumulator = SpatialDeltaAccumulator,
			IsLOD                   = IsLOD,
			FiredAccumulatedDelta   = 0,
		}
	end

	-- ── Spatial tier skip ─────────────────────────────────────────────────────
	local Tier = Snapshot.SpatialTier
	if Tier > SPATIAL_TIERS.HOT then
		SpatialFrameAccumulator = (SpatialFrameAccumulator or 0) + 1
		SpatialDeltaAccumulator = (SpatialDeltaAccumulator or 0) + FrameDelta
		if SpatialFrameAccumulator < Tier then
			return {
				ShouldSkip              = true,
				StepDelta               = FrameDelta,
				LODFrameAccumulator     = LODFrameAccumulator,
				LODDeltaAccumulator     = LODDeltaAccumulator,
				SpatialFrameAccumulator = SpatialFrameAccumulator,
				SpatialDeltaAccumulator = SpatialDeltaAccumulator,
				IsLOD                   = IsLOD,
				FiredAccumulatedDelta   = 0,
			}
		end
		local AccumulatedDelta = SpatialDeltaAccumulator
		return {
			ShouldSkip              = false,
			StepDelta               = AccumulatedDelta,
			LODFrameAccumulator     = LODFrameAccumulator,
			LODDeltaAccumulator     = LODDeltaAccumulator,
			SpatialFrameAccumulator = 0,
			SpatialDeltaAccumulator = 0,
			IsLOD                   = IsLOD,
			FiredAccumulatedDelta   = AccumulatedDelta,
		}
	end

	return {
		ShouldSkip              = false,
		StepDelta               = FrameDelta,
		LODFrameAccumulator     = LODFrameAccumulator,
		LODDeltaAccumulator     = LODDeltaAccumulator,
		SpatialFrameAccumulator = 0,
		SpatialDeltaAccumulator = 0,
		IsLOD                   = IsLOD,
		FiredAccumulatedDelta   = 0,
	}
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(LODSpatial)