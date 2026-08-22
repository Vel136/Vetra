--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — feature verification suite, part 1 of 2
--
-- Runs each feature against BOTH solvers and asserts they agree. Divergence
-- between serial and parallel is where this library's bugs have historically
-- lived (a feature silently no-oping on one path), so almost every check here is
-- really a cross-solver equivalence check.
--
-- Part 1 covers the core loop and the common behaviors. FeatureSuite2 covers the
-- mutating hooks, hitscan, fragmentation, tumble, Magnus, wind/Coriolis, dynamic
-- occupancy, and the remaining providers. Run both.
--
-- HOW TO RUN
--   Require from a Script with `src` under ReplicatedStorage. Reads the console:
--   each check prints [PASS]/[FAIL] with observed numbers, and a summary lands at
--   the end. Non-zero FAIL count means a real regression.
--
-- HOW IT'S BUILT
--   Each test fires a small number of casts into purpose-built geometry, waits a
--   fixed window, and asserts on signal counts / final state. Tests are ordered
--   cheap-to-expensive. Everything cleans up after itself.
--
-- WHAT IT DELIBERATELY DOESN'T COVER
--   · CastFunction — documented as serial-only (functions can't cross Actors).
--   · Cosmetic bullets — needs visual inspection, not assertions.
--   · Exact physics values — that's AccuracyTests' job. This suite asserts a
--     feature RUNS and BEHAVES on both paths, not that drag matches a ballistics
--     table.
--
-- READING FAILURES
--   A [FAIL] on one solver but not the other is a divergence bug (the common
--   case). A [FAIL] on both usually means the test's geometry or thresholds are
--   wrong, not the library — check the test before the source.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 72)

-- ── Harness ──────────────────────────────────────────────────────────────────
local Passes, Fails = 0, 0
local FailedNames: { string } = {}

local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("    [PASS] %-38s %s", name, detail))
	else
		Fails += 1
		table.insert(FailedNames, name)
		warn(string.format("    [FAIL] %-38s %s", name, detail))
	end
end

-- Known open bugs, confirmed against the source. These print [KNOWN] instead of
-- [FAIL] so a red suite means a NEW regression, not this backlog. Delete an entry
-- when its bug is fixed — the check then has to pass like any other.
local Known = 0
local function checkKnown(name: string, ok: boolean, detail: string, issue: string)
	if ok then
		-- It started passing: someone fixed it and forgot to remove this entry.
		Passes += 1
		print(string.format("    [FIXED] %-37s %s  (remove the known-bug entry)", name, detail))
	else
		Known += 1
		print(string.format("    [KNOWN] %-37s %s  — %s", name, detail, issue))
	end
end

local function section(title: string)
	print(BAR)
	print("  " .. title)
	print(BAR)
end

