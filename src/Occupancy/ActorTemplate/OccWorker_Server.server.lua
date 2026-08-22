--!optimize 2

local Actor = script:GetActor()
if not Actor then
	error("[OccWorker] Must run inside an Actor instance.")
	return
end

local OccupancyReference = script.Parent:WaitForChild("OccupancyReference")
local Occupancy   = OccupancyReference.Value
local StaticOccupancy = require(Occupancy.StaticOccupancy)
local VoxelBaker    = require(Occupancy.VoxelBaker)

local Output: SharedTable = nil :: any

Actor:BindToMessage("Init", function(OutputST: SharedTable, ReadyST: SharedTable)
	Output = OutputST
	ReadyST["ready"] += 1
end)

Actor:BindToMessageParallel("BakeSlab", function(
	slabStartVX: number, slabEndVX: number,
	regionCFrame: CFrame, regionSize: Vector3, voxelSize: number,
	doneST: SharedTable, slot: number, ignoreTags: { string }?
)
	local grid = StaticOccupancy.new(voxelSize)
	local voxelInv = grid.voxelInv

	local slabMinX = slabStartVX * voxelSize
	local slabMaxX = (slabEndVX + 1) * voxelSize
	local slabCenterX = (slabMinX + slabMaxX) * 0.5
	local slabSizeX   = slabMaxX - slabMinX

	local origin = regionCFrame.Position
	local slabCFrame = CFrame.new(slabCenterX, origin.Y, origin.Z)
	local slabSize   = Vector3.new(slabSizeX, regionSize.Y, regionSize.Z)

	local op = VoxelBaker._buildOverlapParams(ignoreTags or VoxelBaker._DEFAULT_IGNORE_TAGS)
	local parts = workspace:GetPartBoundsInBox(slabCFrame, slabSize, op)

	local YIELD = VoxelBaker._YIELD_INTERVAL
	local clock = os.clock()
	for _, part in parts do
		VoxelBaker._markPart(grid, part, voxelSize, voxelInv, slabStartVX, slabEndVX)
		if os.clock() - clock >= YIELD then
			task.wait()
			clock = os.clock()
		end
	end

	local count = grid.count
	local buf = buffer.create(4 + count * 8)
	buffer.writeu32(buf, 0, count)
	local o = 4
	for k in grid.set do
		buffer.writef64(buf, o, k)
		o += 8
	end

	Output[slot] = buffer.tostring(buf)
	doneST["done"] += 1
end)
