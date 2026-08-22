--!native
--!optimize 2

local CollectionService = game:GetService("CollectionService")

local Occupancy     = script.Parent
local StaticOccupancy = require(Occupancy.StaticOccupancy)

local VoxelBaker = {}

local UP = Vector3.new(0, 1, 0)

local abs   = math.abs
local floor = math.floor
local min   = math.min
local max   = math.max
local sqrt  = math.sqrt

local YIELD_INTERVAL = 0.008

local DEFAULT_IGNORE_TAGS = { "VetraOccIgnore" }

local function isFallbackPart(part: BasePart): boolean
	if part:IsA("MeshPart") or part:IsA("UnionOperation") then return true end
	if part:IsA("Part") then
		local s = (part :: Part).Shape
		if s == Enum.PartType.CornerWedge then return false end
		if part:FindFirstChildOfClass("SpecialMesh") then return true end
		return false
	end
	if part:IsA("WedgePart") or part:IsA("CornerWedgePart") then return false end
	return true
end


local function aabbVsOBB(cf: CFrame, w1: number, w2: number, w3: number,
	cx: number, cy: number, cz: number, e: number): boolean
	local b1, b2, b3 = cf.XVector, cf.YVector, cf.ZVector
	local p  = cf.Position
	local tx, ty, tz = p.X - cx, p.Y - cy, p.Z - cz

	local r11, r12, r13 = b1.X, b2.X, b3.X
	local r21, r22, r23 = b1.Y, b2.Y, b3.Y
	local r31, r32, r33 = b1.Z, b2.Z, b3.Z
	local a11, a12, a13 = abs(r11) + 1e-6, abs(r12) + 1e-6, abs(r13) + 1e-6
	local a21, a22, a23 = abs(r21) + 1e-6, abs(r22) + 1e-6, abs(r23) + 1e-6
	local a31, a32, a33 = abs(r31) + 1e-6, abs(r32) + 1e-6, abs(r33) + 1e-6

	if abs(tx) > e + w1 * a11 + w2 * a12 + w3 * a13 then return false end
	if abs(ty) > e + w1 * a21 + w2 * a22 + w3 * a23 then return false end
	if abs(tz) > e + w1 * a31 + w2 * a32 + w3 * a33 then return false end

	if abs(tx * r11 + ty * r21 + tz * r31) > w1 + e * (a11 + a21 + a31) then return false end
	if abs(tx * r12 + ty * r22 + tz * r32) > w2 + e * (a12 + a22 + a32) then return false end
	if abs(tx * r13 + ty * r23 + tz * r33) > w3 + e * (a13 + a23 + a33) then return false end

	if abs(tz * r21 - ty * r31) > e * a31 + e * a21 + w2 * a13 + w3 * a12 then return false end
	if abs(tz * r22 - ty * r32) > e * a32 + e * a22 + w1 * a13 + w3 * a11 then return false end
	if abs(tz * r23 - ty * r33) > e * a33 + e * a23 + w1 * a12 + w2 * a11 then return false end
	if abs(tx * r31 - tz * r11) > e * a31 + e * a11 + w2 * a23 + w3 * a22 then return false end
	if abs(tx * r32 - tz * r12) > e * a32 + e * a12 + w1 * a23 + w3 * a21 then return false end
	if abs(tx * r33 - tz * r13) > e * a33 + e * a13 + w1 * a22 + w3 * a21 then return false end
	if abs(ty * r11 - tx * r21) > e * a21 + e * a11 + w2 * a33 + w3 * a32 then return false end
	if abs(ty * r12 - tx * r22) > e * a22 + e * a12 + w1 * a33 + w3 * a31 then return false end
	if abs(ty * r13 - tx * r23) > e * a23 + e * a13 + w1 * a32 + w2 * a31 then return false end
	return true
end

local function ballVsBox(cx: number, cy: number, cz: number, r: number,
	bx: number, by: number, bz: number, e: number): boolean
	local dx = max(abs(bx - cx) - e, 0)
	local dy = max(abs(by - cy) - e, 0)
	local dz = max(abs(bz - cz) - e, 0)
	return dx * dx + dy * dy + dz * dz <= r * r