-- Approximate equality for cross-solver comparison. Parallel output is one frame
-- late by design, so positions/counts never match serial exactly — these
-- tolerances are "the feature works on both", not "bit-identical".
local function near(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= tol
end

local function ratioNear(a: number, b: number, expected: number, tol: number): (boolean, number)
	if b == 0 then return false, math.huge end
	local r = a / b
	return math.abs(r - expected) <= tol, r
end

-- ── Scene ────────────────────────────────────────────────────────────────────
local Scene = Instance.new("Folder")
Scene.Name   = "VetraFeatureSuiteScene"
Scene.Parent = workspace

local function makeWall(position: Vector3, size: Vector3, name: string): BasePart
	local Part      = Instance.new("Part")
	Part.Name       = name
	Part.Anchored   = true
	Part.CanCollide = false
	Part.Size       = size
	Part.Position   = position
	Part.Parent     = Scene
	return Part
end

-- Params that only see our scene, so unrelated workspace geometry can't skew a run.
local function sceneParams(): RaycastParams
	local P = RaycastParams.new()
	P.FilterType = Enum.RaycastFilterType.Include
	P.FilterDescendantsInstances = { Scene }
	return P
end

local function newSolver(parallel: boolean, config: any?): any
	local Cfg = config or {}
	return parallel and Vetra.newParallel(Cfg) or Vetra.new(Cfg)
end

-- Parallel workers boot asynchronously; casts fired before they're up are queued
-- and the first steps are lost. Every parallel solver gets this beat before use.
local WORKER_BOOT = 1.5

local function fire(Solver: any, origin: Vector3, dir: Vector3, speed: number, behavior: any): (any, any)
	local Ctx = Vetra.BulletContext.new({
		Origin    = origin,
		Direction = dir,
		Speed     = speed,
	})
	
	local Cast = Solver:Fire(Ctx, behavior)
	
	return Cast, Ctx
end

-- Runs `body(Solver, isParallel)` against both solvers and hands back both results
-- so the caller can compare them. Each solver is destroyed before the next runs so
-- worker actors don't pile up across ~15 tests.
local function bothSolvers(config: any?, body: (any, boolean) -> any): (any, any)
	local SerialSolver = newSolver(false, config)
	local SerialResult = body(SerialSolver, false)
	SerialSolver:Destroy()

	local ParallelSolver = newSolver(true, config)
	task.wait(WORKER_BOOT)
	local ParallelResult = body(ParallelSolver, true)
	ParallelSolver:Destroy()

	return SerialResult, ParallelResult
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CORE — does a bullet fly, hit, and terminate on both paths?
-- ─────────────────────────────────────────────────────────────────────────────
local function testCore()
	section("1. Core: fire / travel / hit / terminate")

	makeWall(Vector3.new(300, 500, 0), Vector3.new(4, 200, 200), "CoreWall")

	local S, P = bothSolvers(nil, function(Solver, _isParallel)
		local Sig = Solver:GetSignals()
		local R = { Fire = 0, Travel = 0, Hit = 0, Term = 0, HitPos = nil :: Vector3? }

		Sig.OnFire:Connect(function() R.Fire += 1 end)
		Sig.OnTravel:Connect(function() R.Travel += 1 end)
		Sig.OnHit:Connect(function(_ctx, result)
			R.Hit += 1
			R.HitPos = result and result.Position
		end)
		Sig.OnTerminated:Connect(function() R.Term += 1 end)

		fire(Solver, Vector3.new(0, 500, 0), Vector3.new(1, 0, 0), 500, {
			MaxDistance      = 1e4,
			Gravity          = Vector3.new(0, -0.001, 0),  -- ~flat: aim straight at the wall
			RaycastParams    = sceneParams(),
			FireTravelEvents = true,
			MaxBounces       = 0,
		})
		task.wait(2)
		return R
	end)

	check("OnFire fires (serial)",    S.Fire == 1, string.format("count=%d", S.Fire))
	check("OnFire fires (parallel)",  P.Fire == 1, string.format("count=%d", P.Fire))
	check("OnTravel fires (serial)",   S.Travel > 5, string.format("count=%d", S.Travel))
	check("OnTravel fires (parallel)", P.Travel > 5, string.format("count=%d", P.Travel))
	check("OnHit fires (serial)",     S.Hit == 1, string.format("count=%d", S.Hit))
	check("OnHit fires (parallel)",   P.Hit == 1, string.format("count=%d", P.Hit))
	check("OnTerminated (serial)",    S.Term == 1, string.format("count=%d", S.Term))
	check("OnTerminated (parallel)",  P.Term == 1, string.format("count=%d", P.Term))

	if S.HitPos and P.HitPos then
		local d = (S.HitPos - P.HitPos).Magnitude
		check("hit position agrees", d < 15, string.format("delta=%.2f studs", d))
	else
		check("hit position agrees", false, "one solver never reported a hit")
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. FireTravelEvents — the flag gating per-frame OnTravel
-- ─────────────────────────────────────────────────────────────────────────────
local function testTravelEvents()
	section("2. FireTravelEvents gate")

	local function run(enabled: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local Count = 0
			Solver:GetSignals().OnTravel:Connect(function() Count += 1 end)
			fire(Solver, Vector3.new(0, 800, 0), Vector3.new(1, 0, 0), 300, {
				MaxDistance      = 1e4,
				RaycastParams    = sceneParams(),
				FireTravelEvents = enabled,
			})
			task.wait(1.5)
			return Count
		end)
	end

	local SOn,  POn  = run(true)
	local SOff, POff = run(false)

	check("travel events ON (serial)",    SOn > 5,   string.format("count=%d", SOn))
	check("travel events ON (parallel)",  POn > 5,   string.format("count=%d", POn))
	check("travel events OFF (serial)", SOff == 0, string.format("count=%d", SOff))
	-- Parallel FF casts drop travel results entirely; if this fires, the sync/FF
	-- classification leaked.
	check("travel events OFF (parallel)", POff == 0, string.format("count=%d", POff))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. BOUNCE — reflection, MaxBounces, CanBounceFunction gating
-- ─────────────────────────────────────────────────────────────────────────────
local function testBounce()
	section("3. Bounce")

	-- A floor to bounce off. The spawn sits close above it so the bullet reaches it
	-- within the sample window and still has speed left to rebound.
	makeWall(Vector3.new(0, 400, 500), Vector3.new(2000, 4, 2000), "BounceFloor")

	local function run(maxBounces: number, canBounce: (() -> boolean)?)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Bounce = 0, Term = 0 }
			Solver:GetSignals().OnBounce:Connect(function() R.Bounce += 1 end)
			Solver:GetSignals().OnTerminated:Connect(function() R.Term += 1 end)

			local Behavior: any = {
				MaxDistance          = 1e5,
				MinSpeed             = 0,
				MaxDisplacement      = 0,
				RaycastParams        = sceneParams(),
				MaxBounces           = maxBounces,
				Restitution          = 0.9,
				BounceSpeedThreshold = 0,
			}
			if canBounce then Behavior.CanBounceFunction = canBounce end

			-- Fired steeply down from 100 studs up: contact in ~0.25s, leaving the
			-- rest of the window for repeat bounces.
			fire(Solver, Vector3.new(0, 500, 500), Vector3.new(0.3, -1, 0), 300, Behavior)
			task.wait(3)
			return R
		end)
	end

	-- CanBounceFunction is REQUIRED for any bounce to happen. Both solvers gate on
	-- `CanBounce and EligibleForBounce`, and with no callback CanBounce is nil —
	-- falsy — so the hit is terminal. It reads like an optional filter but it's the
	-- opt-in: without it a bullet never bounces regardless of MaxBounces.
	local S3, P3 = run(3, function() return true end)
	check("bounces occur (serial)",   S3.Bounce > 0, string.format("count=%d", S3.Bounce))
	check("bounces occur (parallel)", P3.Bounce > 0, string.format("count=%d", P3.Bounce))
	check("MaxBounces respected (serial)",   S3.Bounce <= 3, string.format("count=%d (max 3)", S3.Bounce))
	check("MaxBounces respected (parallel)", P3.Bounce <= 3, string.format("count=%d (max 3)", P3.Bounce))

	-- CanBounceFunction returning false should veto every bounce -> cast terminates
	-- on first contact instead of reflecting.
	local SVeto, PVeto = run(5, function() return false end)
	check("CanBounce veto (serial)",   SVeto.Bounce == 0, string.format("bounces=%d", SVeto.Bounce))
	check("CanBounce veto (parallel)", PVeto.Bounce == 0, string.format("bounces=%d", PVeto.Bounce))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. PIERCE — CanPierceFunction, MaxPierceCount
