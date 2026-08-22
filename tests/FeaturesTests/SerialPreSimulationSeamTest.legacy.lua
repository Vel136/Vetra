--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Does SERIAL thread the same seam when driven by PreSimulation deltas?
--
-- The parallel FF bug: PreSimulation FrameDelta is quantized to exact physics
-- quanta (multiples of 1/240), so positions land on an exact grid; a wall face
-- on that grid falls into the raycast dead bands and every frame ray misses.
-- Serial escapes only because init.lua drives it from Heartbeat (jittery
-- wall-clock). Serial's own raycast has NO epsilon back-off — so the hazard
-- should be latent there, reachable the moment the clock changes.
--
-- This test proves it by swapping ONLY the clock:
--   A. serial driven by its default Heartbeat            -> expect HIT
--   B. serial driven manually from PreSimulation deltas  -> expect NO HIT
--   C. serial driven manually from Heartbeat deltas      -> expect HIT
--      (C exists so "manual driving" itself is ruled out as the variable)
--
-- It also prints raw delta samples from both clocks: PreSimulation deltas
-- times 240 should be near-integers; Heartbeat's should not.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Vetra          = require(ReplicatedStorage.src)
local StepProjectile = require(ReplicatedStorage.src.Simulation.StepProjectile)

local WALL_FACE = 150
local SPEED     = 300
local START_Y   = 500

local Bin = Instance.new("Folder")
Bin.Name = "SerialPreSimulationSeamTest"
Bin.Parent = workspace

local function makeWall(z: number)
	local p = Instance.new("Part")
	p.Anchored = true p.CanCollide = false
	p.Size = Vector3.new(4, 200, 100)
	p.Position = Vector3.new(WALL_FACE + 2, START_Y, z)
	p.Transparency = 0.5
	p.Parent = Bin
end

print(string.rep("═", 74))
print("Vetra — serial + PreSimulation clock: is the seam reachable in serial?")
print(string.rep("═", 74))

-- ── 0. Show the two clocks side by side ─────────────────────────────────────
do
	local pre: { number }, hb: { number } = {}, {}
	local c1 = RunService.PreSimulation:Connect(function(dt)
		if #pre < 8 then pre[#pre + 1] = dt end
	end)
	local c2 = RunService.Heartbeat:Connect(function(dt)
		if #hb < 8 then hb[#hb + 1] = dt end
	end)
	task.wait(0.5)
	c1:Disconnect() c2:Disconnect()

	print("\nclock samples (dt, and dt*240 — integer means physics-quantized):")
	for i = 1, math.min(#pre, #hb, 6) do
		print(string.format("  PreSimulation dt=%.9f  x240=%10.5f | Heartbeat dt=%.9f  x240=%10.5f",
			pre[i], pre[i] * 240, hb[i], hb[i] * 240))
	end
end

-- ── One serial scenario with a chosen clock ─────────────────────────────────
local function run(label: string, z: number, driver: string)
	makeWall(z)
	local S = Vetra.new()

	if driver ~= "default" then
		-- take over the stepping: kill the solver's own Heartbeat connection
		local conn = (S :: any)._FrameEvent
		if conn then conn:Disconnect() end
		local ev = (driver == "presim") and RunService.PreSimulation or RunService.Heartbeat
		;(S :: any)._FrameEvent = ev:Connect(function(dt: number)
			StepProjectile.StepProjectile(S, dt)
		end)
	end

	local sig = S:GetSignals()
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
		Origin = Vector3.new(0, START_Y, z), Direction = Vector3.new(1, 0, 0), Speed = SPEED })
	id = ctx.Id
	S:Fire(ctx, {
		Gravity = Vector3.zero, MaxDistance = 1e6, MinSpeed = 0,
		DragCoefficient = 0, MaxBounces = 0, FireTravelEvents = true,
		HighFidelitySegmentSize = 0, LODDistance = 0,
	})
	task.wait(2)
	c1:Disconnect() c2:Disconnect()
	S:Destroy()

	print(string.format("  %-38s %s (maxTravelX=%.2f)",
		label,
		hitX and string.format("HIT %.2f", hitX) or "NO HIT",
		maxX > -math.huge and maxX or -1))
end

print("")
run("A. default clock (Heartbeat)",        0,   "default")
run("B. driven by PreSimulation deltas",   200, "presim")
run("C. driven manually from Heartbeat",   400, "heartbeat")

Bin:Destroy()

print(string.rep("═", 74))
print("A HIT, B NO HIT, C HIT  -> seam confirmed latent in serial; only the")
print("                           jittery Heartbeat clock protects it today.")
print("B HIT too               -> serial differs some other way; investigate.")
print(string.rep("═", 74))
