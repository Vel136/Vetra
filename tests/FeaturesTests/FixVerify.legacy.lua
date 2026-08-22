--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — targeted verification for three bug fixes
--
-- Narrow companion to FeatureSuite: re-tests ONLY the bugs that suite surfaced and
-- that have since been fixed, so the loop is ~20s instead of ~120s. Once these all
-- pass, delete their [KNOWN] entries in FeatureSuite and retire this file.
--
--   1. Cast:Terminate() fires OnTerminated  (was silent on BOTH solvers)
--        The simulation paths each fire the signal before calling _Terminate, so
--        the shared Terminate() doesn't. Cast:Terminate() was the one caller with
--        no such prologue, so manual termination tore down silently.
--
--   2. FireTravelEvents gates OnTravel on serial  (serial ignored the flag)
--        Parallel gates upstream (the worker never ships the record). Serial called
--        straight through to FireOnTravel, so the flag did nothing on Vetra.new().
--
--   3. OnHomingDisengaged fires on serial  (transition was unreachable)
--        Homing.IsActive ALSO checked `HomingElapsed >= HomingMaxDuration`, and
--        callers use IsActive to decide whether to call StepHoming at all. So on
--        the expiry frame the cast was gated out before reaching StepHoming's
--        disengage branch — making its FireOnHomingDisengaged dead code.
--
-- Each check runs on both solvers: these were divergence bugs, and the point is
-- that both paths now agree.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 72)

local Passes, Fails = 0, 0
local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("    [PASS] %-42s %s", name, detail))
	else
		Fails += 1
		warn(string.format("    [FAIL] %-42s %s", name, detail))
	end
end

local function section(title: string)
	print(BAR)
	print("  " .. title)
	print(BAR)
end

local Scene = Instance.new("Folder")
Scene.Name   = "VetraFixVerifyScene"
Scene.Parent = workspace

local function sceneParams(): RaycastParams
	local P = RaycastParams.new()
	P.FilterType = Enum.RaycastFilterType.Include
	P.FilterDescendantsInstances = { Scene }
	return P
end

-- Parallel workers boot asynchronously; firing before they're up loses the first
-- steps.
local WORKER_BOOT = 1.5

local function fire(Solver: any, origin: Vector3, dir: Vector3, speed: number, behavior: any): any
	local Ctx = Vetra.BulletContext.new({ Origin = origin, Direction = dir, Speed = speed })
	return Solver:Fire(Ctx, behavior)
end

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

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1 — Cast:Terminate() fires OnTerminated
-- ─────────────────────────────────────────────────────────────────────────────
local function testManualTerminate()
	section("FIX 1: Cast:Terminate() fires OnTerminated")

	local S, P = bothSolvers(function(Solver)
		local R = { Term = 0, AliveAfter = true }
		Solver:GetSignals().OnTerminated:Connect(function() R.Term += 1 end)

		local Cast = fire(Solver, Vector3.new(0, 2500, 0), Vector3.new(1, 0, 0), 200, {
			MaxDistance   = 1e5,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})
		task.wait(0.5)
		Cast:Terminate()
		task.wait(0.5)
		R.AliveAfter = Cast.Alive
		return R
	end)

	check("Terminate fires OnTerminated (serial)",   S.Term == 1, string.format("count=%d", S.Term))
	check("Terminate fires OnTerminated (parallel)", P.Term == 1, string.format("count=%d", P.Term))
	check("cast is dead after (serial)",   S.AliveAfter == false, string.format("Alive=%s", tostring(S.AliveAfter)))
	check("cast is dead after (parallel)", P.AliveAfter == false, string.format("Alive=%s", tostring(P.AliveAfter)))

	-- Guard the fix's specific risk: the signal is now fired from Cast:Terminate AND
	-- from every simulation path. If those ever overlap, a naturally-terminating cast
	-- double-fires. This shoots a wall so termination comes from the sim path.
	local Wall = Instance.new("Part")
	Wall.Anchored, Wall.CanCollide = true, false
	Wall.Size     = Vector3.new(4, 200, 200)
	Wall.Position = Vector3.new(300, 2600, 0)
	Wall.Parent   = Scene

	local SNat, PNat = bothSolvers(function(Solver)
		local Count = 0
		Solver:GetSignals().OnTerminated:Connect(function() Count += 1 end)
		fire(Solver, Vector3.new(0, 2600, 0), Vector3.new(1, 0, 0), 500, {
			MaxDistance   = 1e4,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})
		task.wait(1.5)
		return Count
	end)

	check("natural terminate fires once (serial)",   SNat == 1, string.format("count=%d (must not double-fire)", SNat))
	check("natural terminate fires once (parallel)", PNat == 1, string.format("count=%d (must not double-fire)", PNat))

	Wall:Destroy()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2 — FireTravelEvents gates OnTravel on serial
