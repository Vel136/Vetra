--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Tumble on parallel — targeted verification (~12s, vs FeatureSuite2's 120s)
--
-- Checks the two fixes from the tumble port and nothing else:
--
--   1. OnTumbleBegin / OnTumbleEnd fire on BOTH solvers.
--        The transition detection lived only in the serial stepper. The parallel
--        worker honoured IsTumbling for drag/lateral force but nothing ever set
--        it, so tumble was inert there: no signals, no physics.
--
--   2. Coriolis deflects on both (threshold sanity only).
--
-- WHY THIS EXISTS SEPARATELY
--   The tumble cast is fire-and-forget (no callbacks, no travel events), and the
--   FF loop DROPS Travel results — only trajectory reopens and terminals come
--   back. So a correct Step-side detection still can't fire a signal unless the
--   record carrying the edge escapes that drop. That's the bug this catches, and
--   it's invisible from reading the Step code alone.
--
-- On failure, the diagnostics below say WHICH link broke rather than just "0".
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 72)

local Passes, Fails = 0, 0
local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("    [PASS] %-40s %s", name, detail))
	else
		Fails += 1
		warn(string.format("    [FAIL] %-40s %s", name, detail))
	end
end

local Scene = Instance.new("Folder")
Scene.Name   = "VetraTumbleVerifyScene"
Scene.Parent = workspace

local function sceneParams(): RaycastParams
	local P = RaycastParams.new()
	P.FilterType = Enum.RaycastFilterType.Include
	P.FilterDescendantsInstances = { Scene }
	return P
end

local WORKER_BOOT = 1.5

local function bothSolvers(body: (any) -> any): (any, any)
	local S = Vetra.new({})
	local SR = body(S)
	S:Destroy()

	local P = Vetra.newParallel({})
	task.wait(WORKER_BOOT)
	local PR = body(P)
	P:Destroy()

	return SR, PR
end

print("")
print(BAR)
print("  Tumble on parallel — verification")
print(BAR)

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tumble begin/end fire on both solvers
-- ─────────────────────────────────────────────────────────────────────────────
local S, P = bothSolvers(function(Solver)
	local R = { Begin = 0, End = 0, Tumbling = false, Speed = 0 }
	Solver:GetSignals().OnTumbleBegin:Connect(function() R.Begin += 1 end)
	Solver:GetSignals().OnTumbleEnd:Connect(function() R.End += 1 end)

	local Ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, 1200, 0),
		Direction = Vector3.new(1, 0, 0),
		Speed     = 600,
	})
	-- Spawn just above the threshold and let drag pull it under: the crossing is
	-- what fires OnTumbleBegin. No callbacks and no travel events, so this cast is
	-- fire-and-forget on parallel — which is exactly the path that drops Travel
	-- results and swallowed the transition edge.
	local Cast = Solver:Fire(Ctx, {
		MaxDistance          = 1e5,
		MinSpeed             = 0,
		Gravity              = Vector3.new(0, -0.001, 0),
		RaycastParams        = sceneParams(),
		MaxBounces           = 0,
		DragCoefficient      = 8e-5,
		TumbleSpeedThreshold = 580,
		TumbleDragMultiplier = 3.0,
	})

	task.wait(2.5)
	if Cast.Alive then
		R.Tumbling = Cast.Runtime.IsTumbling == true
		R.Speed    = Cast:GetVelocity().Magnitude
	end
	return R
end)

check("OnTumbleBegin fires (serial)",   S.Begin > 0, string.format("count=%d", S.Begin))
check("OnTumbleBegin fires (parallel)", P.Begin > 0, string.format("count=%d", P.Begin))
-- Both non-zero BEFORE comparing: a bare tolerance would let 1-vs-0 pass as
-- agreement, which is the exact divergence this test exists to catch.
check("tumble begin counts agree",
	S.Begin > 0 and P.Begin > 0 and math.abs(S.Begin - P.Begin) <= 1,
	string.format("serial=%d parallel=%d", S.Begin, P.Begin))

-- Runtime.IsTumbling is set by the worker's writeback, which is a DIFFERENT link
-- than the signal. Splitting them tells us which half broke: state true + signal 0
-- means the edge died in transport; state false means Step never detected it.
check("Runtime.IsTumbling set (serial)",   S.Tumbling, string.format("IsTumbling=%s speed=%.0f", tostring(S.Tumbling), S.Speed))
check("Runtime.IsTumbling set (parallel)", P.Tumbling, string.format("IsTumbling=%s speed=%.0f", tostring(P.Tumbling), P.Speed))

print("")
if P.Begin == 0 then
	if P.Tumbling then
		print("  -> Parallel DETECTED the tumble (IsTumbling=true) but no signal arrived.")
		print("     The edge is dying in transport: check the FF loop's Travel drop and")
		print("     that TumbleBegan escapes it on a FULL record (lite formats carry no")
		print("     flag field).")
	else
		print("  -> Parallel never detected the tumble at all (IsTumbling=false).")
		print("     Check Parallel/Physics/Step.lua's transition block and that the")
		print("     coordinator ships TumbleSpeedThreshold in AddCast.")
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Coriolis (threshold sanity)
-- ─────────────────────────────────────────────────────────────────────────────
local function runCoriolis(enabled: boolean)
	return bothSolvers(function(Solver)
		if enabled then Solver:SetCoriolisConfig(45, 5000) end
		local Ctx = Vetra.BulletContext.new({
			Origin    = Vector3.new(0, 2000, 500),
			Direction = Vector3.new(1, 0, 0),
			Speed     = 400,
		})
		local Cast = Solver:Fire(Ctx, {
			MaxDistance     = 1e5,
			MinSpeed        = 0,
			Gravity         = Vector3.new(0, -0.001, 0),
			RaycastParams   = sceneParams(),
			MaxBounces      = 0,
			DragCoefficient = 1e-5,
		})
		task.wait(1.5)
		return Cast.Alive and Cast:GetPosition() or nil
	end)
end

local SNo,  PNo  = runCoriolis(false)
local SYes, PYes = runCoriolis(true)

if SNo and SYes then
	local D = (SYes - SNo).Magnitude
	check("Coriolis deflects (serial)", D > 0.01, string.format("delta=%.3f studs", D))
end
if PNo and PYes then
	local D = (PYes - PNo).Magnitude
	check("Coriolis deflects (parallel)", D > 0.01, string.format("delta=%.3f studs", D))
end

Scene:Destroy()

print("")
print(BAR)
print(string.format("  RESULTS: %d passed, %d failed", Passes, Fails))
if Fails == 0 then
	print("  Both fixes verified. Re-run FeatureSuite2 for the full 56/56.")
end
print(BAR)
print("")
