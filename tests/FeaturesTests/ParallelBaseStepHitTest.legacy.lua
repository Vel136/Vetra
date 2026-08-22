--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Parallel base-Step hit test — isolating "HF=0 never hits"
--
-- THE OBSERVATION (reproduced live, single lane, fresh solver each time):
--     HighFidelitySegmentSize = 0  ->  NO HIT   (flies to ~600)
--     HighFidelitySegmentSize = 5  ->  HIT 150.00
-- LOD makes no difference. Lane count makes no difference. Serial always hits.
--
-- HF=0 routes the worker through Parallel/Physics/Step.lua; HF>0 routes it
-- through Parallel/Physics/StepHighFidelity.lua. Both raycast the same span, so
-- one of them is losing the hit — or the base Step's result never reaches the
-- coordinator's dispatcher.
--
-- WHAT EACH SECTION ANSWERS
--   1. Baseline matrix    Does HF=0/HF=5 split reproduce for you, on your machine?
--   2. Pure-function      Called DIRECTLY on the main thread (no Actor, no
--                         marshaling), does Step.lua return a hit? This splits
--                         "the physics is wrong" from "the plumbing is wrong".
--   3. Wire round-trip    Does a base-Step `hit` survive PackEvent -> string ->
--                         UnpackEvent, and does EventHandlers have a handler for
--                         the event name it carries?
--   4. Live worker probe  Fire real casts and count OnHit across configs.
--
-- READING IT
--   Section 2 is the decisive one:
--     · Step returns HIT   -> physics fine, bug is in the worker/wire/dispatch.
--     · Step returns MISS  -> bug is inside Step.lua itself.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local WALL_FACE  = 150
local WALL_THICK = 4
local SPEED      = 300
local START_Y    = 500
local FLIGHT     = 2.0

local function line() print(string.rep("─", 74)) end

local Bin = Instance.new("Folder")
Bin.Name   = "ParallelBaseStepHitTest"
Bin.Parent = workspace

local function makeWall(z: number): BasePart
	local p = Instance.new("Part")
	p.Anchored     = true
	p.CanCollide   = false
	p.Size         = Vector3.new(WALL_THICK, 200, 100)
	p.Position     = Vector3.new(WALL_FACE + WALL_THICK * 0.5, START_Y, z)
	p.Color        = Color3.fromRGB(200, 80, 80)
	p.Transparency = 0.5
	p.Parent       = Bin
	return p
end

local function behavior(hf: number, lod: boolean)
	return {
		Gravity                 = Vector3.zero,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		DragCoefficient         = 0,
		MaxBounces              = 0,
		FireTravelEvents        = true,
		HighFidelitySegmentSize = hf,
		LODDistance             = lod and 1 or 0,
		LODInterval             = 4,
	}
end

print(string.rep("═", 74))
print("Vetra — parallel base-Step hit test (HF=0 vs HF>0)")
print(string.format("  wall face x=%d | speed=%d | gravity=ZERO", WALL_FACE, SPEED))
print(string.rep("═", 74))

-- ═══ 1 & 4. Live matrix ═════════════════════════════════════════════════════
local function fireOnce(solver: any, z: number, hf: number, lod: boolean)
	makeWall(z)
	local sig = solver:GetSignals()
	local id: number? = nil
	local hitX: number? = nil
	local travelN, maxX = 0, -math.huge

	local c1 = sig.OnTravel:Connect(function(ctx, pos)
		if ctx.Id ~= id then return end
		travelN += 1
		if pos.X > maxX then maxX = pos.X end
	end)
	local c2 = sig.OnHit:Connect(function(ctx, res)
		if ctx.Id == id and hitX == nil and res then hitX = res.Position.X end
	end)

	solver:SetLODOrigin(Vector3.new(0, -1e5, 0))
	local ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, START_Y, z),
		Direction = Vector3.new(1, 0, 0),
		Speed     = SPEED,
	})
	id = ctx.Id
	solver:Fire(ctx, behavior(hf, lod))
	task.wait(FLIGHT)
	c1:Disconnect()
	c2:Disconnect()
	return hitX, travelN, (maxX > -math.huge) and maxX or nil
end

local function report(label: string, hitX: number?, travelN: number, maxX: number?)
	print(string.format("  %-30s travel=%-5d maxX=%-9s hit=%s",
		label, travelN,
		maxX and string.format("%.2f", maxX) or "-",
		hitX and string.format("%.2f", hitX) or "NO HIT  <<<"))
end

print("\n### 1. SERIAL control (expect every row to HIT 150)")
local S = Vetra.new()
report("HF=0 LOD=off", fireOnce(S, 0,   0, false))
report("HF=5 LOD=off", fireOnce(S, 200, 5, false))
report("HF=0 LOD=on",  fireOnce(S, 400, 0, true))
report("HF=5 LOD=on",  fireOnce(S, 600, 5, true))
S:Destroy()