-- ─────────────────────────────────────────────────────────────────────────────
local function testTravelGate()
	section("FIX 2: FireTravelEvents gates OnTravel")

	local function run(enabled: boolean, batch: boolean)
		return bothSolvers(function(Solver)
			local R = { Travel = 0, Batches = 0 }
			Solver:GetSignals().OnTravel:Connect(function() R.Travel += 1 end)
			Solver:GetSignals().OnTravelBatch:Connect(function(b)
				R.Batches += 1
				R.Travel  += #b
			end)
			fire(Solver, Vector3.new(0, 3000, 0), Vector3.new(1, 0, 0), 300, {
				MaxDistance      = 1e5,
				Gravity          = Vector3.new(0, -0.001, 0),
				RaycastParams    = sceneParams(),
				MaxBounces       = 0,
				FireTravelEvents = enabled,
				BatchTravel      = batch,
			})
			task.wait(1.2)
			return R
		end)
	end

	local SOn,  POn  = run(true, false)
	local SOff, POff = run(false, false)

	check("travel ON still fires (serial)",   SOn.Travel > 5,   string.format("count=%d", SOn.Travel))
	check("travel ON still fires (parallel)", POn.Travel > 5,   string.format("count=%d", POn.Travel))
	check("travel OFF is silent (serial)",    SOff.Travel == 0, string.format("count=%d", SOff.Travel))
	check("travel OFF is silent (parallel)",  POff.Travel == 0, string.format("count=%d", POff.Travel))

	-- The gate landed inside FireOnTravel, which is also the batching path's entry
	-- point — so BatchTravel must still work when the flag is on, and must go silent
	-- when it's off.
	local SBOn,  PBOn  = run(true, true)
	local SBOff, PBOff = run(false, true)

	check("batch ON still fires (serial)",   SBOn.Batches > 0,   string.format("batches=%d", SBOn.Batches))
	check("batch ON still fires (parallel)", PBOn.Batches > 0,   string.format("batches=%d", PBOn.Batches))
	check("batch OFF is silent (serial)",    SBOff.Batches == 0, string.format("batches=%d", SBOff.Batches))
	check("batch OFF is silent (parallel)",  PBOff.Batches == 0, string.format("batches=%d", PBOff.Batches))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 3 — OnHomingDisengaged fires on serial
-- ─────────────────────────────────────────────────────────────────────────────
local function testHomingDisengage()
	section("FIX 3: OnHomingDisengaged fires at HomingMaxDuration")

	local Target = Vector3.new(0, 3500, 500)

	local S, P = bothSolvers(function(Solver)
		local R = { Disengaged = 0, MidDist = math.huge, Steered = false }
		Solver:GetSignals().OnHomingDisengaged:Connect(function() R.Disengaged += 1 end)

		-- Fired perpendicular to the target, so closing distance can only be homing.
		local Cast = fire(Solver, Vector3.new(-1200, 3500, 500), Vector3.new(0, 0, 1), 300, {
			MaxDistance            = 1e5,
			MinSpeed               = 0,
			Gravity                = Vector3.new(0, -0.001, 0),
			RaycastParams          = sceneParams(),
			MaxBounces             = 0,
			HomingMaxDuration      = 1.0,
			HomingPositionProvider = function() return Target end,
		})

		task.wait(0.6)   -- inside the duration: homing should still be steering
		R.MidDist = Cast.Alive and (Cast:GetPosition() - Target).Magnitude or math.huge
		R.Steered = R.MidDist < 1200

		task.wait(1.2)   -- well past expiry: the transition must have fired by now
		return R
	end)

	check("homing steers before expiry (serial)",   S.Steered, string.format("dist=%.0f (spawn 1200)", S.MidDist))
	check("homing steers before expiry (parallel)", P.Steered, string.format("dist=%.0f (spawn 1200)", P.MidDist))
	-- Exactly once. The IsActive fix removed a gate that made this unreachable on
	-- serial; the risk on the other side is the latch failing and re-firing.
	check("OnHomingDisengaged fires once (serial)",   S.Disengaged == 1, string.format("count=%d", S.Disengaged))
	check("OnHomingDisengaged fires once (parallel)", P.Disengaged == 1, string.format("count=%d", P.Disengaged))

	-- Homing with no expiry must never disengage: guards IsActive still honouring
	-- the latch rather than the elapsed check I removed.
	local SNo, PNo = bothSolvers(function(Solver)
		local Count = 0
		Solver:GetSignals().OnHomingDisengaged:Connect(function() Count += 1 end)
		fire(Solver, Vector3.new(-1200, 3800, 900), Vector3.new(0, 0, 1), 300, {
			MaxDistance            = 1e5,
			MinSpeed               = 0,
			Gravity                = Vector3.new(0, -0.001, 0),
			RaycastParams          = sceneParams(),
			MaxBounces             = 0,
			HomingMaxDuration      = 0,     -- 0 = never expire
			HomingPositionProvider = function() return Vector3.new(0, 3800, 900) end,
		})
		task.wait(1.5)
		return Count
	end)

	check("no expiry -> no disengage (serial)",   SNo == 0, string.format("count=%d", SNo))
	check("no expiry -> no disengage (parallel)", PNo == 0, string.format("count=%d", PNo))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RUN
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print(BAR)
print("  Vetra — FIX VERIFICATION  (3 fixes, both solvers)")
print(BAR)

local Start = os.clock()

for _, Entry in {
	{ name = "ManualTerminate", fn = testManualTerminate },
	{ name = "TravelGate",      fn = testTravelGate },
	{ name = "HomingDisengage", fn = testHomingDisengage },
} do
	local Ok, Err = pcall(Entry.fn)
	if not Ok then
		Fails += 1
		warn(string.format("  [ERROR] %s — %s", Entry.name, tostring(Err)))
	end
end

Scene:Destroy()

print("")
print(BAR)
print(string.format("  RESULTS: %d passed, %d failed  (%.1fs)", Passes, Fails, os.clock() - Start))
if Fails == 0 then
	print("  All three fixes verified. Remove their [KNOWN] entries from FeatureSuite.")
end
print(BAR)
print("")
