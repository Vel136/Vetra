--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Which of these is the HF=0+LOD=off failure?
--   (a) OnHit never fires and the cast never terminates      -> worker/wire loss
--   (b) OnHit fires with res == nil                          -> HitInstance race
--   (c) OnHit doesn't fire but OnTerminated does             -> handler gap
-- Previous test counted a hit only when `res` was non-nil, which cannot tell
-- (a) from (b). This one logs every signal unconditionally.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local Bin = Instance.new("Folder")
Bin.Name = "ParallelHitNilResultTest"
Bin.Parent = workspace

local function makeWall(z: number)
	local p = Instance.new("Part")
	p.Anchored = true p.CanCollide = false
	p.Size = Vector3.new(4, 200, 100)
	p.Position = Vector3.new(152, 500, z)
	p.Transparency = 0.5
	p.Parent = Bin
end

local function trial(P: any, label: string, z: number, hf: number, lod: boolean)
	makeWall(z)
	local sig = P:GetSignals()
	local id: number? = nil

	local onHitCount, onHitNilCount = 0, 0
	local hitX: number? = nil
	local terminated: string? = nil
	local maxX = -math.huge

	local c1 = sig.OnHit:Connect(function(ctx, res)
		if ctx.Id ~= id then return end
		onHitCount += 1
		if res then hitX = res.Position.X else onHitNilCount += 1 end
	end)
	local c2 = sig.OnTerminated:Connect(function(ctx)
		if ctx.Id == id then terminated = terminated or "OnTerminated" end
	end)
	local c3 = sig.OnTravel:Connect(function(ctx, pos)
		if ctx.Id == id and pos.X > maxX then maxX = pos.X end
	end)

	P:SetLODOrigin(Vector3.new(0, -1e5, 0))
	local ctx = Vetra.BulletContext.new({
		Origin = Vector3.new(0, 500, z), Direction = Vector3.new(1, 0, 0), Speed = 300 })
	id = ctx.Id
	P:Fire(ctx, {
		Gravity = Vector3.zero, MaxDistance = 1e6, MinSpeed = 0,
		DragCoefficient = 0, MaxBounces = 0, FireTravelEvents = true,
		HighFidelitySegmentSize = hf,
		LODDistance = lod and 1 or 0, LODInterval = 4,
	})
	task.wait(2)
	c1:Disconnect() c2:Disconnect() c3:Disconnect()

	print(string.format(
		"  %-22s OnHit=%d (nil-res=%d) hitX=%-8s terminated=%-14s maxTravelX=%.2f",
		label, onHitCount, onHitNilCount,
		hitX and string.format("%.2f", hitX) or "-",
		terminated or "NO",
		maxX > -math.huge and maxX or -1))
end

print(string.rep("═", 74))
print("Vetra — is the parallel HF=0 'NO HIT' really a nil-result OnHit?")
print(string.rep("═", 74))

local P = Vetra.newParallel()
task.wait(1)
trial(P, "HF=0 LOD=off  <<<", 0,    0, false)
trial(P, "HF=5 LOD=off",      200,  5, false)
trial(P, "HF=0 LOD=on",       400,  0, true)
trial(P, "HF=0 LOD=off again",600,  0, false)
P:Destroy()
Bin:Destroy()

print(string.rep("═", 74))
print("(a) OnHit=0, terminated=NO, maxX>>150  -> hit record lost before dispatch")
print("(b) OnHit>0 with nil-res>0             -> HitInstance BindableEvent race")
print("(c) OnHit=0 but terminated=YES         -> handler consumed it silently")
print(string.rep("═", 74))