-- ─────────────────────────────────────────────────────────────────────────────
local function testPierce()
	section("4. Pierce")

	for i = 1, 4 do
		makeWall(Vector3.new(200 * i, 500, 1000), Vector3.new(2, 100, 100), "PierceWall" .. i)
	end

	local function run(maxPierce: number)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Pierce = 0 }
			Solver:GetSignals().OnPierce:Connect(function() R.Pierce += 1 end)

			fire(Solver, Vector3.new(0, 500, 1000), Vector3.new(1, 0, 0), 900, {
				MaxDistance          = 1e4,
				Gravity              = Vector3.new(0, -0.001, 0),
				RaycastParams        = sceneParams(),
				MaxBounces           = 0,
				MaxPierceCount       = maxPierce,
				PierceSpeedThreshold = 0,
				CanPierceFunction    = function() return true end,
			})
			task.wait(2)
			return R
		end)
	end

	local S, P = run(4)
	check("pierces occur (serial)",   S.Pierce > 0, string.format("count=%d", S.Pierce))
	check("pierces occur (parallel)", P.Pierce > 0, string.format("count=%d", P.Pierce))
	-- Both must be non-zero before "agree" means anything: a bare tolerance lets a
	-- 1-vs-0 divergence pass as agreement.
	check("pierce counts agree",
		S.Pierce > 0 and P.Pierce > 0 and math.abs(S.Pierce - P.Pierce) <= 1,
		string.format("serial=%d parallel=%d", S.Pierce, P.Pierce))

	local SCap, PCap = run(2)
	check("MaxPierceCount cap (serial)",   SCap.Pierce <= 2, string.format("count=%d (max 2)", SCap.Pierce))
	check("MaxPierceCount cap (parallel)", PCap.Pierce <= 2, string.format("count=%d (max 2)", PCap.Pierce))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. DRAG — does it actually decelerate, and equally on both paths?
