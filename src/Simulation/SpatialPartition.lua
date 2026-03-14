--!native
--!optimize 2
--!strict

-- ─── SpatialPartition ────────────────────────────────────────────────────────
--[[
    Grid-based cast step-frequency partitioning.

    Divides the world into uniform cubic cells. Each frame, cells near
    registered interest points (typically player positions) are assigned
    a step tier — HOT, WARM, or COLD. StepProjectile queries the tier
    for each cast's current cell before deciding whether to step it this
    frame or accumulate the delta and skip.

    Consumer contract:
        Solver:SetInterestPoints({ Vector3, ... }) each frame.
        Solver rebuilds the grid every UpdateInterval frames automatically.

    Tier meaning (step every N frames):
        HOT  = 1  — full simulation, every frame
        WARM = 2  — half frequency
        COLD = 4  — quarter frequency
        nil       — no interest nearby; FallbackTier is used instead
]]

-- ─── Module References ───────────────────────────────────────────────────────

local Identity        = "SpatialPartition"
local SpatialPartition = {}
SpatialPartition.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)
local t          = require(Core.TypeCheck)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

-- ─── Private Helpers ─────────────────────────────────────────────────────────

-- Convert a world-space position to a cell coordinate string key.
-- math.floor ensures negative coordinates map correctly:
--   position -1 with cellSize 50 → cell -1, not 0.
local function ToCellKey(Position: Vector3, CellSize: number): string
	local cx = math.floor(Position.X / CellSize)
	local cy = math.floor(Position.Y / CellSize)
	local cz = math.floor(Position.Z / CellSize)
	return cx .. "," .. cy .. "," .. cz
end

-- Mark a cubic radius of cells around a world position with the given tier.
-- Only writes to cells that have not yet been assigned a better (lower N) tier.
-- This ensures HOT cells written first are never overwritten by WARM.
local function MarkRadius(
	Grid        : { [string]: number },
	Position    : Vector3,
	CellSize    : number,
	Radius      : number,
	Tier        : number
)
	local OriginCX = math.floor(Position.X / CellSize)
	local OriginCY = math.floor(Position.Y / CellSize)
	local OriginCZ = math.floor(Position.Z / CellSize)

	for dx = -Radius, Radius do
		for dy = -Radius, Radius do
			for dz = -Radius, Radius do
				local Key         = (OriginCX + dx) .. "," .. (OriginCY + dy) .. "," .. (OriginCZ + dz)
				local ExistingTier = Grid[Key]
				-- Lower N = higher priority. Never downgrade an existing tier.
				if ExistingTier == nil or Tier < ExistingTier then
					Grid[Key] = Tier
				end
			end
		end
	end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

-- Build a fresh spatial grid from the solver's current interest points.
-- Called by StepProjectile every UpdateInterval frames.
--
-- The grid is a flat { [cellKey] = tier } table. Cells not present in the
-- table have no interest nearby; callers should apply FallbackTier.
function SpatialPartition.Rebuild(Solver: any)
	local Config          = Solver._SpatialConfig
	local InterestPoints  = Solver._InterestPoints
	local CellSize        = Config.CellSize
	local HotRadius       = Config.HotRadius
	local WarmRadius      = Config.WarmRadius
	local Tiers           = Constants.SPATIAL_TIERS

	-- Reuse the existing table rather than allocating a new one every rebuild.
	-- table.clear preserves the table's allocated capacity which avoids
	-- rehashing on the subsequent insertions.
	local Grid = Solver._SpatialGrid
	table.clear(Grid)

	if #InterestPoints == 0 then
		-- No interest points registered. Grid stays empty; all casts will
		-- fall through to FallbackTier in GetTier.
		if Config.WarnOnEmpty then
			Logger:Warn("SpatialPartition.Rebuild: no interest points set — all casts using FallbackTier")
		end
		return
	end

	for _, Point in InterestPoints do
		-- HOT first so it is never overwritten by the wider WARM pass.
		MarkRadius(Grid, Point, CellSize, HotRadius,  Tiers.HOT)
		MarkRadius(Grid, Point, CellSize, WarmRadius, Tiers.WARM)
	end
end

-- Return the step tier (number of frames between steps) for the given
-- world position. Returns FallbackTier if the cell has no entry.
function SpatialPartition.GetTier(Solver: any, Position: Vector3): number
	local Config   = Solver._SpatialConfig
	local Key      = ToCellKey(Position, Config.CellSize)
	local Tier     = Solver._SpatialGrid[Key]
	return Tier or Config.FallbackTier
end

-- Resolve and validate a consumer-supplied config table, filling in
-- defaults for any missing fields. Returns a frozen config.
function SpatialPartition.ResolveConfig(RawConfig: any?): any
	
	local Raw     = RawConfig or {}
	local Tiers   = Constants.SPATIAL_TIERS
	
	if Raw.FallbackTier and not t.number(Raw.FallbackTier) then
		Logger:Warn("SpatialPartition.ResolveConfig: FallbackTier must be a Constants.SPATIAL_TIERS value — defaulting to HOT")
	end
	
	local FallbackTier = (Raw.FallbackTier and t.number(Raw.FallbackTier)) and Raw.FallbackTier or Constants.SPATIAL_TIERS.HOT

	-- WarmRadius must be >= HotRadius. Clamp silently.
	local HotRadius  = Raw.HotRadius  or Constants.SPATIAL_DEFAULT_HOT_RADIUS
	local WarmRadius = Raw.WarmRadius or Constants.SPATIAL_DEFAULT_WARM_RADIUS
	if WarmRadius < HotRadius then
		Logger:Warn("SpatialPartition.ResolveConfig: WarmRadius < HotRadius — clamping WarmRadius to HotRadius")
		WarmRadius = HotRadius
	end

	return table.freeze({
		Enabled        = Raw.Enabled        ~= false,  -- default true if key missing
		CellSize       = Raw.CellSize       or Constants.SPATIAL_DEFAULT_CELL_SIZE,
		HotRadius      = HotRadius,
		WarmRadius     = WarmRadius,
		UpdateInterval = Raw.UpdateInterval or Constants.SPATIAL_DEFAULT_UPDATE_INTERVAL,
		FallbackTier   = FallbackTier,
		WarnOnEmpty    = Raw.WarnOnEmpty    ~= false,   -- default true
	})
end

-- ─── Module Return ────────────────────────────────────────────────────────────

local SpatialMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("SpatialPartition: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"SpatialPartition: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(SpatialPartition, SpatialMetatable)