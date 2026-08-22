--!native
--!optimize 2

local StaticOccupancy = {}
StaticOccupancy.__index = StaticOccupancy
StaticOccupancy.__occType = "static"

local S  = 131072
local S2 = S * S
local O  = 65536

local floor = math.floor

local function packKey(vx: number, vy: number, vz: number): number
	return (vx + O) + (vy + O) * S + (vz + O) * S2
end


local buffer_readf64  = buffer.readf64
local buffer_writef64 = buffer.writef64

local EMPTY = -1

local INV_S = 1 / S
local function hashKey(k: number, slots: number): number
	local ux = k % S
	local r  = (k - ux) * INV_S
	local uy = r % S
	local uz = (r - uy) * INV_S
	return (ux * 73856093 + uy * 19349663 + uz * 83492791) % slots
end

local function nextPow2(n: number): number
	local p = 1
	while p < n do p *= 2 end
	return p
end

local function buildKeyBuffer(keyIter: () -> number?, count: number): (buffer, number)
	local slots = math.max(8, nextPow2(count * 2))
	local buf   = buffer.create(slots * 8)
	for i = 0, slots - 1 do
		buffer_writef64(buf, i * 8, EMPTY)
	end
	local inserted = 0
	for k in keyIter do
		local h = hashKey(k, slots)
		local probes = 0
		while buffer_readf64(buf, h * 8) ~= EMPTY do
			if buffer_readf64(buf, h * 8) == k then h = -1; break end
			h = (h + 1) % slots
			probes += 1
			if probes >= slots then
				error("StaticOccupancy buffer set full — count/keys mismatch")
			end
		end
		if h >= 0 then
			buffer_writef64(buf, h * 8, k)
			inserted += 1
		end
	end
	return buf, slots
end

local function bufContains(buf: buffer, slots: number, k: number): boolean
	local h = hashKey(k, slots)
	for _ = 1, slots do
		local slot = buffer_readf64(buf, h * 8)
		if slot == k then return true end
		if slot == EMPTY then return false end
		h = (h + 1) % slots
	end
	return false
end

local BAKE_MAGIC   = 0x4C584F56
local BAKE_VERSION = 1
local HEADER       = 40


function StaticOccupancy.new(voxelSize: number?)
	local vs = voxelSize or 4
	assert(vs > 0, "StaticOccupancy.new: voxelSize must be > 0")
	local self = setmetatable({}, StaticOccupancy)
	self.voxelSize = vs
	self.voxelInv  = 1 / vs
	self.set       = {} :: { [number]: boolean }
	self.count     = 0
	self._keyBuf   = nil :: buffer?
	self._keySlots = 0
	self.minVX, self.minVY, self.minVZ =  math.huge,  math.huge,  math.huge
	self.maxVX, self.maxVY, self.maxVZ = -math.huge, -math.huge, -math.huge
	return self
end


function StaticOccupancy.Mark(self, vx: number, vy: number, vz: number)
	local k = packKey(vx, vy, vz)
	if not self.set[k] then
		self.set[k] = true
		self.count += 1
	end
	if vx < self.minVX then self.minVX = vx end
	if vy < self.minVY then self.minVY = vy end
	if vz < self.minVZ then self.minVZ = vz end
	if vx > self.maxVX then self.maxVX = vx end
	if vy > self.maxVY then self.maxVY = vy end
	if vz > self.maxVZ then self.maxVZ = vz end
end

function StaticOccupancy.MarkKey(self, k: number)
	if not self.set[k] then
		self.set[k] = true
		self.count += 1
	end
end

function StaticOccupancy.IsOccupied(self, vx: number, vy: number, vz: number): boolean
	local k = packKey(vx, vy, vz)
	if self._keyBuf then
		return bufContains(self._keyBuf, self._keySlots, k)
	end
	return self.set[k] == true
end