-- ─────────────────────────────────────────────────────────────────────────────
local function testDrag()
	section("5. Drag")

	-- The default DragModel is Quadratic: decel = Coefficient * Cd * Speed^2. At
	-- Speed=600 a "realistic-looking" Cd of 0.3 yields ~108,000 studs/s^2 and the
	-- bullet stops in one frame. This value is sized to bite visibly over ~2s.
	local DRAG = 4e-5

	local function run(drag: number)
		return bothSolvers(nil, function(Solver, _p)
			local Cast = fire(Solver, Vector3.new(0, 900, 2000), Vector3.new(1, 0, 0), 600, {
				MaxDistance     = 1e5,
				MinSpeed        = 0,
				Gravity         = Vector3.new(0, -0.001, 0),
				RaycastParams   = sceneParams(),
				DragCoefficient = drag,
				MaxBounces      = 0,
			})
			task.wait(2)
			local Speed = Cast.Alive and Cast:GetVelocity().Magnitude or -1
			return Speed
		end)
	end

	local SNo,  PNo  = run(0)
	local SYes, PYes = run(DRAG)

	check("dragless keeps speed (serial)",   near(SNo, 600, 30), string.format("speed=%.1f (spawn 600)", SNo))
	check("dragless keeps speed (parallel)", near(PNo, 600, 30), string.format("speed=%.1f (spawn 600)", PNo))
	-- Measured: 4e-5 sheds ~26 studs/s over 2s. The bar is "drag is demonstrably
	-- acting", not a specific curve — AccuracyTests owns the curve.
	check("drag decelerates (serial)",   SYes > 0 and SYes < 595, string.format("speed=%.1f (spawn 600)", SYes))
	check("drag decelerates (parallel)", PYes > 0 and PYes < 595, string.format("speed=%.1f (spawn 600)", PYes))
	check("drag agrees across solvers", near(SYes, PYes, 60),
		string.format("serial=%.1f parallel=%.1f", SYes, PYes))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. HOMING — steering, disengage, and the OnHomingDisengaged transition
-- ─────────────────────────────────────────────────────────────────────────────
local function testHoming()
	section("6. Homing")

	local Target = Vector3.new(0, 900, 3200)

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Disengaged = 0, FinalDist = math.huge }
		Solver:GetSignals().OnHomingDisengaged:Connect(function() R.Disengaged += 1 end)

		-- Fired perpendicular to the target so any closing distance is homing, not
		-- the initial aim.
		local Cast = fire(Solver, Vector3.new(-1500, 900, 3200), Vector3.new(0, 0, 1), 300, {
			MaxDistance            = 1e5,
			MinSpeed               = 0,
			Gravity                = Vector3.new(0, -0.001, 0),
			RaycastParams          = sceneParams(),
			MaxBounces             = 0,
			HomingMaxDuration      = 1.0,
			HomingPositionProvider = function() return Target end,
		})

		task.wait(0.6)  -- still inside HomingMaxDuration
		local MidDist = Cast.Alive and (Cast:GetPosition() - Target).Magnitude or math.huge
		task.wait(1.2)  -- past it: disengage must have fired
		R.FinalDist = MidDist
		return R
	end)

	check("homing steers toward target (serial)",   S.FinalDist < 1500,
		string.format("dist=%.0f (spawn 1500)", S.FinalDist))
	check("homing steers toward target (parallel)", P.FinalDist < 1500,
		string.format("dist=%.0f (spawn 1500)", P.FinalDist))
	-- Exactly once: the parallel disengage path ships one transition record, and a
	-- repeat here would mean the latch is re-firing every frame.
	check("OnHomingDisengaged once (serial)", S.Disengaged == 1, string.format("count=%d", S.Disengaged))
	check("OnHomingDisengaged once (parallel)", P.Disengaged == 1, string.format("count=%d", P.Disengaged))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. 6DOF — attitude integrates AND syncs back to the main thread
