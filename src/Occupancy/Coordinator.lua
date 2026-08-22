--!optimize 2

local RunService = game:GetService("RunService")

local Occupancy     = script.Parent
local StaticOccupancy = require(Occupancy.StaticOccupancy)

local Coordinator = {}
Coordinator.__index = Coordinator

local WorkerTemplate = Occupancy:FindFirstChild("ActorTemplate")
	and (RunService:IsClient()
		and Occupancy.ActorTemplate:FindFirstChild("OccWorker_Client")
		or  Occupancy.ActorTemplate:FindFirstChild("OccWorker_Server"))
	or nil

function Coordinator.new(numWorkers: number)
	local self = setmetatable({}, Coordinator)
	self._numWorkers = math.max(1, numWorkers)
	self._actors     = {}
	self._outputST   = SharedTable.new()
	self._doneST     = SharedTable.new({ done = 0 })
	self._available  = WorkerTemplate ~= nil
	return self
end

function Coordinator._spawn(self)
	if not self._available then return false end

	local readyST = SharedTable.new({ ready = 0 })

	for i = 1, self._numWorkers do
		local actor = Instance.new("Actor")
		actor.Name  = "VetraOccWorker_" .. i

		local ref   = Instance.new("ObjectValue")
		ref.Name    = "OccupancyReference"
		ref.Value   = Occupancy
		ref.Parent  = actor

		local worker   = WorkerTemplate:Clone()
		worker.Parent  = actor
		worker.Enabled = true

		actor.Parent = Occupancy

		local outputST = self._outputST
		task.defer(function()
			actor:SendMessage("Init", outputST, readyST)
		end)

		self._actors[i] = actor
	end

	local deadline = os.clock() + 5
	while readyST["ready"] < self._numWorkers do
		if os.clock() > deadline then
			warn("[Vetra Occupancy] workers failed to init in time")
			return false
		end
		task.wait()
	end
	return true
end

function Coordinator.Bake(self, grid, regionCFrame: CFrame, regionSize: Vector3, opts: any?)
	if not self:_spawn() then return false end

	opts = opts or {}
	local vs       = grid.voxelSize
	local voxelInv = grid.voxelInv
	local origin   = regionCFrame.Position

	local startVX = math.floor((origin.X - regionSize.X * 0.5) * voxelInv)
	local endVX   = math.floor((origin.X + regionSize.X * 0.5) * voxelInv)
	local totalCols = endVX - startVX + 1

	local numWorkers = #self._actors
	local colsPer    = math.ceil(totalCols / numWorkers)

	SharedTable.clear(self._outputST)
	self._doneST["done"] = 0

	local ignoreTags = opts.ignoreTags
	local dispatched = 0
	for i = 1, numWorkers do
		local slabStartVX = startVX + (i - 1) * colsPer
		local slabEndVX   = math.min(startVX + i * colsPer - 1, endVX)
		if slabStartVX > endVX then break end
		dispatched += 1
		self._actors[i]:SendMessage("BakeSlab",
			slabStartVX, slabEndVX,
			regionCFrame, regionSize, vs,
			self._doneST, i, ignoreTags)
	end

	local deadline = os.clock() + 60
	while self._doneST["done"] < dispatched do
		if os.clock() > deadline then
			warn("[Vetra Occupancy] parallel bake timed out")
			break
		end
		task.wait()
	end

	for slot = 1, dispatched do
		local blob = self._outputST[slot]
		if not blob then continue end
		local buf   = buffer.fromstring(blob)
		local count = buffer.readu32(buf, 0)
		local o = 4
		for _ = 1, count do
			grid:MarkKey(buffer.readf64(buf, o))
			o += 8
		end
	end
	grid:RecomputeBounds()

	if opts.Verbose then
		print(string.format("[Vetra Occupancy] Parallel baked %d voxels across %d workers (vs=%g)",
			grid.count, dispatched, vs))
	end
	return true
end

function Coordinator.Destroy(self)
	for _, actor in self._actors do
		actor:Destroy()
	end
	self._actors = {}
end

return Coordinator