function StaticOccupancy.WorldToVoxel(self, p: Vector3): (number, number, number)
	local inv = self.voxelInv
	return floor(p.X * inv), floor(p.Y * inv), floor(p.Z * inv)
end

function StaticOccupancy.RecomputeBounds(self)
	local minVX, minVY, minVZ =  math.huge,  math.huge,  math.huge
	local maxVX, maxVY, maxVZ = -math.huge, -math.huge, -math.huge
	for k in self.set do
		local rz = floor(k / S2)
		local rem = k - rz * S2
		local ry = floor(rem / S)
		local rx = rem - ry * S
		local vx, vy, vz = rx - O, ry - O, rz - O
		if vx < minVX then minVX = vx end
		if vy < minVY then minVY = vy end
		if vz < minVZ then minVZ = vz end
		if vx > maxVX then maxVX = vx end
		if vy > maxVY then maxVY = vy end
		if vz > maxVZ then maxVZ = vz end
	end
	self.minVX, self.minVY, self.minVZ = minVX, minVY, minVZ
	self.maxVX, self.maxVY, self.maxVZ = maxVX, maxVY, maxVZ
end

local function marchClear(
	set: { [number]: boolean }?, keyBuf: buffer?, keySlots: number,
	vs: number, inv: number,
	ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number
): boolean
	local vx = floor(ox * inv)
	local vy = floor(oy * inv)
	local vz = floor(oz * inv)
	local evx = floor((ox + dx) * inv)
	local evy = floor((oy + dy) * inv)
	local evz = floor((oz + dz) * inv)

	local sMinX = vx < evx and vx or evx
	local sMaxX = vx > evx and vx or evx
	local sMinY = vy < evy and vy or evy
	local sMaxY = vy > evy and vy or evy
	local sMinZ = vz < evz and vz or evz
	local sMaxZ = vz > evz and vz or evz

	local d = vx + vy + vz + evx + evy + evz
	if d - d ~= 0 then
		return false
	end

	if keyBuf then
		if bufContains(keyBuf, keySlots, (vx + O) + (vy + O) * S + (vz + O) * S2) then
			return false
		end
	elseif set and set[(vx + O) + (vy + O) * S + (vz + O) * S2] then
		return false
	end

	local stepX, tMaxX, tDeltaX
	if dx > 0 then
		stepX   = 1
		tDeltaX = vs / dx
		tMaxX   = ((vx + 1) * vs - ox) / dx
	elseif dx < 0 then
		stepX   = -1
		tDeltaX = -vs / dx
		tMaxX   = (vx * vs - ox) / dx
	else
		stepX   = 0
		tDeltaX = math.huge
		tMaxX   = math.huge
	end

	local stepY, tMaxY, tDeltaY
	if dy > 0 then
		stepY   = 1
		tDeltaY = vs / dy
		tMaxY   = ((vy + 1) * vs - oy) / dy
	elseif dy < 0 then
		stepY   = -1
		tDeltaY = -vs / dy
		tMaxY   = (vy * vs - oy) / dy
	else
		stepY   = 0
		tDeltaY = math.huge
		tMaxY   = math.huge
	end

	local stepZ, tMaxZ, tDeltaZ
	if dz > 0 then
		stepZ   = 1
		tDeltaZ = vs / dz
		tMaxZ   = ((vz + 1) * vs - oz) / dz
	elseif dz < 0 then
		stepZ   = -1
		tDeltaZ = -vs / dz
		tMaxZ   = (vz * vs - oz) / dz
	else
		stepZ   = 0
		tDeltaZ = math.huge
		tMaxZ   = math.huge
	end

	local MaxSteps = (sMaxX - sMinX) + (sMaxY - sMinY) + (sMaxZ - sMinZ) + 3
	if not (MaxSteps <= 4096) then
		return false
	end
	for _ = 1, MaxSteps do
		if tMaxX < tMaxY then
			if tMaxX < tMaxZ then
				if tMaxX > 1 then return true end
				vx += stepX
				tMaxX += tDeltaX
			else
				if tMaxZ > 1 then return true end
				vz += stepZ
				tMaxZ += tDeltaZ
			end
		else
			if tMaxY < tMaxZ then
				if tMaxY > 1 then return true end
				vy += stepY
				tMaxY += tDeltaY
			else
				if tMaxZ > 1 then return true end
				vz += stepZ
				tMaxZ += tDeltaZ
			end
		end

		local k = (vx + O) + (vy + O) * S + (vz + O) * S2
		if keyBuf then
			if bufContains(keyBuf, keySlots, k) then return false end
		elseif set and set[k] then
			return false
		end
	end

	return false
