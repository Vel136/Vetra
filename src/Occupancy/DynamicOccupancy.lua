--!native
--!optimize 2

local StaticOccupancy = require(script.Parent.StaticOccupancy)
local VoxelBaker    = require(script.Parent.VoxelBaker)

local DynamicOccupancy = {}
DynamicOccupancy.__index = DynamicOccupancy
DynamicOccupancy.__occType = "dynamic"

local MIN_VOXELS = 3

local MIN_SCALE = 1e-3

local floor = math.floor


local function serializeShape(grid, bakeSize: Vector3): string
	local head = buffer.create(16)
	buffer.writef32(head, 0,  grid.voxelSize)
	buffer.writef32(head, 4,  bakeSize.X)
	buffer.writef32(head, 8,  bakeSize.Y)
	buffer.writef32(head, 12, bakeSize.Z)
	return buffer.tostring(head) .. grid:Serialize()
end

local function deserializeShape(blob: string): (any, Vector3)
	local head = buffer.fromstring(string.sub(blob, 1, 16))
	local bakeSize = Vector3.new(
		buffer.readf32(head, 4),
		buffer.readf32(head, 8),
		buffer.readf32(head, 12)
	)
	local grid = StaticOccupancy.Deserialize(string.sub(blob, 17))
	return grid, bakeSize
end

DynamicOccupancy._serializeShape   = serializeShape
DynamicOccupancy._deserializeShape = deserializeShape


function DynamicOccupancy.new(voxelSize: number?)
	local self = setmetatable({}, DynamicOccupancy)
	self.voxelSize   = voxelSize or 4
	self._nextId     = 1
	self._objects    = {} :: { [number]: { part: BasePart, bakeSize: Vector3 } }
	self._shapes     = {} :: { [number]: string }
	self._xforms     = {} :: { [number]: string }
	self._bounds     = {} :: { [number]: number }
	self._world      = {} :: { [number]: number }
	self._active     = {} :: { number }
	self._reader     = nil :: any
	return self
end