-- ─────────────────────────────────────────────────────────────────────────────
local function testSixDOF()
	section("7. 6DOF")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local Cast = fire(Solver, Vector3.new(0, 1200, 4000), Vector3.new(1, 0, 0), 800, {
			MaxDistance            = 1e5,
			MinSpeed               = 0,
			RaycastParams          = sceneParams(),
			MaxBounces             = 0,
			SixDOFEnabled          = true,
			InitialAngularVelocity = Vector3.new(30, 0, 0),
			MomentOfInertia        = 0.001,
			SpinMOI                = 0.001,
			ReferenceArea          = 0.01,
			ReferenceLength        = 0.1,
			LiftCoefficientSlope   = 2.0,
			PitchingMomentSlope    = -0.5,
			PitchDampingCoeff      = -0.1,
		})

		local Start = Cast.Alive and Cast:GetOrientation() or CFrame.identity
		task.wait(1.5)
		if not Cast.Alive then return { Moved = false, AngVel = 0 } end
		local Now = Cast:GetOrientation()
		-- Angle between the two forward vectors: nonzero means attitude integrated.
		local Dot   = Start.LookVector:Dot(Now.LookVector)
		local Angle = math.deg(math.acos(math.clamp(Dot, -1, 1)))
		return { Moved = Angle > 1, Angle = Angle, AngVel = Cast:GetAngularVelocity().Magnitude }
	end)

	check("orientation integrates (serial)",   S.Moved, string.format("rotated %.1f deg", S.Angle or 0))
	-- This is the check that catches 6DOF being a silent no-op on parallel, and the
	-- one that catches an FF trajectory-refresh record dropping the attitude.
	check("orientation integrates (parallel)", P.Moved, string.format("rotated %.1f deg", P.Angle or 0))
	check("angular velocity readable (serial)",   S.AngVel > 0, string.format("|w|=%.2f", S.AngVel))
	check("angular velocity readable (parallel)", P.AngVel > 0, string.format("|w|=%.2f", P.AngVel))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. LOD — 1-in-3 throttle beyond LODDistance
-- ─────────────────────────────────────────────────────────────────────────────
local function testLOD()
	section("8. LOD throttle")

	local LOD_DISTANCE = 3000

	local function run(parallel: boolean): number
		local Solver = newSolver(parallel)
		if parallel then task.wait(WORKER_BOOT) end
		Solver:SetLODOrigin(Vector3.new(0, 0, 0))

		local Counts: { [number]: number } = {}
		Solver:GetSignals().OnTravel:Connect(function(Ctx)
			Counts[Ctx.Id] = (Counts[Ctx.Id] or 0) + 1
		end)

		local function shoot(origin: Vector3)
			local Ctx = Vetra.BulletContext.new({
				Origin = origin, Direction = Vector3.new(1, 0, 0), Speed = 100,
			})
			Solver:Fire(Ctx, {
				MaxDistance      = 1e6,
				Gravity          = Vector3.new(0, -0.001, 0),  -- keep radius stable
				RaycastParams    = sceneParams(),
				LODDistance      = LOD_DISTANCE,
				FireTravelEvents = true,
				MaxBounces       = 0,
				-- MUST be 0. This test counts OnTravel to infer step rate, and serial
				-- fires it once per SimulateCast call — which HF makes ~N times per
				-- frame (once per sub-segment). A LOD'd cast skips HF entirely
				-- (UseHighFidelity requires `not IsLOD`), so with HF on we'd be
				-- comparing 1-every-3-frames against N-per-frame and reading the
				-- resulting ~0.09 as a broken throttle. It isn't: it's HF inflating the
				-- denominator. Parallel doesn't fire per sub-segment, which is why only
				-- serial looked wrong.
				HighFidelitySegmentSize = 0,
			})
			return Ctx.Id
		end

		local NearId = shoot(Vector3.new(0, 100, 0))       -- inside radius: full rate
		local FarId  = shoot(Vector3.new(0, 100, 5000))    -- outside: 1-in-3

		task.wait(1.5)
		local NearC, FarC = Counts[NearId] or 0, Counts[FarId] or 0
		Solver:Destroy()
		return NearC > 0 and (FarC / NearC) or math.huge
	end

	local SR = run(false)
	local PR = run(true)

	check("LOD throttles (serial)", SR >= 0.20 and SR <= 0.50, string.format("far/near=%.3f (want ~0.33)", SR))
	check("LOD throttles (parallel)", PR >= 0.20 and PR <= 0.50, string.format("far/near=%.3f (want ~0.33)", PR))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. SPEED THRESHOLDS