end

function StaticOccupancy.SegmentClear(self, origin: Vector3, disp: Vector3): boolean
	local inv = self.voxelInv
	local ox, oy, oz = origin.X, origin.Y, origin.Z
	local dx, dy, dz = disp.X, disp.Y, disp.Z

	local vx  = floor(ox * inv);        local vy  = floor(oy * inv);        local vz  = floor(oz * inv)
	local evx = floor((ox + dx) * inv); local evy = floor((oy + dy) * inv); local evz = floor((oz + dz) * inv)
	local sMinX = vx < evx and vx or evx
	local sMaxX = vx > evx and vx or evx
	local sMinY = vy < evy and vy or evy
	local sMaxY = vy > evy and vy or evy
	local sMinZ = vz < evz and vz or evz
	local sMaxZ = vz > evz and vz or evz
	if sMaxX < self.minVX or sMinX > self.maxVX
		or sMaxY < self.minVY or sMinY > self.maxVY
		or sMaxZ < self.minVZ or sMinZ > self.maxVZ then


		return true
	end

	return marchClear(
		self.set, self._keyBuf, self._keySlots,
		self.voxelSize, inv,
		ox, oy, oz, dx, dy, dz
	)
end

local function marchFirstHit(
	set: { [number]: boolean }?, keyBuf: buffer?, keySlots: number,
	vs: number, inv: number,
	ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number
): number
	local vx = floor(ox * inv)
	local vy = floor(oy * inv)
	local vz = floor(oz * inv)
	local evx = floor((ox + dx) * inv)
	local evy = floor((oy + dy) * inv)
	local evz = floor((oz + dz) * inv)

	local sMinX = vx < evx and vx or evx
	local sMaxX = vx > evx and vx or evx
	local sMinY = vy < evy and vy or evy
	local sMaxY = vy > evy and vy or evy
	local sMinZ = vz < evz and vz or evz
	local sMaxZ = vz > evz and vz or evz

	local d = vx + vy + vz + evx + evy + evz
	if d - d ~= 0 then
		return 0
	end

	if keyBuf then
		if bufContains(keyBuf, keySlots, (vx + O) + (vy + O) * S + (vz + O) * S2) then
			return 0
		end
	elseif set and set[(vx + O) + (vy + O) * S + (vz + O) * S2] then
		return 0
	end

	local stepX, tMaxX, tDeltaX
	if dx > 0 then
		stepX   = 1
		tDeltaX = vs / dx
		tMaxX   = ((vx + 1) * vs - ox) / dx
	elseif dx < 0 then
		stepX   = -1
		tDeltaX = -vs / dx
		tMaxX   = (vx * vs - ox) / dx
	else
		stepX   = 0
		tDeltaX = math.huge
		tMaxX   = math.huge
	end

	local stepY, tMaxY, tDeltaY
	if dy > 0 then
		stepY   = 1
		tDeltaY = vs / dy
		tMaxY   = ((vy + 1) * vs - oy) / dy
	elseif dy < 0 then
		stepY   = -1
		tDeltaY = -vs / dy
		tMaxY   = (vy * vs - oy) / dy
	else
		stepY   = 0
		tDeltaY = math.huge
		tMaxY   = math.huge
	end

	local stepZ, tMaxZ, tDeltaZ
	if dz > 0 then
		stepZ   = 1
		tDeltaZ = vs / dz
		tMaxZ   = ((vz + 1) * vs - oz) / dz
	elseif dz < 0 then
		stepZ   = -1
		tDeltaZ = -vs / dz
		tMaxZ   = (vz * vs - oz) / dz
	else
		stepZ   = 0
		tDeltaZ = math.huge
		tMaxZ   = math.huge
	end

	local MaxSteps = (sMaxX - sMinX) + (sMaxY - sMinY) + (sMaxZ - sMinZ) + 3
	if not (MaxSteps <= 4096) then
		return 0
	end
	for _ = 1, MaxSteps do
		local EnterT
		if tMaxX < tMaxY then
			if tMaxX < tMaxZ then
				if tMaxX > 1 then return math.huge end
				EnterT = tMaxX
				vx += stepX
				tMaxX += tDeltaX
			else
				if tMaxZ > 1 then return math.huge end
				EnterT = tMaxZ
				vz += stepZ
				tMaxZ += tDeltaZ
			end
		else
			if tMaxY < tMaxZ then
				if tMaxY > 1 then return math.huge end
				EnterT = tMaxY
				vy += stepY
				tMaxY += tDeltaY
			else
				if tMaxZ > 1 then return math.huge end
				EnterT = tMaxZ
				vz += stepZ
				tMaxZ += tDeltaZ
			end
		end

		local k = (vx + O) + (vy + O) * S + (vz + O) * S2
		if keyBuf then
			if bufContains(keyBuf, keySlots, k) then return EnterT end
		elseif set and set[k] then
			return EnterT
		end
	end

	return math.huge