function DynamicOccupancy.Register(self, part: BasePart, nonUniform: boolean?): number?
	local grid, bakeSize = VoxelBaker.BakeLocal(part, self.voxelSize, nonUniform ~= false)
	if grid.count < MIN_VOXELS then
		return nil
	end

	local id = self._nextId
	self._nextId += 1
	self._objects[id] = { part = part, bakeSize = bakeSize }
	self._active[#self._active + 1] = id
	self._shapes[id] = serializeShape(grid, bakeSize)
	return id
end

function DynamicOccupancy.Unregister(self, id: number)
	self._objects[id] = nil
	self._shapes[id] = nil
	self._xforms[id] = nil
	local b = id * 6
	local bounds = self._bounds
	bounds[b - 5] = nil; bounds[b - 4] = nil; bounds[b - 3] = nil
	bounds[b - 2] = nil; bounds[b - 1] = nil; bounds[b]     = nil
	for i, v in self._active do
		if v == id then
			self._active[i] = self._active[#self._active]
			self._active[#self._active] = nil
			break
		end
	end
end

local function packXform(part: BasePart, bakeSize: Vector3): (buffer, number, number, number, number, number, number)
	local cf   = part.CFrame
    local inv  = cf:Inverse()
	local size = part.Size

	local buf = buffer.create(84)
	local px, py, pz,
		r00, r01, r02,
		r10, r11, r12,
		r20, r21, r22 = inv:GetComponents()
	buffer.writef32(buf, 0,  px);  buffer.writef32(buf, 4,  py);  buffer.writef32(buf, 8,  pz)
	buffer.writef32(buf, 12, r00); buffer.writef32(buf, 16, r01); buffer.writef32(buf, 20, r02)
	buffer.writef32(buf, 24, r10); buffer.writef32(buf, 28, r11); buffer.writef32(buf, 32, r12)
	buffer.writef32(buf, 36, r20); buffer.writef32(buf, 40, r21); buffer.writef32(buf, 44, r22)
	buffer.writef32(buf, 48, size.X / bakeSize.X)
	buffer.writef32(buf, 52, size.Y / bakeSize.Y)
	buffer.writef32(buf, 56, size.Z / bakeSize.Z)
	local wcf = part.CFrame
	local rv, uv, lv = wcf.RightVector, wcf.UpVector, wcf.LookVector
	local ax = math.abs(rv.X) * size.X + math.abs(uv.X) * size.Y + math.abs(lv.X) * size.Z
	local ay = math.abs(rv.Y) * size.X + math.abs(uv.Y) * size.Y + math.abs(lv.Y) * size.Z
	local az = math.abs(rv.Z) * size.X + math.abs(uv.Z) * size.Y + math.abs(lv.Z) * size.Z
	local wp = wcf.Position
	buffer.writef32(buf, 60, wp.X); buffer.writef32(buf, 64, wp.Y); buffer.writef32(buf, 68, wp.Z)
	buffer.writef32(buf, 72, ax * 0.5); buffer.writef32(buf, 76, ay * 0.5); buffer.writef32(buf, 80, az * 0.5)
	return buf, wp.X, wp.Y, wp.Z, ax * 0.5, ay * 0.5, az * 0.5
end

DynamicOccupancy._packXform = packXform

function DynamicOccupancy.UpdateTransforms(self)
	local bounds = self._bounds
	local wMinX, wMinY, wMinZ = math.huge, math.huge, math.huge
	local wMaxX, wMaxY, wMaxZ = -math.huge, -math.huge, -math.huge

	local i = 1
	while i <= #self._active do
		local id  = self._active[i]
		local obj = self._objects[id]
		if not obj or not obj.part.Parent then
			self:Unregister(id)
		else
			local buf, cx, cy, cz, hx, hy, hz = packXform(obj.part, obj.bakeSize)
			self._xforms[id] = buffer.tostring(buf)
			local b = id * 6
			bounds[b - 5] = cx; bounds[b - 4] = cy; bounds[b - 3] = cz
			bounds[b - 2] = hx; bounds[b - 1] = hy; bounds[b]     = hz

			local loX, hiX = cx - hx, cx + hx
			local loY, hiY = cy - hy, cy + hy
			local loZ, hiZ = cz - hz, cz + hz
			if loX < wMinX then wMinX = loX end
			if loY < wMinY then wMinY = loY end
			if loZ < wMinZ then wMinZ = loZ end
			if hiX > wMaxX then wMaxX = hiX end
			if hiY > wMaxY then wMaxY = hiY end
			if hiZ > wMaxZ then wMaxZ = hiZ end

			i += 1
		end
	end

	local world = self._world
	world[1] = wMinX; world[2] = wMinY; world[3] = wMinZ
	world[4] = wMaxX; world[5] = wMaxY; world[6] = wMaxZ
end

function DynamicOccupancy.SegmentClear(self, origin: Vector3, disp: Vector3): boolean
	local reader = self._reader
	if reader == nil then
		reader = DynamicOccupancy.Reader(self._shapes, self._xforms, self._bounds, self._world)
		self._reader = reader
	end
	return reader:SegmentClear(origin, disp)
end

function DynamicOccupancy.SegmentFirstHit(self, origin: Vector3, disp: Vector3): number
	local reader = self._reader
	if reader == nil then
		reader = DynamicOccupancy.Reader(self._shapes, self._xforms, self._bounds, self._world)
		self._reader = reader
	end
	return reader:SegmentFirstHit(origin, disp)
end

function DynamicOccupancy.Destroy(self)
	self._shapes  = {}
	self._xforms  = {}
	self._bounds  = {}
	self._world   = {}
	self._objects = {}
	self._active  = {}
	self._reader  = nil
end


local Reader = {}
Reader.__index = Reader

function DynamicOccupancy.Reader(shapes: { [number]: string }, xforms: { [number]: string }, bounds: { [number]: number }, world: { [number]: number })
	local self = setmetatable({}, Reader)
	self._shapeST = shapes
	self._xformST = xforms
	self._boundST = bounds
	self._worldST = world
	self._grids   = {} :: { [number]: any }
	return self
end

function Reader._missesWorld(self, sMinX, sMinY, sMinZ, sMaxX, sMaxY, sMaxZ): boolean
	local w = self._worldST
	local wMinX = w[1]
	if wMinX == nil then return true end
	return sMaxX < wMinX or sMinX > w[4]
		or sMaxY < w[2] or sMinY > w[5]
		or sMaxZ < w[3] or sMinZ > w[6]
end

function Reader._grid(self, id: number)
	local g = self._grids[id]
	if g == nil then
		local blob = self._shapeST[id]
		if not blob then return nil end
		g = (deserializeShape(blob))
		self._grids[id] = g
	end
	return g
end

function Reader.SegmentClear(self, origin: Vector3, disp: Vector3): boolean
	local xformST = self._xformST
	local ox, oy, oz = origin.X, origin.Y, origin.Z
	local ex, ey, ez = ox + disp.X, oy + disp.Y, oz + disp.Z

	local sMinX = ox < ex and ox or ex; local sMaxX = ox > ex and ox or ex
	local sMinY = oy < ey and oy or ey; local sMaxY = oy > ey and oy or ey
	local sMinZ = oz < ez and oz or ez; local sMaxZ = oz > ez and oz or ez

	if self:_missesWorld(sMinX, sMinY, sMinZ, sMaxX, sMaxY, sMaxZ) then
		return true
	end

	local boundST = self._boundST

	for id, blob in xformST do
		local b = id * 6
		local cx, cy, cz = boundST[b - 5], boundST[b - 4], boundST[b - 3]
		if cx == nil then continue end
		local hx, hy, hz = boundST[b - 2], boundST[b - 1], boundST[b]
		if sMaxX < cx - hx or sMinX > cx + hx
			or sMaxY < cy - hy or sMinY > cy + hy
			or sMaxZ < cz - hz or sMinZ > cz + hz then
			continue
		end

		local xb = buffer.fromstring(blob)

		local scx, scy, scz = buffer.readf32(xb, 48), buffer.readf32(xb, 52), buffer.readf32(xb, 56)
		if scx < MIN_SCALE or scy < MIN_SCALE or scz < MIN_SCALE then
			return false
		end

		local grid = self:_grid(id)
		if grid == nil then
			return false
		end

		local ipx, ipy, ipz = buffer.readf32(xb, 0), buffer.readf32(xb, 4), buffer.readf32(xb, 8)
		local ir0, ir1, ir2 = buffer.readf32(xb, 12), buffer.readf32(xb, 16), buffer.readf32(xb, 20)
		local iu0, iu1, iu2 = buffer.readf32(xb, 24), buffer.readf32(xb, 28), buffer.readf32(xb, 32)
		local ib0, ib1, ib2 = buffer.readf32(xb, 36), buffer.readf32(xb, 40), buffer.readf32(xb, 44)

		local lox = (ir0 * ox + ir1 * oy + ir2 * oz + ipx) / scx
		local loy = (iu0 * ox + iu1 * oy + iu2 * oz + ipy) / scy
		local loz = (ib0 * ox + ib1 * oy + ib2 * oz + ipz) / scz
		local lex = (ir0 * ex + ir1 * ey + ir2 * ez + ipx) / scx
		local ley = (iu0 * ex + iu1 * ey + iu2 * ez + ipy) / scy
		local lez = (ib0 * ex + ib1 * ey + ib2 * ez + ipz) / scz

		if not grid:SegmentClearLocal(lox, loy, loz, lex - lox, ley - loy, lez - loz) then
			return false
		end
	end

	return true
end

function Reader.SegmentFirstHit(self, origin: Vector3, disp: Vector3): number
	local xformST = self._xformST
	local ox, oy, oz = origin.X, origin.Y, origin.Z
	local ex, ey, ez = ox + disp.X, oy + disp.Y, oz + disp.Z

	local sMinX = ox < ex and ox or ex; local sMaxX = ox > ex and ox or ex
	local sMinY = oy < ey and oy or ey; local sMaxY = oy > ey and oy or ey
	local sMinZ = oz < ez and oz or ez; local sMaxZ = oz > ez and oz or ez

	if self:_missesWorld(sMinX, sMinY, sMinZ, sMaxX, sMaxY, sMaxZ) then
		return math.huge
	end

	local boundST = self._boundST

	local BestT = math.huge
	for id, blob in xformST do
		local b = id * 6
		local cx, cy, cz = boundST[b - 5], boundST[b - 4], boundST[b - 3]
		if cx == nil then continue end
		local hx, hy, hz = boundST[b - 2], boundST[b - 1], boundST[b]
		if sMaxX < cx - hx or sMinX > cx + hx
			or sMaxY < cy - hy or sMinY > cy + hy
			or sMaxZ < cz - hz or sMinZ > cz + hz then
			continue
		end

		local xb = buffer.fromstring(blob)

		local scx, scy, scz = buffer.readf32(xb, 48), buffer.readf32(xb, 52), buffer.readf32(xb, 56)
		if scx < MIN_SCALE or scy < MIN_SCALE or scz < MIN_SCALE then
			return 0
		end

		local grid = self:_grid(id)
		if grid == nil then
			return 0
		end

		local ipx, ipy, ipz = buffer.readf32(xb, 0), buffer.readf32(xb, 4), buffer.readf32(xb, 8)
		local ir0, ir1, ir2 = buffer.readf32(xb, 12), buffer.readf32(xb, 16), buffer.readf32(xb, 20)
		local iu0, iu1, iu2 = buffer.readf32(xb, 24), buffer.readf32(xb, 28), buffer.readf32(xb, 32)
		local ib0, ib1, ib2 = buffer.readf32(xb, 36), buffer.readf32(xb, 40), buffer.readf32(xb, 44)

		local lox = (ir0 * ox + ir1 * oy + ir2 * oz + ipx) / scx
		local loy = (iu0 * ox + iu1 * oy + iu2 * oz + ipy) / scy
		local loz = (ib0 * ox + ib1 * oy + ib2 * oz + ipz) / scz
		local lex = (ir0 * ex + ir1 * ey + ir2 * ez + ipx) / scx
		local ley = (iu0 * ex + iu1 * ey + iu2 * ez + ipy) / scy
		local lez = (ib0 * ex + ib1 * ey + ib2 * ez + ipz) / scz

		local t = grid:SegmentFirstHitLocal(lox, loy, loz, lex - lox, ley - loy, lez - loz)
		if t < BestT then
			BestT = t
			if BestT <= 0 then return 0 end
		end
	end

	return BestT
end

return DynamicOccupancy