-- ─────────────────────────────────────────────────────────────────────────────
local function testSpeedThresholds()
	section("9. Speed thresholds")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Crossed = 0, Descending = 0 }
		-- Constants.THRESHOLD_DIRECTION is Ascending=true / Descending=false, so the
		-- direction arg is a plain boolean, not a string or enum.
		Solver:GetSignals().OnSpeedThresholdCrossed:Connect(function(_ctx, _threshold, direction)
			R.Crossed += 1
			if direction == false then R.Descending += 1 end
		end)

		fire(Solver, Vector3.new(0, 1500, 5000), Vector3.new(1, 0, 0), 600, {
			MaxDistance      = 1e5,
			MinSpeed         = 0,
			Gravity          = Vector3.new(0, -0.001, 0),
			RaycastParams    = sceneParams(),
			MaxBounces       = 0,
			DragCoefficient  = 4e-5,       -- decelerate through the thresholds
			SpeedThresholds  = { 500, 400 },
			FireTravelEvents = true,
		})
		task.wait(2.5)
		return R
	end)

	check("thresholds cross (serial)",   S.Crossed > 0, string.format("count=%d", S.Crossed))
	check("thresholds cross (parallel)", P.Crossed > 0, string.format("count=%d", P.Crossed))
	-- Both must be non-zero before "agree" means anything: a bare tolerance lets a
	-- 1-vs-0 divergence pass as agreement.
	check("threshold counts agree",
		S.Crossed > 0 and P.Crossed > 0 and math.abs(S.Crossed - P.Crossed) <= 1,
		string.format("serial=%d parallel=%d", S.Crossed, P.Crossed))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. OCCUPANCY — grid must not change outcomes, only cost
-- ─────────────────────────────────────────────────────────────────────────────
local function testOccupancy()
	section("10. Static occupancy (correctness, not speed)")

	local OccWall = makeWall(Vector3.new(600, 500, 6000), Vector3.new(8, 300, 300), "OccWall")

	local Grid = Vetra.StaticOccupancy.new(4)
	Vetra.VoxelBaker.BakeRegion(Grid, CFrame.new(Vector3.new(600, 500, 6000)), Vector3.new(200, 400, 400), {})
	
	local function run(useGrid: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Hit = 0, Pos = nil :: Vector3? }
			Solver:GetSignals().OnHit:Connect(function(_c, result)
				R.Hit += 1
				R.Pos = result and result.Position
			end)

			local Behavior: any = {
				MaxDistance   = 1e4,
				Gravity       = Vector3.new(0, -0.001, 0),
				RaycastParams = sceneParams(),
				MaxBounces    = 0,
			}
			if useGrid then Behavior.StaticOccupancy = Grid end

			fire(Solver, Vector3.new(0, 500, 6000), Vector3.new(1, 0, 0), 500, Behavior)
			task.wait(2)
			return R
		end)
	end

	local SOff, POff = run(false)
	local SOn,  POn  = run(true)

	-- The grid is a raycast-skipping optimization: it must never change whether or
	-- where a bullet hits. A miss here means the grid is reporting clear spans that
	-- aren't (the vacuous-clear class of bug).
	check("occupancy preserves hit (serial)",   SOn.Hit == SOff.Hit,
		string.format("with=%d without=%d", SOn.Hit, SOff.Hit))
	check("occupancy preserves hit (parallel)", POn.Hit == POff.Hit,
		string.format("with=%d without=%d", POn.Hit, POff.Hit))

	if SOn.Pos and SOff.Pos then
		local d = (SOn.Pos - SOff.Pos).Magnitude
		check("occupancy same hit point (serial)", d < 10, string.format("delta=%.2f", d))
	end
	if POn.Pos and POff.Pos then
		local d = (POn.Pos - POff.Pos).Magnitude
		check("occupancy same hit point (parallel)", d < 10, string.format("delta=%.2f", d))
	end

	OccWall:Destroy()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. HIGH FIDELITY — sub-stepping must not change the hit
-- ─────────────────────────────────────────────────────────────────────────────
local function testHighFidelity()
	section("11. High fidelity")

	makeWall(Vector3.new(400, 500, 7000), Vector3.new(4, 200, 200), "HFWall")

	local function run(hf: number)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Hit = 0, Pos = nil :: Vector3? }
			Solver:GetSignals().OnHit:Connect(function(_c, result)
				R.Hit += 1
				R.Pos = result and result.Position
			end)
			fire(Solver, Vector3.new(0, 500, 7000), Vector3.new(1, 0, 0), 700, {
				MaxDistance             = 1e4,
				Gravity                 = Vector3.new(0, -0.001, 0),
				RaycastParams           = sceneParams(),
				MaxBounces              = 0,
				HighFidelitySegmentSize = hf,
			})
			task.wait(2)
			return R
		end)
	end

	local SOff, POff = run(0)
	local SOn,  POn  = run(0.5)

	check("HF hits (serial)",   SOn.Hit == 1, string.format("count=%d", SOn.Hit))
	check("HF hits (parallel)", POn.Hit == 1, string.format("count=%d", POn.Hit))
	if SOn.Pos and SOff.Pos then
		local d = (SOn.Pos - SOff.Pos).Magnitude
		check("HF agrees with base (serial)", d < 10, string.format("delta=%.2f", d))
	end
	if POn.Pos and POff.Pos then
		local d = (POn.Pos - POff.Pos).Magnitude
		check("HF agrees with base (parallel)", d < 10, string.format("delta=%.2f", d))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. CAST METHODS — getters track flight, setters actually redirect