print("\n### 4. PARALLEL matrix (HF=0 rows are the suspects)")
local P = Vetra.newParallel()
task.wait(1)   -- workers init async
report("HF=0 LOD=off", fireOnce(P, 1000, 0, false))
report("HF=5 LOD=off", fireOnce(P, 1200, 5, false))
report("HF=0 LOD=on",  fireOnce(P, 1400, 0, true))
report("HF=5 LOD=on",  fireOnce(P, 1600, 5, true))
P:Destroy()

-- ═══ 2. Pure-function: call Step.lua directly, no Actor ═════════════════════
print("\n### 2. Step.lua called DIRECTLY on the main thread (no worker, no marshaling)")
line()

local Step = require(ReplicatedStorage.src.Parallel.Physics.Step)
local StepFn = (type(Step) == "table" and Step.Step) or Step

local probeWall = makeWall(2000)
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.FilterDescendantsInstances = {}

local control = workspace:Raycast(
	Vector3.new(0, START_Y, 2000), Vector3.new(400, 0, 0), rp)
print("  control raycast 0->400 : " ..
	(control and string.format("HIT %.3f", control.Position.X) or "NIL"))

local function makeSnapshot(hf: number)
	return {
		Id = 1,
		TrajectoryOrigin          = Vector3.new(0, START_Y, 2000),
		TrajectoryInitialVelocity = Vector3.new(SPEED, 0, 0),
		TrajectoryAcceleration    = Vector3.zero,
		TrajectoryStartTime       = 0,
		TotalRuntime = 0, DistanceCovered = 0,
		SpawnOrigin  = Vector3.new(0, START_Y, 2000),
		IsSupersonic = false, LastDragRecalculateTime = 0, SpinVector = Vector3.zero,
		HomingElapsed = 0, HomingDisengaged = false, HomingAcquired = false,
		CurrentSegmentSize = hf,
		BouncesThisFrame = 0, BounceCount = 0, PierceCount = 0, LastBounceTime = 0,
		IsLOD = false, LODDistance = 0, LODInterval = 4,
		LODFrameAccumulator = 0, LODDeltaAccumulator = 0,
		SpatialFrameAccumulator = 0, SpatialDeltaAccumulator = 0,
		SpatialTier = 1, LODOrigin = nil,
		BouncePositionHistory = {}, BouncePositionHead = 0,
		VelocityDirectionEMA = Vector3.zero, FirstBouncePosition = nil,
		CornerBounceCount = 0,
		MaxDistance = 1e6, MaxDisplacement = 0, MinSpeed = 0, MaxSpeed = math.huge,
		MaxBounces = 0, MaxBouncesPerFrame = 0, MaxPierceCount = 0,
		DragCoefficient = 0, DragModel = 0, DragSegmentInterval = 0,
		BounceSpeedThreshold = 0, Restitution = 0, NormalPerturbation = 0,
		PierceSpeedThreshold = 0, PierceSpeedRetention = 0, PierceNormalBias = 0,
		MagnusCoefficient = 0, SpinDecayRate = 0,
		HomingStrength = 0, HomingMaxDuration = 0, HomingTarget = nil,
		HighFidelitySegmentSize = hf, AdaptiveScaleFactor = 2, MinSegmentSize = 0.1,
		HighFidelityFrameBudget = 4,
		CornerTimeThreshold = 0, CornerDisplacementThreshold = 0, CornerEMAAlpha = 0,
		CornerEMAThreshold = 0, CornerMinProgressPerBounce = 0,
		HasCanPierceCallback = false, HasCanBounceCallback = false,
		HasCanHomeCallback = false,
		BaseAcceleration = Vector3.zero, Wind = Vector3.zero, WindResponse = 0,
		IsTumbling = false, TumbleOnPierce = false,
		VisualizeCasts = false, NeedsSync = false,
		RaycastParams = rp,
		StaticOccupancy = nil, DynamicOccupancy = nil,
		StaticOccupancyId = 0, DynamicOccupancyId = 0,
		CoriolisOmega = Vector3.zero,
		RemainingResimDelta = nil,
		ProvidedLastPosition = nil, ProvidedCurrentPosition = nil,
		ProvidedCurrentVelocity = nil,
		SixDOFEnabled = false,
	}
end

