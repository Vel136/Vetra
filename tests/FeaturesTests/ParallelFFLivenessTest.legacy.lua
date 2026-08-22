--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Is the worker's FF loop even RUNNING for the cast that misses?
--
-- Established so far: HF=0+LOD=off on parallel sometimes hits, sometimes flies
-- to 600 with no hit — same solver, same config. Step.lua, the wire format, and
-- the dispatcher are all verified correct. So the failure is liveness, not
-- logic: for the failing cast, either the worker never steps it, or the write
-- never lands.
--
-- HOW THIS OBSERVES (no worker edits needed):
--   · The worker's FF loop writes FFBuffer["data"] EVERY frame it executes with
--     at least one FF cast — even a frame with zero events writes the empty
--     batch. The coordinator only ever resets "count", never "data". So:
--         data == nil forever  =>  the FF loop never ran in that worker
--         data ~= nil          =>  the loop ran; then "count" tells us whether
--                                  the hit record was ever written
--   · We connect our own Heartbeat BEFORE creating the solver, so our sampler
--     runs before the coordinator's drain each frame and can see "count" > 0
--     before it is zeroed.
--   · We also record which shard the cast landed on (Coordinator._CastToShard)
--     and whether that worker ever signalled WorkerReadyEvent.
--
-- RUN: server, Play mode. Fires the failing config 6 times on one solver.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Vetra = require(ReplicatedStorage.src)

local Bin = Instance.new("Folder")
Bin.Name = "ParallelFFLivenessTest"
Bin.Parent = workspace

local function makeWall(z: number)
	local p = Instance.new("Part")
	p.Anchored = true p.CanCollide = false
	p.Size = Vector3.new(4, 200, 100)
	p.Position = Vector3.new(152, 500, z)
	p.Transparency = 0.5
	p.Parent = Bin
end

print(string.rep("═", 74))
print("Vetra — FF worker liveness (is the loop running for the cast that misses?)")
print(string.rep("═", 74))

-- ── Sampler: registered BEFORE the solver so it runs before the drain ───────
local FFRefs: { any } = {}          -- coordinator's FF SharedTables, once known
local CountSeen: { [number]: number } = {}  -- shard -> frames where count > 0
local DataSeen:  { [number]: number } = {}  -- shard -> frames where data ~= nil
local FramesSampled = 0
local SamplerOn = false

local SamplerConn = RunService.Heartbeat:Connect(function()
	if not SamplerOn then return end
	FramesSampled += 1
	for shard, ff in ipairs(FFRefs) do
		if ff["data"] ~= nil then DataSeen[shard] = (DataSeen[shard] or 0) + 1 end
		local c = ff["count"]
		if c and c > 0 then CountSeen[shard] = (CountSeen[shard] or 0) + 1 end
	end
end)

-- ── Solver ──────────────────────────────────────────────────────────────────
local P = Vetra.newParallel()

-- Reach the coordinator internals (diagnostic only).
local Coord: any = nil
for _, v in pairs(P :: any) do
	if type(v) == "table" and rawget(v, "_FFBuffers") then Coord = v break end
end
if not Coord then
	warn("could not locate coordinator internals — abort")
	return
end
for i, ff in ipairs(Coord._FFBuffers) do FFRefs[i] = ff end

local ReadySeen: { [number]: boolean } = {}
for i, actor in ipairs(Coord._Actors) do
	local ev = actor:FindFirstChild("WorkerReadyEvent")
	if ev then
		local idx = i
		ev.Event:Connect(function() ReadySeen[idx] = true end)
	end
end

task.wait(1)  -- worker init window (the documented startup race)

print(string.format("shards: %d | workers ready-signalled before first fire: %s",
	#Coord._Actors,
	(function()
		local t = {}
		for i = 1, #Coord._Actors do t[#t+1] = ReadySeen[i] and "Y" or "?" end
		return table.concat(t, ",")
	end)()))
print("(ready '?' can mean the signal fired before we hooked — not conclusive alone)")
print("")

-- ── Trials ──────────────────────────────────────────────────────────────────
local ZBase = 0
for trial = 1, 6 do
	local z = ZBase + (trial - 1) * 200
	makeWall(z)

	-- reset per-trial tallies
	CountSeen = {}
	DataSeen  = {}
	FramesSampled = 0

	local sig = P:GetSignals()
	local id: number? = nil
	local hitX: number? = nil
	local maxX = -math.huge
	local c1 = sig.OnHit:Connect(function(ctx, res)
		if ctx.Id == id and res and hitX == nil then hitX = res.Position.X end
	end)
	local c2 = sig.OnTravel:Connect(function(ctx, pos)
		if ctx.Id == id and pos.X > maxX then maxX = pos.X end
	end)

	local ctx = Vetra.BulletContext.new({
		Origin = Vector3.new(0, 500, z), Direction = Vector3.new(1, 0, 0), Speed = 300 })
	id = ctx.Id
	SamplerOn = true
	P:Fire(ctx, {
		Gravity = Vector3.zero, MaxDistance = 1e6, MinSpeed = 0,
		DragCoefficient = 0, MaxBounces = 0, FireTravelEvents = true,
		HighFidelitySegmentSize = 0, LODDistance = 0,
	})
	local shard = Coord._CastToShard[id]

	task.wait(2)
	SamplerOn = false
	c1:Disconnect() c2:Disconnect()

	local dataFrames  = shard and (DataSeen[shard] or 0) or -1
	local countFrames = shard and (CountSeen[shard] or 0) or -1

	print(string.format(
		"trial %d: shard=%s  hit=%-8s maxX=%-8.2f | shard's FF: dataFrames=%d/%d countFrames=%d",
		trial, tostring(shard),
		hitX and string.format("%.2f", hitX) or "NO HIT",
		maxX > -math.huge and maxX or -1,
		dataFrames, FramesSampled, countFrames))

	-- non-target shards, for contrast
	local others = {}
	for s = 1, #FFRefs do
		if s ~= shard then
			others[#others+1] = string.format("s%d:d=%d,c=%d", s, DataSeen[s] or 0, CountSeen[s] or 0)
		end
	end
	print("         other shards: " .. table.concat(others, "  "))
end

SamplerConn:Disconnect()
P:Destroy()
Bin:Destroy()

print(string.rep("═", 74))
print("READ:")
print("  MISS + dataFrames=0            -> FF loop NEVER RAN in that worker")
print("     (FFBuffer nil there => Init message lost/late, or connection dead)")
print("  MISS + dataFrames>0, count=0   -> loop ran but the hit was never packed")
print("  MISS + countFrames>0           -> packed but lost between write & drain")
print("  Compare which shards the HITs vs MISSes land on.")
print(string.rep("═", 74))