-- ─────────────────────────────────────────────────────────────────────────────
local function testCastMethods()
	section("12. Cast methods")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R: any = {}

		local Cast = fire(Solver, Vector3.new(0, 2000, 8000), Vector3.new(1, 0, 0), 400, {
			MaxDistance   = 1e5,
			MinSpeed      = 0,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})

		local P0 = Cast:GetPosition()
		task.wait(0.8)
		local P1 = Cast:GetPosition()
		R.Moved = (P1 - P0).Magnitude

		-- Setter: redirect to +Z. If the setter is a no-op the cast keeps going +X.
		Cast:SetVelocity(Vector3.new(0, 0, 400))
		task.wait(0.8)
		local P2 = Cast:GetPosition()
		R.ZDelta = math.abs(P2.Z - P1.Z)
		R.XDelta = math.abs(P2.X - P1.X)

		-- Pause freezes; Resume unfreezes
		
		Cast:Pause()
		local PP = Cast:GetPosition()
		task.wait(0.5)
		R.PausedDrift = (Cast:GetPosition() - PP).Magnitude
		Cast:Resume()
		task.wait(0.5)
		R.ResumedDrift = (Cast:GetPosition() - PP).Magnitude

		return R
	end)

	check("GetPosition tracks flight (serial)",   S.Moved > 50, string.format("moved %.0f studs", S.Moved))
	check("GetPosition tracks flight (parallel)", P.Moved > 50, string.format("moved %.0f studs", P.Moved))
	check("SetVelocity redirects (serial)",   S.ZDelta > S.XDelta,
		string.format("dZ=%.0f dX=%.0f", S.ZDelta, S.XDelta))
	check("SetVelocity redirects (parallel)", P.ZDelta > P.XDelta,
		string.format("dZ=%.0f dX=%.0f", P.ZDelta, P.XDelta))
	check("Pause freezes (serial)",   S.PausedDrift < 5, string.format("drift=%.2f", S.PausedDrift))
	check("Pause freezes (parallel)", P.PausedDrift < 5, string.format("drift=%.2f", P.PausedDrift))
	check("Resume unfreezes (serial)",   S.ResumedDrift > 50, string.format("drift=%.0f", S.ResumedDrift))
	check("Resume unfreezes (parallel)", P.ResumedDrift > 50, string.format("drift=%.0f", P.ResumedDrift))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. TERMINATION REASONS — MaxDistance / MinSpeed / Manual
-- ─────────────────────────────────────────────────────────────────────────────
local function testTermination()
	section("13. Termination")

	local function runDistance()
		return bothSolvers(nil, function(Solver, _p)
			local Term = 0
			Solver:GetSignals().OnTerminated:Connect(function() Term += 1 end)
			fire(Solver, Vector3.new(0, 2500, 9000), Vector3.new(1, 0, 0), 500, {
				MaxDistance   = 300,     -- ~0.6s of flight
				Gravity       = Vector3.new(0, -0.001, 0),
				RaycastParams = sceneParams(),
				MaxBounces    = 0,
			})
			task.wait(1.5)
			return Term
		end)
	end

	local SD, PD = runDistance()
	check("MaxDistance terminates (serial)",   SD == 1, string.format("count=%d", SD))
	check("MaxDistance terminates (parallel)", PD == 1, string.format("count=%d", PD))

	local SM, PM = bothSolvers(nil, function(Solver, _p)
		local Term = 0
		Solver:GetSignals().OnTerminated:Connect(function() Term += 1 end)
		local Cast = fire(Solver, Vector3.new(0, 2500, 9500), Vector3.new(1, 0, 0), 200, {
			MaxDistance   = 1e5,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})
		task.wait(0.5)
		Cast:Terminate()
		task.wait(0.5)
		return Term
	end)
	check("Terminate() fires OnTerminated (serial)",   SM == 1, string.format("count=%d", SM))
	check("Terminate() fires OnTerminated (parallel)", PM == 1, string.format("count=%d", PM))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. SUSPEND — SuspendFrame / SuspendTime / ClearSuspend