-- Drive Step.lua frame by frame with a REALISTIC jittery delta (exact 1/60 has a
-- separate float-boundary artifact that is NOT what we're hunting here).
local Snap = makeSnapshot(0)
local outcome = "ran off the end without terminating"
local crossing = {}
for frame = 1, 300 do
	local dt = (1/60) * (1 + (math.random() - 0.5) * 0.02)
	local before = Snap.TotalRuntime
	local r = StepFn(Snap, dt)
	if r == nil then outcome = "Step returned nil at frame " .. frame break end

	local tp = r.TravelPosition
	if tp and tp.X > 138 and tp.X < 166 then
		local a = Vector3.new(before * SPEED, START_Y, 2000)
		local b = Vector3.new(r.TotalRuntime * SPEED, START_Y, 2000)
		local manual = workspace:Raycast(a, b - a, rp)
		table.insert(crossing, string.format(
			"    x=%7.3f ev=%-9s hit=%-8s | manual ray %.3f->%.3f = %s",
			tp.X, tostring(r.Event),
			r.HitPosition and string.format("%.2f", r.HitPosition.X) or "nil",
			a.X, b.X,
			manual and string.format("HIT %.3f", manual.Position.X) or "nil"))
	end

	Snap.TotalRuntime    = r.TotalRuntime
	Snap.DistanceCovered = r.DistanceCovered
	if r.Trajectory then
		Snap.TrajectoryOrigin          = r.Trajectory.Origin
		Snap.TrajectoryInitialVelocity = r.Trajectory.InitialVelocity
		Snap.TrajectoryAcceleration    = r.Trajectory.Acceleration
		Snap.TrajectoryStartTime       = r.Trajectory.StartTime
	end

	if r.Event ~= "travel" then
		outcome = string.format("frame %d EVENT=%s hitPos=%s",
			frame, tostring(r.Event),
			r.HitPosition and string.format("%.3f", r.HitPosition.X) or "nil")
		break
	end
	if tp and tp.X > 260 then
		outcome = string.format("OVERRAN to %.2f without terminating", tp.X)
		break
	end
end

print("  frames crossing the wall region:")
if #crossing == 0 then
	print("    (none — cast never reached x=138..166)")
end
for _, l in ipairs(crossing) do print(l) end
print("  outcome: " .. outcome)
print("")
print("  >> If 'manual ray' HITs on a frame where Step reports ev=travel/hit=nil,")
print("     the bug is INSIDE Step.lua. If Step reports EVENT=hit here but the live")
print("     parallel run above says NO HIT, the bug is in the worker/wire/dispatch.")

-- ═══ 3. Wire round-trip for a base-Step hit ════════════════════════════════
print("\n### 3. Does a base-Step 'hit' survive the ResultBuffer wire + find a handler?")
line()

local ResultBuffer  = require(ReplicatedStorage.src.Parallel.ResultBuffer)
local EventHandlers = require(ReplicatedStorage.src.Parallel.Physics.EventHandlers)
local Constants     = require(ReplicatedStorage.src.Core.Constants)

local FakeHit = {
	Id = 1, Event = Constants.PARALLEL_EVENT.Hit,
	TotalRuntime = 0.5, DistanceCovered = 150,
	IsSupersonic = false, LastDragRecalcTime = 0, SpinVector = Vector3.zero,
	HomingElapsed = 0, HomingDisengaged = false, HomingAcquired = false,
	CurrentSegmentSize = 0, BouncesThisFrame = 0,
	IsLOD = false, LODFrameAccumulator = 0, LODDeltaAccumulator = 0,
	SpatialFrameAccumulator = 0, SpatialDeltaAccumulator = 0,
	HitPosition = Vector3.new(150, START_Y, 0),
	HitNormal   = Vector3.new(-1, 0, 0),
	HitMaterial = Enum.Material.Plastic,
	TravelPosition = Vector3.new(150, START_Y, 0),
	TravelVelocity = Vector3.new(SPEED, 0, 0),
	RayOrigin      = Vector3.new(145, START_Y, 0),
	IsTumbling = false, TumbleBegan = false, TumbleRecovered = false,
}

local buf = buffer.create(ResultBuffer.HEADER_SIZE + ResultBuffer.MAX_RECORD_SIZE * 2)
local okPack, endOff = pcall(ResultBuffer.PackEvent, buf, ResultBuffer.HEADER_SIZE, FakeHit)
print("  PackEvent      : " .. tostring(okPack) .. (okPack and (" -> offset " .. tostring(endOff)) or (" ERR " .. tostring(endOff))))

if okPack then
	buffer.writeu32(buf, 0, 1)
	local tmp = buffer.create(endOff)
	buffer.copy(tmp, 0, buf, 0, endOff)
	local rbuf = buffer.fromstring(buffer.tostring(tmp))
	local okUn, ev = pcall(ResultBuffer.UnpackEvent, rbuf, ResultBuffer.HEADER_SIZE)
	if okUn then
		print("  UnpackEvent    : Event=" .. tostring(ev.Event)
			.. "  HitPosition=" .. tostring(ev.HitPosition))
		local handler = EventHandlers[ev.Event]
		print("  Handler exists : " .. tostring(handler ~= nil)
			.. "  (for event name '" .. tostring(ev.Event) .. "')")
		if handler == nil then
			warn("  [!!] No handler registered for this event name — a hit would be")
			warn("       unpacked and then silently dropped by the dispatcher.")
		end
	else
		warn("  UnpackEvent FAILED: " .. tostring(ev))
	end
end

print("\n  EventHandlers keys registered:")
for k, v in pairs(EventHandlers) do
	if type(v) == "function" then print("    " .. tostring(k)) end
end

probeWall:Destroy()
Bin:Destroy()

print(string.rep("═", 74))
print("Report sections 1, 2, 3 and 4 together — 2 tells us physics vs plumbing.")
print(string.rep("═", 74))