end

StaticOccupancy._marchClear    = marchClear
StaticOccupancy._marchFirstHit = marchFirstHit

function StaticOccupancy.FinalizeToBuffer(self)
	self:RecomputeBounds()
	if self.count > 0 then
		local keys, n = {}, 0
		for key in self.set do
			n += 1
			keys[n] = key
		end
		local i = 0
		local iter = function(): number?
			i += 1
			return keys[i]
		end
		self._keyBuf, self._keySlots = buildKeyBuffer(iter, self.count)
	end
	self.set = {}
	return self
end

function StaticOccupancy.DilateOneVoxel(self)
	local original = {}
	local n = 0
	for key in self.set do
		n += 1
		original[n] = key
	end
	for i = 1, n do
		local key = original[i]
		local rz  = floor(key / S2)
		local rem = key - rz * S2
		local ry  = floor(rem / S)
		local rx  = rem - ry * S
		local vx, vy, vz = rx - O, ry - O, rz - O
		self:Mark(vx - 1, vy, vz); self:Mark(vx + 1, vy, vz)
		self:Mark(vx, vy - 1, vz); self:Mark(vx, vy + 1, vz)
		self:Mark(vx, vy, vz - 1); self:Mark(vx, vy, vz + 1)
	end
end

function StaticOccupancy.SegmentClearLocal(self, ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number): boolean
	return marchClear(
		self.set, self._keyBuf, self._keySlots,
		self.voxelSize, self.voxelInv,
		ox, oy, oz, dx, dy, dz
	)
end

function StaticOccupancy.SegmentFirstHit(self, origin: Vector3, disp: Vector3): number
	local inv = self.voxelInv
	local ox, oy, oz = origin.X, origin.Y, origin.Z
	local dx, dy, dz = disp.X, disp.Y, disp.Z

	local vx  = floor(ox * inv);        local vy  = floor(oy * inv);        local vz  = floor(oz * inv)
	local evx = floor((ox + dx) * inv); local evy = floor((oy + dy) * inv); local evz = floor((oz + dz) * inv)
	local sMinX = vx < evx and vx or evx
	local sMaxX = vx > evx and vx or evx
	local sMinY = vy < evy and vy or evy
	local sMaxY = vy > evy and vy or evy
	local sMinZ = vz < evz and vz or evz
	local sMaxZ = vz > evz and vz or evz
	if sMaxX < self.minVX or sMinX > self.maxVX
		or sMaxY < self.minVY or sMinY > self.maxVY
		or sMaxZ < self.minVZ or sMinZ > self.maxVZ then

		return math.huge
	end

	return marchFirstHit(
		self.set, self._keyBuf, self._keySlots,
		self.voxelSize, inv,
		ox, oy, oz, dx, dy, dz
	)
