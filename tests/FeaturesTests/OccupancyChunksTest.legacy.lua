--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — OccupancyChunks round-trip test
--
-- OccupancyChunks exists to get a baked occupancy grid across the one boundary
-- Roblox won't let a blob cross intact: a StringValue can't hold an arbitrarily
-- long string, so a bake is base64'd and split into 180,000-char StringValues
-- under a folder, then reassembled on the far side.
--
-- Everything here is a round-trip assertion — Write then Read, and check what
-- comes back is byte-identical. A grid that survives the trip but comes back
-- subtly wrong is worse than one that fails loudly, so the checks compare the
-- rebuilt grid's actual occupancy, not just its length.
--
-- WHAT'S ACTUALLY AT RISK
--   · The chunk split. #encoded is almost never an exact multiple of CHUNK, so
--     the last chunk is a partial — off-by-one there truncates the blob.
--   · Chunk ORDER. Read sorts by name, and the names are zero-padded ("%06d")
--     precisely so a lexicographic sort matches numeric order. Break the padding
--     and chunk 10 sorts before chunk 2.
--   · Write's cleanup. It destroys existing StringValues first; if it didn't,
--     re-baking into a used folder would interleave old and new chunks.
--   · Binary safety. The blob is packed binary with embedded NULs, not text.
--
-- HOW TO RUN
--   Drop in ServerScriptService with `src` under ReplicatedStorage, press Play,
--   read the console. Non-zero FAIL means a real regression.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StaticOccupancy = require(ReplicatedStorage.src.Occupancy.StaticOccupancy)
local OccupancyChunks = require(ReplicatedStorage.src.Occupancy.OccupancyChunks)

local BAR = string.rep("─", 72)
local CHUNK_SIZE = 180000  -- must match OccupancyChunks.CHUNK

local Passes, Fails = 0, 0
local FailedNames: { string } = {}

local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("    [PASS] %-40s %s", name, detail))
	else
		Fails += 1
		table.insert(FailedNames, name)
		warn(string.format("    [FAIL] %-40s %s", name, detail))
	end
end

local function section(title: string)
	print(BAR)
	print("  " .. title)
	print(BAR)
end

local Scene = Instance.new("Folder")
Scene.Name   = "VetraChunksTestScene"
Scene.Parent = workspace

local function newFolder(name: string): Folder
	local F = Instance.new("Folder")
	F.Name   = name
	F.Parent = Scene
	return F
end

-- Marks a deterministic scatter of voxels. Deterministic matters: the whole test
-- is "does what came back equal what went in", so both sides must agree on what
-- went in without storing it twice.
local function makeGrid(voxelSize: number, n: number)
	local grid = StaticOccupancy.new(voxelSize)
	for i = 1, n do
		grid:Mark(i % 97, (i * 7) % 89, (i * 13) % 83)
	end
	grid:RecomputeBounds()
	return grid
end

-- Compares two grids the way callers actually use them: via IsOccupied.
--
-- Deliberately NOT by comparing `.set`. A freshly Marked grid keeps its voxels in
-- the `set` hash, but Deserialize builds the packed `_keyBuf` instead and leaves
-- `set` empty — IsOccupied reads whichever is present. Comparing `set` directly
-- reports every deserialized grid as "missing every voxel" while IsOccupied says
-- the two are identical, which is the test lying, not the grid.
local function gridsMatch(a, b): (boolean, string)
	if a.count ~= b.count then
		return false, string.format("count %d vs %d", a.count, b.count)
	end
	if math.abs(a.voxelSize - b.voxelSize) > 1e-6 then
		return false, string.format("voxelSize %g vs %g", a.voxelSize, b.voxelSize)
	end
	for _, f in { "minVX", "minVY", "minVZ", "maxVX", "maxVY", "maxVZ" } do
		if a[f] ~= b[f] then
			return false, string.format("%s %s vs %s", f, tostring(a[f]), tostring(b[f]))
		end
	end

	-- Sweep the original's bounds and require both grids to answer identically. The
	-- bounds already matched, so anything b holds outside a's voxels would have to
	-- sit inside those same bounds to go unnoticed — and the count check rules that
	-- out.
	local Probes = 0
	for vx = a.minVX, a.maxVX do
		for vy = a.minVY, a.maxVY do
			for vz = a.minVZ, a.maxVZ do
				Probes += 1
				if a:IsOccupied(vx, vy, vz) ~= b:IsOccupied(vx, vy, vz) then
					return false, string.format("IsOccupied disagrees at voxel (%d,%d,%d)", vx, vy, vz)
				end
			end
		end
	end
	return true, string.format("identical (%d voxels, %d probes)", a.count, Probes)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Round trip, small grid (single chunk)
