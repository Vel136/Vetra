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

	-- The shape blob is new, and only a full push sends shapes. See _fullResync
	-- in Unregister.
	self._fullResync = true
	return id
end

function DynamicOccupancy.Unregister(self, id: number)
	-- Invalidate reader indexes: they are built from the bounds table and would
	-- otherwise keep handing out this id until the next UpdateTransforms. Readers
	-- also skip ids whose xform has gone, so a stale index is safe either way --
	-- this just stops it being stale for a whole frame.
	local world = self._world
	world[7] = (world[7] or 0) + 1

	-- Force the next parallel push to re-send the whole registry. A removed id
	-- never appears in the dirty list, so an incremental push would leave the
	-- worker-side SharedTables holding a part that no longer exists.
	self._fullResync = true

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

	-- Cheap pre-pass: has anything actually changed? A registered set that is
	-- momentarily still is the common case (parts idle between bursts of motion),
	-- and answering it here costs two property reads per part instead of the six
	-- bounds reads and the world-AABB fold the full pass would run.
	--
	-- Correctness note: this must be a SEPARATE pass, not an early `continue`
	-- inside the main loop. The world AABB is a fold over every part, so skipping
	-- unchanged parts partway through would fold only the tail of the list.
	local active  = self._active
	local objects = self._objects
	local anyDirty = false
	for j = 1, #active do
		local id  = active[j]
		local obj = objects[id]
		if obj == nil or obj.part.Parent == nil then
			anyDirty = true
			break
		end
		local part = obj.part
		if obj.lastCF ~= part.CFrame or obj.lastSize ~= part.Size or bounds[id * 6 - 5] == nil then
			anyDirty = true
			break
		end
	end

	if not anyDirty then
		-- Bounds, world AABB and version stamp all still describe reality. Clear
		-- the dirty list too: leaving last frame's ids there would have the
		-- parallel push re-send transforms that have not changed since.
		self._dirtyCount = 0
		return
	end

	local wMinX, wMinY, wMinZ = math.huge, math.huge, math.huge
	local wMaxX, wMaxY, wMaxZ = -math.huge, -math.huge, -math.huge

	local moved = false

	-- Ids repacked this pass. The parallel Coordinator reads this to push only what
	-- changed instead of re-sending every active id every frame; a scene where a
	-- handful of parts move otherwise pays a full marshal of the whole registry.
	local dirtyIds = self._dirtyIds
	if dirtyIds == nil then
		dirtyIds = {}
		self._dirtyIds = dirtyIds
	else
		table.clear(dirtyIds)
	end
	local dirtyCount = 0

	local i = 1
	while i <= #self._active do
		local id  = self._active[i]
		local obj = self._objects[id]
		if not obj or not obj.part.Parent then
			self:Unregister(id)
		else
			local part = obj.part
			local cf, size = part.CFrame, part.Size

			-- Repack only what actually moved. "Dynamic" rarely means "every part
			-- every frame": a scene of 2500 registered parts with a few dozen in
			-- motion paid full repack cost for all 2500 before this check. Measured
			-- on an orbiting field, 97.9% of parts hold their grid cell per frame.
			local b = id * 6
			local cx, cy, cz, hx, hy, hz
			local unchanged = obj.lastCF == cf and obj.lastSize == size and bounds[b - 5] ~= nil
			if unchanged then
				cx = bounds[b - 5]; cy = bounds[b - 4]; cz = bounds[b - 3]
				hx = bounds[b - 2]; hy = bounds[b - 1]; hz = bounds[b]
			else
				local buf
				buf, cx, cy, cz, hx, hy, hz = packXform(part, obj.bakeSize)
				self._xforms[id] = buffer.tostring(buf)
				obj.lastCF   = cf
				obj.lastSize = size
				bounds[b - 5] = cx; bounds[b - 4] = cy; bounds[b - 3] = cz
				bounds[b - 2] = hx; bounds[b - 1] = hy; bounds[b]     = hz
				moved = true
				dirtyCount += 1
				dirtyIds[dirtyCount] = id
			end

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

	self._dirtyCount = dirtyCount

	if not moved then
		-- Nothing changed: leave the stamp alone so readers keep their index.
		return
	end

	-- Version stamp. Readers key their broadphase index off this and rebuild when
	-- it moves. It lives in the world table because that is one of the four
	-- structures marshaled to the parallel workers -- a Reader built worker-side
	-- from SharedTables has no other way to notice that transforms changed.
	world[7] = (world[7] or 0) + 1
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

	-- Broadphase index over registered parts, keyed by cell hash. Without it a
	-- query is O(registered parts): the world AABB is the only other filter, and
	-- it stops discriminating the moment a query is inside the field, which is
	-- exactly when the grid is supposed to earn its keep.
	self._cells    = nil :: any
	self._cellSize = 0
	self._indexVer = -1
	-- Per-id cell ranges from the last build, so a rebuild can touch only the
	-- parts whose range actually moved. _spanCell guards against reusing spans
	-- that were computed against a different cell width.
	self._spans    = nil :: any
	self._spanCell = 0

	-- Decoded transform buffers, keyed by id. Transforms are stored as STRINGS
	-- because SharedTable rejects buffers outright ("buffers can not be stored in
	-- a SharedTable"), so the parallel path forces the encoding. Without this
	-- cache every query pays buffer.fromstring per candidate part -- measured at
	-- ~98ns, by far the largest single cost in the query loop.
	self._xbuf    = {} :: { [number]: buffer }
	self._xbufVer = -1

	-- Query-scoped dedup (Amanatides & Woo 1987, "Avoiding Multiple
	-- Intersections"). Each query takes the next id; a part records the last id
	-- that tested it. Matching ids mean "already examined this query", which
	-- replaces a set that would otherwise need clearing every call.
	--
	-- The counter only ever increases, so a stored id can never equal a future
	-- one and no stale entry can wrongly suppress a part. Luau numbers are
	-- doubles: integers stay exact to 2^53, which at a million queries a second
	-- is ~285 years, so the counter is treated as non-wrapping.
	self._queryId   = 0
	self._lastQuery = {} :: { [number]: number }
	return self
end

-- Cell size is derived from the mean part extent, not fixed: too small and a big
-- part is inserted into thousands of cells, too large and every query pulls in
-- everything. One mean-sized part then spans a handful of cells.
local MIN_CELL = 4

function Reader._buildIndex(self)
	local boundST = self._boundST
	local xformST = self._xformST

	-- Cell size is measured once and kept. Recomputing the mean extent every
	-- rebuild costs a full pass over the registry to produce a number that barely
	-- moves -- parts change position far more often than they change size.
	local cellSize = self._cellSize
	if cellSize <= 0 then
		local sumExtent, count = 0, 0
		for id in xformST do
			local b = id * 6
			local hx = boundST[b - 2]
			if hx ~= nil then
				sumExtent += hx + boundST[b - 1] + boundST[b]
				count += 1
			end
		end

		if count == 0 then
			self._cells    = {}
			self._cellSize = 0   -- stay unmeasured; remeasure once parts exist
			return
		end

		-- mean half-extent across all three axes, doubled to a full width
		cellSize = (sumExtent / (count * 3)) * 2
		if cellSize < MIN_CELL then cellSize = MIN_CELL end
	end

	local inv = 1 / cellSize

	-- Incremental path. Measured on an orbiting field, 97.9% of parts occupy the
	-- same cells from one frame to the next, so a full rebuild spends nearly all
	-- of its time recomputing identical assignments. When a previous span is on
	-- record, touch only the parts whose cell range actually changed.
	local cells = self._cells
	local spans = self._spans
	if cells ~= nil and spans ~= nil and self._spanCell == cellSize then
		local boundST2 = boundST
		for id in xformST do
			local b = id * 6
			local cx = boundST2[b - 5]
			local prev = spans[id]
			if cx == nil then
				if prev ~= nil then
					self:_removeSpan(id, prev, cells)
					spans[id] = nil
				end
			else
				local cy, cz = boundST2[b - 4], boundST2[b - 3]
				local hx, hy, hz = boundST2[b - 2], boundST2[b - 1], boundST2[b]
				local gx0, gx1 = floor((cx - hx) * inv), floor((cx + hx) * inv)
				local gy0, gy1 = floor((cy - hy) * inv), floor((cy + hy) * inv)
				local gz0, gz1 = floor((cz - hz) * inv), floor((cz + hz) * inv)

				if prev == nil then
					self:_insertSpan(id, gx0, gx1, gy0, gy1, gz0, gz1, cells)
					spans[id] = { gx0, gx1, gy0, gy1, gz0, gz1 }
				elseif prev[1] ~= gx0 or prev[2] ~= gx1 or prev[3] ~= gy0
					or prev[4] ~= gy1 or prev[5] ~= gz0 or prev[6] ~= gz1 then
					self:_removeSpan(id, prev, cells)
					self:_insertSpan(id, gx0, gx1, gy0, gy1, gz0, gz1, cells)
					prev[1], prev[2], prev[3] = gx0, gx1, gy0
					prev[4], prev[5], prev[6] = gy1, gz0, gz1
				end
			end
		end

		-- Drop spans for ids that vanished from the registry entirely.
		for id, prev in spans do
			if xformST[id] == nil then
				self:_removeSpan(id, prev, cells)
				spans[id] = nil
			end
		end

		self._cellSize = cellSize
		return
	end

	-- Full build. Reuse the bucket tables: allocating a fresh table per occupied
	-- cell each time is pure GC churn.
	if cells == nil then
		cells = {}
		self._cells = cells
	else
		for _, bucket in cells do
			table.clear(bucket)
		end
	end

	spans = {}
	self._spans    = spans
	self._spanCell = cellSize

	for id in xformST do
		local b = id * 6
		local cx = boundST[b - 5]
		if cx ~= nil then
			local cy, cz = boundST[b - 4], boundST[b - 3]
			local hx, hy, hz = boundST[b - 2], boundST[b - 1], boundST[b]

			local gx0, gx1 = floor((cx - hx) * inv), floor((cx + hx) * inv)
			local gy0, gy1 = floor((cy - hy) * inv), floor((cy + hy) * inv)
			local gz0, gz1 = floor((cz - hz) * inv), floor((cz + hz) * inv)

			self:_insertSpan(id, gx0, gx1, gy0, gy1, gz0, gz1, cells)
			spans[id] = { gx0, gx1, gy0, gy1, gz0, gz1 }
		end
	end

	self._cells    = cells
	self._cellSize = cellSize
end

-- Hash multipliers are Teschner et al.'s large primes, chosen so that
-- neighbouring cells do not collide in a run.
local function cellKey(gx: number, gy: number, gz: number): number
	return gx * 73856093 + gy * 19349663 + gz * 83492791
end

-- DO NOT replace the AABB cell enumeration below with a DDA / Amanatides-Woo
-- segment walk. It was implemented, measured as a large win, and reverted as
-- INCORRECT.
--
-- DDA visits the cells a zero-width line passes through. This index inserts each
-- part into every cell its AABB overlaps. Those are different sets: a part whose
-- box overlaps a cell the centre line never enters is still a legitimate
-- candidate, because the segment can clip the part inside a neighbouring cell.
-- Measured failure: span 6,6,1 -- AABB reached 64 occupied cells, the DDA walk
-- reached 5, and a real blocker sat in the difference. SegmentClear returned
-- "clear" for a segment that was blocked, i.e. bullets through walls.
--
-- Amanatides-Woo is correct when cell membership is built the same way the walk
-- traverses (thin ray vs. per-cell object lists). Making it usable here would
-- need conservative insertion widened by the query's own extent, which costs more
-- on insert than the walk saves on query. The cost of the AABB enumeration is
-- bounded in practice because cell size tracks mean part extent, so a one-frame
-- segment spans very few cells.

function Reader._insertSpan(self, id: number, gx0, gx1, gy0, gy1, gz0, gz1, cells)
	for gx = gx0, gx1 do
		for gy = gy0, gy1 do
			for gz = gz0, gz1 do
				local key = cellKey(gx, gy, gz)
				local bucket = cells[key]
				if bucket == nil then
					cells[key] = { id }
				else
					bucket[#bucket + 1] = id
				end
			end
		end
	end
end

function Reader._removeSpan(self, id: number, span, cells)
	for gx = span[1], span[2] do
		for gy = span[3], span[4] do
			for gz = span[5], span[6] do
				local bucket = cells[cellKey(gx, gy, gz)]
				if bucket ~= nil then
					-- Swap-remove: order within a bucket carries no meaning.
					for k = 1, #bucket do
						if bucket[k] == id then
							bucket[k] = bucket[#bucket]
							bucket[#bucket] = nil
							break
						end
					end
				end
			end
		end
	end
end

-- Returns the index, rebuilding it if UpdateTransforms has run since it was
-- built. Callers must treat the result as read-only.
function Reader._index(self)
	local ver = self._worldST[7] or 0
	if self._cells == nil or self._indexVer ~= ver then
		self:_buildIndex()
		self._indexVer = ver
	end
	if self._xbufVer ~= ver then
		table.clear(self._xbuf)
		self._xbufVer = ver
	end
	-- An empty registry leaves the cell size unmeasured. Callers divide by it, so
	-- hand back a usable width rather than 0 -- the index is empty either way.
	local cellSize = self._cellSize
	return self._cells, cellSize > 0 and cellSize or MIN_CELL
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
	local cells, cellSize = self:_index()
	local inv = 1 / cellSize
	local xbuf = self._xbuf

	local gx0, gx1 = (sMinX * inv) // 1, (sMaxX * inv) // 1
	local gy0, gy1 = (sMinY * inv) // 1, (sMaxY * inv) // 1
	local gz0, gz1 = (sMinZ * inv) // 1, (sMaxZ * inv) // 1

	-- A part straddling a cell border sits in several buckets, so it can surface
	-- more than once per query. A single-cell query cannot, so it skips dedup
	-- entirely -- the common case for a one-frame segment.
	local multiCell = gx0 ~= gx1 or gy0 ~= gy1 or gz0 ~= gz1
	local lastQuery, queryId
	if multiCell then
		lastQuery = self._lastQuery
		queryId = self._queryId + 1
		self._queryId = queryId
	end

	-- Collect the candidate buckets.
	local buckets = self._walk
	if buckets == nil then
		buckets = {}
		self._walk = buckets
	end
	local bucketCount = 0
	for gx = gx0, gx1 do
		for gy = gy0, gy1 do
			for gz = gz0, gz1 do
				-- Buckets are reused across rebuilds, so an emptied cell stays
				-- present as a zero-length table rather than going nil.
				local bucket = cells[gx * 73856093 + gy * 19349663 + gz * 83492791]
				if bucket ~= nil then
					bucketCount += 1
					buckets[bucketCount] = bucket
				end
			end
		end
	end

	for ci = 1, bucketCount do
		local bucket = buckets[ci]

	for bi = 1, #bucket do
		local id = bucket[bi]
		if multiCell then
			if lastQuery[id] == queryId then continue end
			lastQuery[id] = queryId
		end

		local b = id * 6
		local cx, cy, cz = boundST[b - 5], boundST[b - 4], boundST[b - 3]
		if cx == nil then continue end
		local hx, hy, hz = boundST[b - 2], boundST[b - 1], boundST[b]
		if sMaxX < cx - hx or sMinX > cx + hx
			or sMaxY < cy - hy or sMinY > cy + hy
			or sMaxZ < cz - hz or sMinZ > cz + hz then
			continue
		end

		-- Decode once per transform version, not once per query.
		local xb = xbuf[id]
		if xb == nil then
			local blob = xformST[id]
			if blob == nil then continue end
			xb = buffer.fromstring(blob)
			xbuf[id] = xb
		end

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
	local cells, cellSize = self:_index()
	local inv = 1 / cellSize
	local xbuf = self._xbuf

	local gx0, gx1 = (sMinX * inv) // 1, (sMaxX * inv) // 1
	local gy0, gy1 = (sMinY * inv) // 1, (sMaxY * inv) // 1
	local gz0, gz1 = (sMinZ * inv) // 1, (sMaxZ * inv) // 1

	local multiCell = gx0 ~= gx1 or gy0 ~= gy1 or gz0 ~= gz1
	local lastQuery, queryId
	if multiCell then
		lastQuery = self._lastQuery
		queryId = self._queryId + 1
		self._queryId = queryId
	end

	local buckets = self._walk
	if buckets == nil then
		buckets = {}
		self._walk = buckets
	end
	local bucketCount = 0
	for gx = gx0, gx1 do
		for gy = gy0, gy1 do
			for gz = gz0, gz1 do
				local bucket = cells[gx * 73856093 + gy * 19349663 + gz * 83492791]
				if bucket ~= nil then
					bucketCount += 1
					buckets[bucketCount] = bucket
				end
			end
		end
	end

	local BestT = math.huge
	for ci = 1, bucketCount do
		local bucket = buckets[ci]

	for bi = 1, #bucket do
		local id = bucket[bi]
		if multiCell then
			if lastQuery[id] == queryId then continue end
			lastQuery[id] = queryId
		end

		local b = id * 6
		local cx, cy, cz = boundST[b - 5], boundST[b - 4], boundST[b - 3]
		if cx == nil then continue end
		local hx, hy, hz = boundST[b - 2], boundST[b - 1], boundST[b]
		if sMaxX < cx - hx or sMinX > cx + hx
			or sMaxY < cy - hy or sMinY > cy + hy
			or sMaxZ < cz - hz or sMinZ > cz + hz then
			continue
		end

		-- Decode once per transform version, not once per query.
		local xb = xbuf[id]
		if xb == nil then
			local blob = xformST[id]
			if blob == nil then continue end
			xb = buffer.fromstring(blob)
			xbuf[id] = xb
		end

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
	end

	return BestT
end

return DynamicOccupancy
