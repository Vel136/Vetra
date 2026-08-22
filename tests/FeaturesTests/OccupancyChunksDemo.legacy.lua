local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local StaticOccupancy = require(ReplicatedStorage.src.Occupancy.StaticOccupancy)
local OccupancyChunks = require(ReplicatedStorage.src.Occupancy.OccupancyChunks)
local VoxelBaker      = require(ReplicatedStorage.src.Occupancy.VoxelBaker)

local Demo = Instance.new("Folder")
Demo.Name   = "VetraBakeDemoGeometry"
Demo.Parent = workspace

for i = 1, 6 do
	local Wall      = Instance.new("Part")
	Wall.Anchored   = true
	Wall.CanCollide = false
	Wall.Size       = Vector3.new(80, 40, 6)
	Wall.Position   = Vector3.new((i - 3) * 40, 20, (i % 2) * 30)
	Wall.Parent     = Demo
end


local VOXEL_SIZE  = 2
local REGION_CF   = CFrame.new(0, 20, 15)
local REGION_SIZE = Vector3.new(300, 80, 100)

local Grid = StaticOccupancy.new(VOXEL_SIZE)
VoxelBaker.BakeRegion(Grid, REGION_CF, REGION_SIZE)

local Blob = Grid:Serialize()

local BakeFolder = ServerStorage:FindFirstChild("VetraOccupancyBake")
if not BakeFolder then
	BakeFolder = Instance.new("Folder")
	BakeFolder.Name   = "VetraOccupancyBake"
	BakeFolder.Parent = ServerStorage
end

OccupancyChunks.Write(BakeFolder, Blob)

local Loaded = OccupancyChunks.Read(BakeFolder)
if Loaded then
	local Rebuilt = StaticOccupancy.Deserialize(Loaded)
end