-- ─────────────────────────────────────────────────────────────────────────────
local function testSmall()
	section("1. Round trip — small grid (fits in one chunk)")

	local Original = makeGrid(4, 200)
	local Blob     = Original:Serialize()
	local Folder   = newFolder("Small")

	OccupancyChunks.Write(Folder, Blob)
	local ReadBack = OccupancyChunks.Read(Folder)

	check("Read returns a blob", ReadBack ~= nil, ReadBack and (#ReadBack .. " bytes") or "nil")
	check("blob is byte-identical", ReadBack == Blob,
		string.format("in=%d out=%d", #Blob, ReadBack and #ReadBack or -1))

	if ReadBack then
		local Rebuilt = StaticOccupancy.Deserialize(ReadBack)
		local Same, Why = gridsMatch(Original, Rebuilt)
		check("grid survives the round trip", Same, Why)
	end

	local Count = Folder:GetAttribute("ChunkCount")
	check("ChunkCount attribute set", Count == 1, "ChunkCount=" .. tostring(Count))
	check("ByteLength matches blob", Folder:GetAttribute("ByteLength") == #Blob,
		string.format("attr=%s actual=%d", tostring(Folder:GetAttribute("ByteLength")), #Blob))
	check("Version defaults to 1", Folder:GetAttribute("Version") == 1,
		"Version=" .. tostring(Folder:GetAttribute("Version")))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Multi-chunk — the split is the whole point of this module
-- ─────────────────────────────────────────────────────────────────────────────
local function testMultiChunk()
	section("2. Round trip — multi-chunk (the split path)")

	-- Serialize is HEADER + 12 bytes/voxel, and base64 inflates by 4/3. To clear
	-- several 180k chunks we need roughly 180000 * 3 / 4 / 12 ≈ 11,250 voxels per
	-- chunk; 60k voxels lands around 4 chunks with a partial last one.
	local Original = makeGrid(4, 60000)
	local Blob     = Original:Serialize()
	local Folder   = newFolder("Multi")

	OccupancyChunks.Write(Folder, Blob)
	local ReadBack = OccupancyChunks.Read(Folder)

	local Count = Folder:GetAttribute("ChunkCount") or 0
	check("split into multiple chunks", Count > 1,
		string.format("ChunkCount=%d for %d voxels (%d-byte blob)", Count, Original.count, #Blob))
	check("StringValue count matches attribute", #Folder:GetChildren() == Count,
		string.format("children=%d attr=%d", #Folder:GetChildren(), Count))
	check("blob is byte-identical", ReadBack == Blob,
		string.format("in=%d out=%d", #Blob, ReadBack and #ReadBack or -1))

	if ReadBack then
		local Rebuilt = StaticOccupancy.Deserialize(ReadBack)
		local Same, Why = gridsMatch(Original, Rebuilt)
		check("60k-voxel grid survives", Same, Why)
	end

	-- Every chunk but the last should be exactly CHUNK chars; the last is the
	-- remainder. A split that drops or duplicates a byte shows up right here.
	local Sizes: { number } = {}
	local Kids = Folder:GetChildren()
	table.sort(Kids, function(a, b) return a.Name < b.Name end)
	for i, sv in Kids do
		Sizes[i] = #(sv :: StringValue).Value
	end
	local FullOk = true
	for i = 1, #Sizes - 1 do
		if Sizes[i] ~= CHUNK_SIZE then FullOk = false end
	end
	check("all but last chunk are full", FullOk,
		string.format("sizes: %s", table.concat(Sizes, ", ")))
	check("last chunk is non-empty", (Sizes[#Sizes] or 0) > 0,
		"last=" .. tostring(Sizes[#Sizes]))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Chunk ordering — zero-padded names must sort correctly past 9
-- ─────────────────────────────────────────────────────────────────────────────
local function testOrdering()
	section("3. Chunk ordering (lexicographic sort must match numeric)")

	-- Read sorts by Name. "%06d" padding is what makes "000010" sort after
	-- "000002"; unpadded, chunk 10 would come before chunk 2 and the blob would
	-- reassemble scrambled — which base64 would then decode into garbage rather
	-- than erroring, so this is a silent-corruption risk.
	local Folder = newFolder("Order")
	local Names: { string } = {}
	for i = 1, 12 do
		local sv = Instance.new("StringValue")
		sv.Name   = string.format("%06d", i)
		sv.Value  = string.rep(tostring(i % 10), 4)
		sv.Parent = Folder
		Names[i] = sv.Name
	end

	local Kids = Folder:GetChildren()
	table.sort(Kids, function(a, b) return a.Name < b.Name end)
	local SortedRight = true
	for i, sv in Kids do
		if sv.Name ~= string.format("%06d", i) then SortedRight = false end
	end
	check("padded names sort numerically", SortedRight,
		string.format("first=%s last=%s (12 chunks)", Kids[1].Name, Kids[#Kids].Name))

	Folder:ClearAllChildren()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Rewrite — Write must clear old chunks, not interleave with them
-- ─────────────────────────────────────────────────────────────────────────────
local function testRewrite()
	section("4. Rewrite into a used folder")

	local Folder = newFolder("Rewrite")

	local Big   = makeGrid(4, 40000)
	local Small = makeGrid(4, 50)

	OccupancyChunks.Write(Folder, Big:Serialize())
	local BigChunks = Folder:GetAttribute("ChunkCount")

	-- Overwrite with a much smaller blob. If the old StringValues survive, Read
	-- concatenates leftovers from the big bake onto the small one and the decode
	-- yields a corrupt grid.
	local SmallBlob = Small:Serialize()
	OccupancyChunks.Write(Folder, SmallBlob)
	local SmallChunks = Folder:GetAttribute("ChunkCount")

	check("chunk count shrinks on rewrite", SmallChunks < BigChunks,
		string.format("%s -> %s", tostring(BigChunks), tostring(SmallChunks)))
	check("no orphaned StringValues", #Folder:GetChildren() == SmallChunks,
		string.format("children=%d attr=%s", #Folder:GetChildren(), tostring(SmallChunks)))

	local ReadBack = OccupancyChunks.Read(Folder)
	check("rewrite reads back cleanly", ReadBack == SmallBlob,
		string.format("in=%d out=%d", #SmallBlob, ReadBack and #ReadBack or -1))

	if ReadBack then
		local Rebuilt = StaticOccupancy.Deserialize(ReadBack)
		local Same, Why = gridsMatch(Small, Rebuilt)
		check("rewritten grid is the small one", Same, Why)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Version attribute
-- ─────────────────────────────────────────────────────────────────────────────
local function testVersion()
	section("5. Version attribute")

	local Folder = newFolder("Version")
	local Blob   = makeGrid(4, 100):Serialize()

	OccupancyChunks.Write(Folder, Blob, 7)
	check("explicit version is stored", Folder:GetAttribute("Version") == 7,
		"Version=" .. tostring(Folder:GetAttribute("Version")))

	OccupancyChunks.Write(Folder, Blob)
	check("version resets to 1 when omitted", Folder:GetAttribute("Version") == 1,
		"Version=" .. tostring(Folder:GetAttribute("Version")))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Edge cases
-- ─────────────────────────────────────────────────────────────────────────────
local function testEdges()
	section("6. Edge cases")

	check("Read(nil) returns nil", OccupancyChunks.Read(nil) == nil, "nil")

	local Empty = newFolder("Empty")
	check("Read of empty folder returns nil", OccupancyChunks.Read(Empty) == nil, "nil")

	-- An empty grid is a real case: bake a region with no parts in it. It has to
	-- survive the trip rather than come back nil.
	local EmptyGrid = StaticOccupancy.new(4)
	local EmptyBlob = EmptyGrid:Serialize()
	local EmptyFolder = newFolder("EmptyGrid")
	OccupancyChunks.Write(EmptyFolder, EmptyBlob)
	local ReadBack = OccupancyChunks.Read(EmptyFolder)
	check("zero-voxel grid round-trips", ReadBack == EmptyBlob,
		string.format("in=%d out=%d", #EmptyBlob, ReadBack and #ReadBack or -1))
	if ReadBack then
		local Rebuilt = StaticOccupancy.Deserialize(ReadBack)
		check("rebuilt empty grid has 0 voxels", Rebuilt.count == 0, "count=" .. Rebuilt.count)
	end

	-- Write always emits at least one chunk, even for an empty payload, so Read
	-- can tell "wrote nothing" from "never written".
	check("empty payload still writes a chunk", EmptyFolder:GetAttribute("ChunkCount") == 1,
		"ChunkCount=" .. tostring(EmptyFolder:GetAttribute("ChunkCount")))

	-- The blob is packed binary — NUL bytes and every high byte value. base64 has
	-- to be binary-safe, not text-safe.
	local Binary = string.char(0, 1, 2, 253, 254, 255) .. string.rep("\0", 100) .. "\255\254"
	local BinFolder = newFolder("Binary")
	OccupancyChunks.Write(BinFolder, Binary)
	local BinBack = OccupancyChunks.Read(BinFolder)
	check("binary payload with NULs survives", BinBack == Binary,
		string.format("in=%d out=%d", #Binary, BinBack and #BinBack or -1))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Realistic bake — a grid from actual geometry
-- ─────────────────────────────────────────────────────────────────────────────
local function testRealBake()
	section("7. Real bake round trip")

	local VoxelBaker = require(ReplicatedStorage.src.Occupancy.VoxelBaker)

	local Wall = Instance.new("Part")
	Wall.Name      = "ChunkTestWall"
	Wall.Anchored  = true
	Wall.CanCollide = false
	Wall.Size      = Vector3.new(120, 60, 8)
	Wall.Position  = Vector3.new(0, 30, 0)
	Wall.Parent    = Scene

	local Grid = StaticOccupancy.new(2)
	VoxelBaker.BakeRegion(Grid, CFrame.new(0, 30, 0), Vector3.new(200, 120, 60))

	check("bake produced voxels", Grid.count > 0, "count=" .. Grid.count)

	local Blob   = Grid:Serialize()
	local Folder = newFolder("RealBake")
	OccupancyChunks.Write(Folder, Blob)
	local ReadBack = OccupancyChunks.Read(Folder)

	check("baked blob round-trips", ReadBack == Blob,
		string.format("in=%d out=%d chunks=%s", #Blob, ReadBack and #ReadBack or -1,
			tostring(Folder:GetAttribute("ChunkCount"))))

	if ReadBack then
		local Rebuilt = StaticOccupancy.Deserialize(ReadBack)
		local Same, Why = gridsMatch(Grid, Rebuilt)
		check("baked grid survives", Same, Why)

		-- The point of the grid is answering occupancy queries, so check the
		-- rebuilt one still answers them the same way the original does.
		local Agree, Total = 0, 0
		for x = -60, 60, 10 do
			for y = 4, 56, 10 do
				for z = -20, 20, 5 do
					Total += 1
					local vx, vy, vz = Grid:WorldToVoxel(Vector3.new(x, y, z))
					if Grid:IsOccupied(vx, vy, vz) == Rebuilt:IsOccupied(vx, vy, vz) then
						Agree += 1
					end
				end
			end
		end
		check("IsOccupied agrees after round trip", Agree == Total,
			string.format("%d/%d probes agree", Agree, Total))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RUN
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print(BAR)
print("  Vetra — OCCUPANCY CHUNKS")
print(BAR)

local StartClock = os.clock()

local Suite: { { name: string, fn: () -> () } } = {
	{ name = "Small",      fn = testSmall },
	{ name = "MultiChunk", fn = testMultiChunk },
	{ name = "Ordering",   fn = testOrdering },
	{ name = "Rewrite",    fn = testRewrite },
	{ name = "Version",    fn = testVersion },
	{ name = "Edges",      fn = testEdges },
	{ name = "RealBake",   fn = testRealBake },
}

for _, Entry in Suite do
	local Ok, Err = pcall(Entry.fn)
	if not Ok then
		Fails += 1
		table.insert(FailedNames, Entry.name .. " (errored)")
		warn(string.format("  [ERROR] %s — %s", Entry.name, tostring(Err)))
	end
end

print("")
print(BAR)
print(string.format("  RESULTS: %d passed, %d failed  (%.1fs)", Passes, Fails, os.clock() - StartClock))
if Fails > 0 then
	print("  Failed:")
	for _, Name in FailedNames do
		print("    · " .. Name)
	end
else
	print("  Chunking round-trips cleanly.")
end
print(BAR)
print("")