end

local function boxUnderPlane(nx: number, ny: number, nz: number, d: number,
	bx: number, by: number, bz: number, e: number): boolean
	return (nx * bx + ny * by + nz * bz) - d <= e * (abs(nx) + abs(ny) + abs(nz))
end


local function markPart(grid, part: BasePart, vs: number, voxelInv: number,
	clampMinVX: number, clampMaxVX: number)
	local cf   = part.CFrame
	local size = part.Size
	local p    = cf.Position

	local rv, uv, lv = cf.RightVector, cf.UpVector, cf.LookVector
	local ax = abs(rv.X) * size.X + abs(uv.X) * size.Y + abs(lv.X) * size.Z
	local ay = abs(rv.Y) * size.X + abs(uv.Y) * size.Y + abs(lv.Y) * size.Z
	local az = abs(rv.Z) * size.X + abs(uv.Z) * size.Y + abs(lv.Z) * size.Z
	local minX, maxX = p.X - ax * 0.5, p.X + ax * 0.5
	local minY, maxY = p.Y - ay * 0.5, p.Y + ay * 0.5
	local minZ, maxZ = p.Z - az * 0.5, p.Z + az * 0.5

	local gxMin = max(clampMinVX, floor(minX * voxelInv))
	local gxMax = min(clampMaxVX, floor(maxX * voxelInv))
	local gyMin = floor(minY * voxelInv)
	local gyMax = floor(maxY * voxelInv)
	local gzMin = floor(minZ * voxelInv)
	local gzMax = floor(maxZ * voxelInv)
	if gxMin > gxMax then return end

	local e = vs * 0.5

	local shape = part:IsA("Part") and (part :: Part).Shape or nil
	local isWedge  = part:IsA("WedgePart") or shape == Enum.PartType.Wedge
	local isCorner = part:IsA("CornerWedgePart") or shape == Enum.PartType.CornerWedge
	local isBall   = shape == Enum.PartType.Ball
	local isCyl    = shape == Enum.PartType.Cylinder

	if isFallbackPart(part) then
		for gx = gxMin, gxMax do
			for gy = gyMin, gyMax do
				for gz = gzMin, gzMax do
					grid:Mark(gx, gy, gz)
				end
			end
		end
		return
	end

	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5

	local ballR = 0
	if isBall then
		ballR = 0.5 * min(size.X, size.Y, size.Z)
	end

	local cylAxis, cylR, cylHalfLen
	if isCyl then
		cylAxis    = cf.XVector
		cylR       = 0.5 * min(size.Y, size.Z)
		cylHalfLen = size.X * 0.5
	end

	local wnx, wny, wnz, wd
	if isWedge then
		local n = cf:VectorToWorldSpace(Vector3.new(0, size.Z, -size.Y).Unit)
		wnx, wny, wnz = n.X, n.Y, n.Z
		wd = n.X * p.X + n.Y * p.Y + n.Z * p.Z
	end

	local c1x, c1y, c1z, c1d, c2x, c2y, c2z, c2d
	if isCorner then
		local n1 = cf:VectorToWorldSpace(Vector3.new(-size.Y, size.X, 0).Unit)
		local n2 = cf:VectorToWorldSpace(Vector3.new(0, size.Z, size.Y).Unit)
		c1x, c1y, c1z = n1.X, n1.Y, n1.Z
		c1d = n1.X * p.X + n1.Y * p.Y + n1.Z * p.Z
		c2x, c2y, c2z = n2.X, n2.Y, n2.Z
		c2d = n2.X * p.X + n2.Y * p.Y + n2.Z * p.Z
	end

	for gx = gxMin, gxMax do
		local bx = gx * vs + e
		for gy = gyMin, gyMax do
			local by = gy * vs + e
			for gz = gzMin, gzMax do
				local bz = gz * vs + e

				local solid
				if isBall then
					solid = ballVsBox(p.X, p.Y, p.Z, ballR, bx, by, bz, e)
				elseif isCyl then
					local dxp = bx - p.X
					local dyp = by - p.Y
					local dzp = bz - p.Z
					local s   = dxp * cylAxis.X + dyp * cylAxis.Y + dzp * cylAxis.Z
					if abs(s) <= cylHalfLen + e then
						local px = dxp - s * cylAxis.X
						local py = dyp - s * cylAxis.Y
						local pz = dzp - s * cylAxis.Z
						local rr = cylR + e
						solid = (px * px + py * py + pz * pz) <= rr * rr
					else
						solid = false
					end
				elseif isWedge then
					solid = aabbVsOBB(cf, hx, hy, hz, bx, by, bz, e)
						and boxUnderPlane(wnx, wny, wnz, wd, bx, by, bz, e)
				elseif isCorner then
					solid = aabbVsOBB(cf, hx, hy, hz, bx, by, bz, e)
						and boxUnderPlane(c1x, c1y, c1z, c1d, bx, by, bz, e)
						and boxUnderPlane(c2x, c2y, c2z, c2d, bx, by, bz, e)
				else
					solid = aabbVsOBB(cf, hx, hy, hz, bx, by, bz, e)
				end

				if solid then
					grid:Mark(gx, gy, gz)
				end
			end
		end
	end