-- ─────────────────────────────────────────────────────────────────────────────
local function testSuspend()
	section("14. Suspend")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R: any = {}
		local Cast = fire(Solver, Vector3.new(0, 3000, 10000), Vector3.new(1, 0, 0), 400, {
			MaxDistance   = 1e5,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})
		task.wait(0.3)

		local Before = Cast:GetPosition()
		Cast:SuspendTime(0.5)
		R.IsSuspended = Cast:IsSuspended()
		task.wait(0.25)                       -- mid-suspend
		R.DuringDrift = (Cast:GetPosition() - Before).Magnitude
		task.wait(0.6)                        -- released + caught up
		R.AfterDrift  = (Cast:GetPosition() - Before).Magnitude
		return R
	end)

	check("IsSuspended reports (serial)",   S.IsSuspended == true, tostring(S.IsSuspended))
	check("IsSuspended reports (parallel)", P.IsSuspended == true, tostring(P.IsSuspended))
	check("suspend halts flight (serial)",   S.DuringDrift < 30, string.format("drift=%.1f", S.DuringDrift))
	checkKnown("suspend halts flight (parallel)", P.DuringDrift < 30, string.format("drift=%.1f", P.DuringDrift),
		"parallel GetPosition keeps interpolating during suspend (main-thread clock ignores the worker's pause)")
	check("suspend releases (serial)",   S.AfterDrift > 50, string.format("drift=%.0f", S.AfterDrift))
	check("suspend releases (parallel)", P.AfterDrift > 50, string.format("drift=%.0f", P.AfterDrift))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. BATCH TRAVEL — OnTravelBatch instead of per-cast OnTravel
-- ─────────────────────────────────────────────────────────────────────────────
local function testBatchTravel()
	section("15. Batch travel")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Batches = 0, Entries = 0 }
		Solver:GetSignals().OnTravelBatch:Connect(function(batch)
			R.Batches += 1
			R.Entries += #batch
		end)

		for _ = 1, 5 do
			fire(Solver, Vector3.new(0, 3500, 11000), Vector3.new(1, 0, 0), 300, {
				MaxDistance      = 1e5,
				Gravity          = Vector3.new(0, -0.001, 0),
				RaycastParams    = sceneParams(),
				MaxBounces       = 0,
				FireTravelEvents = true,
				BatchTravel      = true,
			})
		end
		task.wait(1.5)
		return R
	end)

	check("batch fires (serial)",   S.Batches > 0, string.format("batches=%d entries=%d", S.Batches, S.Entries))
	check("batch fires (parallel)", P.Batches > 0, string.format("batches=%d entries=%d", P.Batches, P.Entries))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RUN
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print(BAR)
print("  Vetra — FEATURE SUITE  (serial vs parallel equivalence)")
print(BAR)

local StartClock = os.clock()

local Suite: { { name: string, fn: () -> () } } = {
	{ name = "Core",             fn = testCore },
	{ name = "FireTravelEvents", fn = testTravelEvents },
	{ name = "Bounce",           fn = testBounce },
	{ name = "Pierce",           fn = testPierce },
	{ name = "Drag",             fn = testDrag },
	{ name = "Homing",           fn = testHoming },
	{ name = "SixDOF",           fn = testSixDOF },
	{ name = "LOD",              fn = testLOD },
	{ name = "SpeedThresholds",  fn = testSpeedThresholds },
	{ name = "Occupancy",        fn = testOccupancy },
	{ name = "HighFidelity",     fn = testHighFidelity },
	{ name = "CastMethods",      fn = testCastMethods },
	{ name = "Termination",      fn = testTermination },
	{ name = "Suspend",          fn = testSuspend },
	{ name = "BatchTravel",      fn = testBatchTravel },
}

for _, Entry in Suite do
	-- One test erroring shouldn't cost us the other fourteen results.
	local Ok, Err = pcall(Entry.fn)
	if not Ok then
		Fails += 1
		table.insert(FailedNames, Entry.name .. " (errored)")
		warn(string.format("  [ERROR] %s — %s", Entry.name, tostring(Err)))
	end
end

Scene:Destroy()

print("")
print(BAR)
print(string.format("  RESULTS: %d passed, %d failed, %d known-bug  (%.1fs)",
	Passes, Fails, Known, os.clock() - StartClock))
if Fails > 0 then
	print("  Failed:")
	for _, Name in FailedNames do
		print("    · " .. Name)
	end
	print("")
	print("  A failure on ONE solver but not the other is a divergence bug.")
	print("  A failure on BOTH is more likely the test's geometry or thresholds.")
else
	print("  No regressions. [KNOWN] lines above are pre-existing bugs this suite")
	print("  documents; fix one and its check flips to [FIXED].")
end
print(BAR)
print("")
