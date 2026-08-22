--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- What snapshot does the worker ACTUALLY hold for the cast that misses?
--
-- Established: worker steps the missing HF=0 cast every frame, Step.lua is
-- correct in isolation, wire+dispatch are correct — yet after the first cast,
-- every HF=0 cast's raycasts all miss. Remaining suspects are the per-cast
-- state that crosses the actor boundary: the reused _AddCastMessage table
-- (stale trajectory) or the pooled RaycastParams.
--
-- The worker has a VETRA-DEBUG probe (ActorWorker_Server) that publishes, per
-- cast id: which worker steps it, its trajectory origin/velocity/startTime,
-- its RaycastParams identity string, and the latest step event + position.
-- This test fires 3 identical HF=0 casts on separate lanes and prints the
-- probe against what was actually fired.
--
-- ALSO settles the id question: prints ctx.Id vs the Cast handle's Id.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")
local Vetra = require(ReplicatedStorage.src)

local Probe = SharedTableRegistry:GetSharedTable("VetraFFProbe")
-- clear leftovers from a previous run
for k in Probe do Probe[k] = nil end

local Bin = Instance.new("Folder")
Bin.Name = "ParallelFFSnapshotProbeTest"
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
print("Vetra — FF snapshot probe: what does the worker hold for each cast?")
print(string.rep("═", 74))

local P = Vetra.newParallel()
task.wait(1)

local fired = {}  -- { {ctxId, castId, z, hitX, maxX} }

for trial = 1, 3 do
	local z = (trial - 1) * 200
	makeWall(z)

	local sig = P:GetSignals()
	local ctxId: number? = nil
	local hitX: number? = nil
	local maxX = -math.huge
	local c1 = sig.OnHit:Connect(function(c, res)
		if c.Id == ctxId and res and hitX == nil then hitX = res.Position.X end
	end)
	local c2 = sig.OnTravel:Connect(function(c, pos)
		if c.Id == ctxId and pos.X > maxX then maxX = pos.X end
	end)

	local ctx = Vetra.BulletContext.new({
		Origin = Vector3.new(0, 500, z), Direction = Vector3.new(1, 0, 0), Speed = 300 })
	ctxId = ctx.Id
	local cast = P:Fire(ctx, {
		Gravity = Vector3.zero, MaxDistance = 1e6, MinSpeed = 0,
		DragCoefficient = 0, MaxBounces = 0, FireTravelEvents = true,
		HighFidelitySegmentSize = 0, LODDistance = 0,
	})
	task.wait(2)
	c1:Disconnect() c2:Disconnect()

	table.insert(fired, {
		ctxId  = ctxId,
		castId = cast and cast.Id or -1,
		z      = z,
		hitX   = hitX,
		maxX   = maxX,
	})
end

print("")
for i, f in ipairs(fired) do
	print(string.format(
		"trial %d: ctx.Id=%s cast.Id=%s  fired origin=(0,500,%d) vel=(300,0,0)  %s (maxX=%.2f)",
		i, tostring(f.ctxId), tostring(f.castId), f.z,
		f.hitX and string.format("HIT %.2f", f.hitX) or "NO HIT",
		f.maxX > -math.huge and f.maxX or -1))

	local K = tostring(f.castId)
	local steps = Probe[K .. "_steps"]
	if steps == nil then
		print("         worker probe: NO ENTRY — this cast was never base-stepped")
	else
		print(string.format(
			"         worker=%s steps=%d lastStep ev=%s x=%.2f rt=%.3f",
			tostring(Probe[K .. "_worker"]), steps,
			tostring(Probe[K .. "_ev"]), Probe[K .. "_tx"] or -1, Probe[K .. "_rt"] or -1))
		print(string.format(
			"         CHAIN  step-terminal : %s (rt=%s x=%s)",
			tostring(Probe[K .. "_term_ev"]),
			tostring(Probe[K .. "_term_rt"]), tostring(Probe[K .. "_term_x"])))
		print(string.format(
			"                wall-crossing : ev=%s from=%s to=%s",
			tostring(Probe[K .. "_cross_ev"]),
			tostring(Probe[K .. "_cross_from"]), tostring(Probe[K .. "_cross_to"])))
		print(string.format(
			"                packed        : ev=%s n=%s",
			tostring(Probe[K .. "_packed_ev"]), tostring(Probe[K .. "_packed_n"])))
		print(string.format(
			"                drained       : ev=%s n=%s drop=%s",
			tostring(Probe[K .. "_drained_ev"]), tostring(Probe[K .. "_drained_n"]),
			tostring(Probe[K .. "_drop"])))
	end
end

P:Destroy()
Bin:Destroy()

print(string.rep("═", 74))
print("READ (the chain: step-terminal -> packed -> drained -> OnHit):")
print("  step-terminal=nil, crossing ev=travel  -> raycast MISSED in the parallel VM")
print("  step-terminal=hit, packed=nil          -> lost between Step and PackEventInto")
print("  packed=hit, drained=nil                -> lost in the SharedTable hand-off")
print("  drained=hit + drop reason              -> dropped at dispatch (reason shown)")
print("  drained=hit, no drop, but NO HIT above -> lost inside the handler")
print(string.rep("═", 74))
