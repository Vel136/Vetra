--!native
--!optimize 2
--!strict

local SpatialPartition = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)
local t         = require(Core.TypeCheck)

local CELL_STRIDE    = Constants.SPATIAL_CELL_STRIDE
local CELL_OFFSET    = Constants.SPATIAL_CELL_OFFSET
local CELL_STRIDE_SQ = Constants.SPATIAL_CELL_STRIDE_SQ

local function ToCellKey(Position: Vector3, CellSize: number): number
	local cx = math.floor(Position.X / CellSize) + CELL_OFFSET
	local cy = math.floor(Position.Y / CellSize) + CELL_OFFSET
	local cz = math.floor(Position.Z / CellSize) + CELL_OFFSET
	return cx + cy * CELL_STRIDE + cz * CELL_STRIDE_SQ
end

local function MarkRadius(
	Grid        : { [number]: number },
	Position    : Vector3,
	CellSize    : number,
	InnerRadius : number,
	Radius      : number,
	Tier        : number
)
	local OriginCX = math.floor(Position.X / CellSize) + CELL_OFFSET
	local OriginCY = math.floor(Position.Y / CellSize) + CELL_OFFSET
	local OriginCZ = math.floor(Position.Z / CellSize) + CELL_OFFSET

	for dx = -Radius, Radius do
		local BaseX  = OriginCX + dx
		local AbsX   = dx < 0 and -dx or dx
		for dy = -Radius, Radius do
			local BaseXY = BaseX + (OriginCY + dy) * CELL_STRIDE
			local AbsY   = dy < 0 and -dy or dy
			local MaxXY  = AbsX > AbsY and AbsX or AbsY
			for dz = -Radius, Radius do
				local AbsZ = dz < 0 and -dz or dz
				local Cheb = MaxXY > AbsZ and MaxXY or AbsZ
				if Cheb > InnerRadius then
					local Key          = BaseXY + (OriginCZ + dz) * CELL_STRIDE_SQ
					local ExistingTier = Grid[Key]
					if ExistingTier == nil or Tier < ExistingTier then
						Grid[Key] = Tier
					end
				end
			end
		end
	end
end

function SpatialPartition.Rebuild(Solver: any)
	local Config         = Solver._SpatialConfig
	local InterestPoints = Solver._InterestPoints
	local CellSize       = Config.CellSize
	local Tiers          = Config.Tiers

	local Grid = Solver._SpatialGrid
	table.clear(Grid)

	if #InterestPoints == 0 then
		return
	end

	for _, Point in InterestPoints do
		local InnerRadius = -1
		for _, Tier in Tiers do
			MarkRadius(Grid, Point, CellSize, InnerRadius, Tier.Radius, Tier.Rate)
			InnerRadius = Tier.Radius
		end
	end
end

function SpatialPartition.GetTierForGrid(
	Grid         : { [number]: number },
	CellSize     : number,
	FallbackTier : number,
	Position     : Vector3
): number
	local Key  = ToCellKey(Position, CellSize)
	local Tier = Grid[Key]
	return Tier or FallbackTier
end

function SpatialPartition.GetTier(Solver: any, Position: Vector3): number
	local Config = Solver._SpatialConfig
	return SpatialPartition.GetTierForGrid(
		Solver._SpatialGrid, Config.CellSize, Config.FallbackTier, Position
	)
end

function SpatialPartition.ResolveConfig(RawConfig: any?): any
	local Raw = RawConfig or {}

	local Tiers: { { Radius: number, Rate: number } } = {}

	if Raw.Tiers ~= nil then
		if not t.table(Raw.Tiers) then
			warn("SpatialPartition.ResolveConfig: Tiers must be an array of {Radius, Rate} — ignoring")
		else
			for Index, Entry in Raw.Tiers do
				if not t.table(Entry) or not t.number(Entry.Radius) or not t.number(Entry.Rate) then
					warn(string.format("SpatialPartition.ResolveConfig: Tiers[%d] needs numeric Radius and Rate — skipping", Index))
					continue
				end
				if Entry.Radius < 0 then
					warn(string.format("SpatialPartition.ResolveConfig: Tiers[%d].Radius < 0 — skipping", Index))
					continue
				end
				if Entry.Rate < 1 then
					warn(string.format("SpatialPartition.ResolveConfig: Tiers[%d].Rate < 1 — clamping to 1 (every frame)", Index))
				end
				table.insert(Tiers, {
					Radius = Entry.Radius,
					Rate   = math.max(1, math.floor(Entry.Rate)),
				})
			end
		end
	end

	if #Tiers == 0 then
		local HotRadius  = Raw.HotRadius  or Constants.SPATIAL_DEFAULT_HOT_RADIUS
		local WarmRadius = Raw.WarmRadius or Constants.SPATIAL_DEFAULT_WARM_RADIUS
		if WarmRadius < HotRadius then
			warn("SpatialPartition.ResolveConfig: WarmRadius < HotRadius — clamping WarmRadius to HotRadius")
			WarmRadius = HotRadius
		end
		Tiers = {
			{ Radius = HotRadius,  Rate = Constants.SPATIAL_TIERS.HOT  },
			{ Radius = WarmRadius, Rate = Constants.SPATIAL_TIERS.WARM },
		}
	end

	table.sort(Tiers, function(A, B) return A.Radius < B.Radius end)
	for Index = 2, #Tiers do
		if Tiers[Index].Rate < Tiers[Index - 1].Rate then
			warn(string.format(
				"SpatialPartition.ResolveConfig: Tiers[%d].Rate (%d) is lower than the ring inside it (%d) — " ..
				"an outer ring stepping MORE often than an inner one is almost certainly a mistake, and the " ..
				"min-wins merge will ignore it anyway",
				Index, Tiers[Index].Rate, Tiers[Index - 1].Rate))
		end
	end

	local RawFallback = Raw.FallbackRate ~= nil and Raw.FallbackRate or Raw.FallbackTier
	if RawFallback ~= nil and not t.number(RawFallback) then
		warn("SpatialPartition.ResolveConfig: FallbackRate must be a number — defaulting to every-frame")
		RawFallback = nil
	end
	local FallbackRate = RawFallback and math.max(1, math.floor(RawFallback)) or Constants.SPATIAL_TIERS.HOT

	for _, Entry in Tiers do
		table.freeze(Entry)
	end

	return table.freeze({
		Enabled        = Raw.Enabled        ~= false,
		CellSize       = Raw.CellSize       or Constants.SPATIAL_DEFAULT_CELL_SIZE,
		Tiers          = table.freeze(Tiers),
		UpdateInterval = Raw.UpdateInterval or Constants.SPATIAL_DEFAULT_UPDATE_INTERVAL,
		FallbackTier   = FallbackRate,
		FallbackRate   = FallbackRate,
	})
end

return table.freeze(SpatialPartition)