end

function StaticOccupancy.SegmentFirstHitLocal(self, ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number): number
	return marchFirstHit(
		self.set, self._keyBuf, self._keySlots,
		self.voxelSize, self.voxelInv,
		ox, oy, oz, dx, dy, dz
	)
end


function StaticOccupancy.Serialize(self): string
	local count = self.count
	local total = HEADER + count * 12
	local b = buffer.create(total)

	buffer.writeu32(b, 0, BAKE_MAGIC)
	buffer.writeu16(b, 4, BAKE_VERSION)
	buffer.writeu16(b, 6, 0)
	buffer.writef32(b, 8, self.voxelSize)
	buffer.writeu32(b, 12, count)
	buffer.writei32(b, 16, self.minVX == math.huge  and 0 or self.minVX)
	buffer.writei32(b, 20, self.minVY == math.huge  and 0 or self.minVY)
	buffer.writei32(b, 24, self.minVZ == math.huge  and 0 or self.minVZ)
	buffer.writei32(b, 28, self.maxVX == -math.huge and 0 or self.maxVX)
	buffer.writei32(b, 32, self.maxVY == -math.huge and 0 or self.maxVY)
	buffer.writei32(b, 36, self.maxVZ == -math.huge and 0 or self.maxVZ)

	local o = HEADER
	for k in self.set do
		local rz  = floor(k / S2)
		local rem = k - rz * S2
		local ry  = floor(rem / S)
		local rx  = rem - ry * S
		buffer.writei32(b, o,     rx - O)
		buffer.writei32(b, o + 4, ry - O)
		buffer.writei32(b, o + 8, rz - O)
		o += 12
	end

	return buffer.readstring(b, 0, total)
end

function StaticOccupancy.Deserialize(blob: string)
	local b = buffer.fromstring(blob)
	assert(buffer.readu32(b, 0) == BAKE_MAGIC, "StaticOccupancy.Deserialize: bad magic (not a Vetra occupancy bake)")

	local voxelSize = buffer.readf32(b, 8)
	local grid = StaticOccupancy.new(voxelSize)

	local count = buffer.readu32(b, 12)
	grid.minVX = buffer.readi32(b, 16)
	grid.minVY = buffer.readi32(b, 20)
	grid.minVZ = buffer.readi32(b, 24)
	grid.maxVX = buffer.readi32(b, 28)
	grid.maxVY = buffer.readi32(b, 32)
	grid.maxVZ = buffer.readi32(b, 36)

	grid.count = count

	if count > 0 then
		local o = HEADER
		local iter = function(): number?
			if o >= HEADER + count * 12 then return nil end
			local vx = buffer.readi32(b, o)
			local vy = buffer.readi32(b, o + 4)
			local vz = buffer.readi32(b, o + 8)
			o += 12
			return (vx + O) + (vy + O) * S + (vz + O) * S2
		end
		grid._keyBuf, grid._keySlots = buildKeyBuffer(iter, count)
	else
		grid.minVX, grid.minVY, grid.minVZ =  math.huge,  math.huge,  math.huge
		grid.maxVX, grid.maxVY, grid.maxVZ = -math.huge, -math.huge, -math.huge
	end

	return grid
end

StaticOccupancy.packKey = packKey

export type StaticOccupancy = typeof(StaticOccupancy.new(4))

return StaticOccupancy