end


local function buildOverlapParams(ignoreTags: { string }): OverlapParams
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	local t = {}
	for _, tag in ignoreTags do
		for _, inst in CollectionService:GetTagged(tag) do
			t[#t + 1] = inst
		end
	end
	if #t > 0 then op.FilterDescendantsInstances = t end
	op.MaxParts = 0x7FFFFFFF
	return op
end

function VoxelBaker.BakeRegion(grid, regionCFrame: CFrame, regionSize: Vector3, opts: any?)
	opts = opts or {}
	local vs       = grid.voxelSize
	local voxelInv = grid.voxelInv

	local op = opts.overlapParams or buildOverlapParams(opts.ignoreTags or DEFAULT_IGNORE_TAGS)

	local t0 = os.clock()
	local parts = workspace:GetPartBoundsInBox(regionCFrame, regionSize, op)

	local origin = regionCFrame.Position
	local rMinVX = floor((origin.X - regionSize.X * 0.5) * voxelInv)
	local rMaxVX = floor((origin.X + regionSize.X * 0.5) * voxelInv)

	local clock = os.clock()
	for _, part in parts do
		markPart(grid, part, vs, voxelInv, rMinVX, rMaxVX)
		if os.clock() - clock >= YIELD_INTERVAL then
			task.wait()
			clock = os.clock()
		end
	end

	if opts.Verbose then
		print(string.format("[Vetra Occupancy] Baked %d parts → %d voxels in %.3fs (vs=%g)",
			#parts, grid.count, os.clock() - t0, vs))
	end

	return grid
end

function VoxelBaker.BakeRegionParallel(grid, regionCFrame: CFrame, regionSize: Vector3, numWorkers: number?, opts: any?)
	local Coordinator = require(Occupancy.Coordinator)
	local coord = Coordinator.new(numWorkers or 8)
	local ok = coord:Bake(grid, regionCFrame, regionSize, opts)
	coord:Destroy()
	if not ok then
		warn("[Vetra Occupancy] Parallel bake unavailable — falling back to serial")
		return VoxelBaker.BakeRegion(grid, regionCFrame, regionSize, opts)
	end
	return grid
end

function VoxelBaker.BakeLocal(part: BasePart, voxelSize: number, dilate: boolean?)
	local grid     = StaticOccupancy.new(voxelSize)
	local voxelInv = grid.voxelInv
	local bakeSize = part.Size

	local proxy = part:Clone()
	proxy.CFrame = CFrame.identity
	proxy.Anchored = true

	markPart(grid, proxy, voxelSize, voxelInv, -0x40000000, 0x40000000)
	proxy:Destroy()

	if dilate then
		grid:DilateOneVoxel()
	end
	grid:RecomputeBounds()

	return grid, bakeSize
end

VoxelBaker._markPart          = markPart
VoxelBaker._buildOverlapParams = buildOverlapParams
VoxelBaker._DEFAULT_IGNORE_TAGS = DEFAULT_IGNORE_TAGS
VoxelBaker._YIELD_INTERVAL     = YIELD_INTERVAL

return VoxelBaker
