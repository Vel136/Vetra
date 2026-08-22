--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Vetra — feature verification suite, part 2
--
-- Companion to FeatureSuite. Same design (run everything on BOTH solvers, assert
-- they agree — divergence is where this library's bugs live), covering what part 1
-- left out:
--
--   · The five mutating HOOKS: OnPreBounce, OnMidBounce, OnPrePierce, OnMidPierce,
--     OnPreTermination. Highest-value gap in the suite — these don't just report,
--     they rewrite normals/velocity/restitution mid-impact, so a divergence
--     silently changes physics instead of dropping an event.
--   · Hitscan — an entirely separate resolve path (ResolveHitscan) with no coverage.
--   · Fragmentation + OnBranchSpawned
--   · Tumble + OnTumbleBegin / OnTumbleEnd
--   · Magnus / spin
--   · Wind + Coriolis
--   · Dynamic occupancy
--   · OnSegmentOpen
--   · MaxDisplacement
--   · Material restitution
--   · TrajectoryPositionProvider, CanHomeFunction
--
-- STILL NOT COVERED ANYWHERE (deliberate):
--   · CastFunction — serial-only by design; functions can't cross Actor boundaries.
--   · Cosmetic bullets — needs visual inspection, not assertions.
--   · Exact physics values — AccuracyTests owns the ballistics curves. This asserts
--     a feature RUNS and BEHAVES the same on both paths.
--   · Speed profiles, pierce depth/force/thickness, HomingAcquisitionRadius — these
--     tune existing paths rather than gate them; they'd need accuracy-style
--     assertions to be meaningful.
--
-- READING FAILURES
--   One solver but not the other = divergence bug (the common case here).
--   Both = more likely this test's geometry or thresholds. Check the test first.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 72)

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
Scene.Name   = "VetraFeatureSuite2Scene"
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

local function sceneParams(): RaycastParams
	local P = RaycastParams.new()
	P.FilterType = Enum.RaycastFilterType.Include
	P.FilterDescendantsInstances = { Scene }
	return P
end

local WORKER_BOOT = 1.5

local function fire(Solver: any, origin: Vector3, dir: Vector3, speed: number, behavior: any): (any, any)
	local Ctx = Vetra.BulletContext.new({ Origin = origin, Direction = dir, Speed = speed })
	local Cast = Solver:Fire(Ctx, behavior)
	return Cast, Ctx
end

local function bothSolvers(config: any?, body: (any, boolean) -> any): (any, any)
	local S = config and Vetra.new(config) or Vetra.new({})
	local SR = body(S, false)
	S:Destroy()

	local P = config and Vetra.newParallel(config) or Vetra.newParallel({})
	task.wait(WORKER_BOOT)
	local PR = body(P, true)
	P:Destroy()

	return SR, PR
end

-- Bounces are opt-in: both solvers gate on `CanBounce and EligibleForBounce`, and
-- with no CanBounceFunction that's nil (falsy), so hits are terminal. Any test that
-- wants a bounce must supply this.
local function allowBounce() return true end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. OnPreBounce — mutate the surface normal before reflection
-- ─────────────────────────────────────────────────────────────────────────────
local function testPreBounce()
	section("1. OnPreBounce hook (mutates normal)")

	makeWall(Vector3.new(0, 400, 0), Vector3.new(2000, 4, 2000), "PreBounceFloor")

	local function run(mutate: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Fired = 0, PostVel = nil :: Vector3? }

			Solver:GetSignals().OnPreBounce:Connect(function(_ctx, _hit, _vel, MutateData)
				R.Fired += 1
				if mutate then
					-- Tilt the floor's normal 45 degrees toward +X. Reflection is
					-- `v - 2(v·n)n`, so the mutated normal must have a component along
					-- the velocity to change anything: a pure +X normal against a purely
					-- -Y fall gives v·n = 0 and reflects to nothing. Tilted, the bounce
					-- gains real +X travel that a true floor normal can never produce.
					MutateData(Vector3.new(1, 1, 0).Unit, nil)
				end
			end)

			Solver:GetSignals().OnBounce:Connect(function(_ctx, _hit, postVel)
				R.PostVel = R.PostVel or postVel
			end)

			-- Fired at an ANGLE, not straight down. A vertical drop bounces back up the
			-- same line and re-hits the same spot, which is precisely what the
			-- corner-trap detector kills (CornerDisplacementThreshold 0.5 /
			-- CornerMinProgressPerBounce 0.3 — zero horizontal progress per bounce).
			-- The cast then terminates as CornerTrap instead of bouncing, and whether
			-- that lands before or after the first OnPreBounce is a frame-timing
			-- coin-flip — which read as a serial-vs-parallel divergence.
			fire(Solver, Vector3.new(0, 500, 0), Vector3.new(0.5, -1, 0), 300, {
				MaxDistance          = 1e5,
				MinSpeed             = 0,
				RaycastParams        = sceneParams(),
				MaxBounces           = 3,
				Restitution          = 0.9,
				BounceSpeedThreshold = 0,
				CanBounceFunction    = allowBounce,
			})
			task.wait(2)
			return R
		end)
	end

	local SPlain, PPlain = run(false)
	check("OnPreBounce fires (serial)",   SPlain.Fired > 0, string.format("count=%d", SPlain.Fired))
	check("OnPreBounce fires (parallel)", PPlain.Fired > 0, string.format("count=%d", PPlain.Fired))

	if SPlain.PostVel then
		check("un-mutated bounce goes up (serial)", SPlain.PostVel.Y > 0,
			string.format("postVel.Y=%.1f", SPlain.PostVel.Y))
	end
	if PPlain.PostVel then
		check("un-mutated bounce goes up (parallel)", PPlain.PostVel.Y > 0,
			string.format("postVel.Y=%.1f", PPlain.PostVel.Y))
	end

	-- Compared against the un-mutated run rather than a fixed number: the shot is
	-- angled, so a true floor normal already yields some +X. The mutated normal tilts
	-- the reflection much further along +X, so the difference is the signal.
	local SMut, PMut = run(true)
	if SMut.PostVel and SPlain.PostVel then
		check("mutated normal redirects (serial)",
			math.abs(SMut.PostVel.X) > math.abs(SPlain.PostVel.X) + 50,
			string.format("mutated |X|=%.1f vs plain |X|=%.1f",
				math.abs(SMut.PostVel.X), math.abs(SPlain.PostVel.X)))
	else
		check("mutated normal redirects (serial)", false, "no bounce observed in one of the runs")
	end
	if PMut.PostVel and PPlain.PostVel then
		check("mutated normal redirects (parallel)",
			math.abs(PMut.PostVel.X) > math.abs(PPlain.PostVel.X) + 50,
			string.format("mutated |X|=%.1f vs plain |X|=%.1f",
				math.abs(PMut.PostVel.X), math.abs(PPlain.PostVel.X)))
	else
		check("mutated normal redirects (parallel)", false, "no bounce observed in one of the runs")
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. OnMidBounce — mutate restitution after reflection
-- ─────────────────────────────────────────────────────────────────────────────
local function testMidBounce()
	section("2. OnMidBounce hook (mutates restitution)")

	makeWall(Vector3.new(0, 400, 1000), Vector3.new(2000, 4, 2000), "MidBounceFloor")

	local function run(restitution: number?)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Fired = 0, PostSpeed = nil :: number? }

			Solver:GetSignals().OnMidBounce:Connect(function(_ctx, _hit, _postVel, MutateData)
				R.Fired += 1
				if restitution then MutateData(nil, restitution, nil) end
			end)
			Solver:GetSignals().OnBounce:Connect(function(_ctx, _hit, postVel)
				R.PostSpeed = R.PostSpeed or postVel.Magnitude
			end)

			fire(Solver, Vector3.new(0, 500, 1000), Vector3.new(0, -1, 0), 300, {
				MaxDistance          = 1e5,
				MinSpeed             = 0,
				RaycastParams        = sceneParams(),
				MaxBounces           = 3,
				Restitution          = 0.9,   -- hook overrides this when set
				BounceSpeedThreshold = 0,
				CanBounceFunction    = allowBounce,
			})
			task.wait(2)
			return R
		end)
	end

	local SHigh, PHigh = run(nil)     -- behavior default 0.9
	local SLow,  PLow  = run(0.1)     -- hook forces 0.1

	check("OnMidBounce fires (serial)",   SHigh.Fired > 0, string.format("count=%d", SHigh.Fired))
	check("OnMidBounce fires (parallel)", PHigh.Fired > 0, string.format("count=%d", PHigh.Fired))

	-- A restitution of 0.1 must retain far less speed than 0.9. If the hook's value
	-- were ignored, both runs would land on the same post-bounce speed.
	if SHigh.PostSpeed and SLow.PostSpeed then
		check("mutated restitution applies (serial)", SLow.PostSpeed < SHigh.PostSpeed * 0.5,
			string.format("r=0.1 -> %.1f vs r=0.9 -> %.1f", SLow.PostSpeed, SHigh.PostSpeed))
	else
		check("mutated restitution applies (serial)", false, "no bounce observed")
	end
	if PHigh.PostSpeed and PLow.PostSpeed then
		check("mutated restitution applies (parallel)", PLow.PostSpeed < PHigh.PostSpeed * 0.5,
			string.format("r=0.1 -> %.1f vs r=0.9 -> %.1f", PLow.PostSpeed, PHigh.PostSpeed))
	else
		check("mutated restitution applies (parallel)", false, "no bounce observed")
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. OnPrePierce / OnMidPierce
-- ─────────────────────────────────────────────────────────────────────────────
local function testPierceHooks()
	section("3. OnPrePierce / OnMidPierce hooks")

	for i = 1, 3 do
		makeWall(Vector3.new(200 * i, 500, 2000), Vector3.new(2, 100, 100), "PierceHookWall" .. i)
	end

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Pre = 0, Mid = 0 }
		Solver:GetSignals().OnPrePierce:Connect(function() R.Pre += 1 end)
		Solver:GetSignals().OnMidPierce:Connect(function() R.Mid += 1 end)

		fire(Solver, Vector3.new(0, 500, 2000), Vector3.new(1, 0, 0), 900, {
			MaxDistance          = 1e4,
			Gravity              = Vector3.new(0, -0.001, 0),
			RaycastParams        = sceneParams(),
			MaxBounces           = 0,
			MaxPierceCount       = 5,
			PierceSpeedThreshold = 0,
			CanPierceFunction    = function() return true end,
		})
		task.wait(2)
		return R
	end)

	check("OnPrePierce fires (serial)",   S.Pre > 0, string.format("count=%d", S.Pre))
	check("OnPrePierce fires (parallel)", P.Pre > 0, string.format("count=%d", P.Pre))
	check("OnMidPierce fires (serial)",   S.Mid > 0, string.format("count=%d", S.Mid))
	check("OnMidPierce fires (parallel)", P.Mid > 0, string.format("count=%d", P.Mid))
	-- Both must be non-zero before "agree" means anything: a bare tolerance lets a
	-- 1-vs-0 divergence pass as agreement.
	check("pierce hook counts agree",
		S.Pre > 0 and P.Pre > 0 and math.abs(S.Pre - P.Pre) <= 1,
		string.format("serial=%d parallel=%d", S.Pre, P.Pre))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. OnPreTermination — cancel, and the 3-strike force-terminate
-- ─────────────────────────────────────────────────────────────────────────────
local function testPreTermination()
	section("4. OnPreTermination hook (cancel + 3-strike escape)")

	makeWall(Vector3.new(300, 500, 3000), Vector3.new(4, 200, 200), "PreTermWall")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Fired = 0, Terminated = 0 }

		Solver:GetSignals().OnPreTermination:Connect(function(_ctx, _reason, MutateData)
			R.Fired += 1
			MutateData(true, nil)   -- cancel every time
		end)
		Solver:GetSignals().OnTerminated:Connect(function() R.Terminated += 1 end)

		-- Terminate on DISTANCE, not on a hit. The 3-strike escape counts cancels of
		-- the same reason, and the condition has to re-assert itself on later frames
		-- to rack them up. An over-distance cast re-trips every frame; a cancelled
		-- wall hit doesn't necessarily re-contact, so it only ever scored one strike.
		fire(Solver, Vector3.new(0, 500, 3000), Vector3.new(1, 0, 0), 500, {
			MaxDistance   = 200,
			Gravity       = Vector3.new(0, -0.001, 0),
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
		})
		task.wait(2)
		return R
	end)

	check("OnPreTermination fires (serial)",   S.Fired > 0, string.format("count=%d", S.Fired))
	check("OnPreTermination fires (parallel)", P.Fired > 0, string.format("count=%d", P.Fired))
	-- Cancelling is honoured but bounded: after 3 cancels of the same reason the
	-- solver force-terminates rather than let a bullet live forever.
	check("cancel is bounded, cast dies (serial)",   S.Terminated == 1,
		string.format("terminated=%d after %d cancels", S.Terminated, S.Fired))
	check("cancel is bounded, cast dies (parallel)", P.Terminated == 1,
		string.format("terminated=%d after %d cancels", P.Terminated, P.Fired))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. OnSegmentOpen
-- ─────────────────────────────────────────────────────────────────────────────
local function testSegmentOpen()
	section("5. OnSegmentOpen")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local Count = 0
		Solver:GetSignals().OnSegmentOpen:Connect(function() Count += 1 end)

		-- Drag reopens the segment every DragSegmentInterval, so this should fire
		-- repeatedly rather than only at spawn.
		fire(Solver, Vector3.new(0, 900, 4000), Vector3.new(1, 0, 0), 600, {
			MaxDistance     = 1e5,
			MinSpeed        = 0,
			Gravity         = Vector3.new(0, -0.001, 0),
			RaycastParams   = sceneParams(),
			MaxBounces      = 0,
			DragCoefficient = 4e-5,
		})
		task.wait(1.5)
		return Count
	end)

	check("OnSegmentOpen fires (serial)",   S > 0, string.format("count=%d", S))
	check("OnSegmentOpen fires (parallel)", P > 0, string.format("count=%d", P))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. HITSCAN — a wholly separate resolve path
-- ─────────────────────────────────────────────────────────────────────────────
local function testHitscan()
	section("6. Hitscan")

	makeWall(Vector3.new(400, 500, 5000), Vector3.new(4, 200, 200), "HitscanWall")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Hit = 0, Term = 0, ResolvedSync = false }
		Solver:GetSignals().OnHit:Connect(function() R.Hit += 1 end)
		Solver:GetSignals().OnTerminated:Connect(function() R.Term += 1 end)

		local Cast = fire(Solver, Vector3.new(0, 500, 5000), Vector3.new(1, 0, 0), 1000, {
			MaxDistance   = 1e4,
			RaycastParams = sceneParams(),
			MaxBounces    = 0,
			IsHitscan     = true,
		})
		-- Hitscan resolves the entire path inside Fire(), with no per-frame physics —
		-- so the cast is already dead before we ever yield.
		R.ResolvedSync = (Cast == nil) or (not Cast.Alive)

		task.wait(0.5)
		return R
	end)

	check("hitscan hits (serial)",   S.Hit == 1, string.format("count=%d", S.Hit))
	check("hitscan hits (parallel)", P.Hit == 1, string.format("count=%d", P.Hit))
	check("hitscan resolves inside Fire (serial)",   S.ResolvedSync, tostring(S.ResolvedSync))
	check("hitscan resolves inside Fire (parallel)", P.ResolvedSync, tostring(P.ResolvedSync))
	check("hitscan terminates (serial)",   S.Term == 1, string.format("count=%d", S.Term))
	check("hitscan terminates (parallel)", P.Term == 1, string.format("count=%d", P.Term))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. FRAGMENTATION + OnBranchSpawned
-- ─────────────────────────────────────────────────────────────────────────────
local function testFragmentation()
	section("7. Fragmentation + OnBranchSpawned")

	makeWall(Vector3.new(300, 500, 6000), Vector3.new(2, 200, 200), "FragWall")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Branches = 0, Fires = 0 }
		Solver:GetSignals().OnBranchSpawned:Connect(function() R.Branches += 1 end)
		Solver:GetSignals().OnFire:Connect(function() R.Fires += 1 end)

		fire(Solver, Vector3.new(0, 500, 6000), Vector3.new(1, 0, 0), 900, {
			MaxDistance          = 1e4,
			Gravity              = Vector3.new(0, -0.001, 0),
			RaycastParams        = sceneParams(),
			MaxBounces           = 0,
			PierceSpeedThreshold = 0,
			CanPierceFunction    = function() return true end,
			FragmentOnPierce     = true,
			FragmentCount        = 3,
			FragmentDeviation    = 15,
		})
		task.wait(2)
		return R
	end)

	check("OnBranchSpawned fires (serial)",   S.Branches > 0, string.format("count=%d", S.Branches))
	check("OnBranchSpawned fires (parallel)", P.Branches > 0, string.format("count=%d", P.Branches))
	-- Each fragment is itself a cast, so OnFire must exceed the single manual shot.
	check("fragments are real casts (serial)",   S.Fires > 1, string.format("OnFire count=%d", S.Fires))
	check("fragments are real casts (parallel)", P.Fires > 1, string.format("OnFire count=%d", P.Fires))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. TUMBLE + OnTumbleBegin / OnTumbleEnd
-- ─────────────────────────────────────────────────────────────────────────────
local function testTumble()
	section("8. Tumble + OnTumbleBegin / OnTumbleEnd")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Begin = 0, End = 0 }
		Solver:GetSignals().OnTumbleBegin:Connect(function() R.Begin += 1 end)
		Solver:GetSignals().OnTumbleEnd:Connect(function() R.End += 1 end)

		-- Spawn above the tumble threshold, then let drag drag it below: begin should
		-- fire on the way down through it.
		fire(Solver, Vector3.new(0, 1200, 7000), Vector3.new(1, 0, 0), 600, {
			MaxDistance          = 1e5,
			MinSpeed             = 0,
			Gravity              = Vector3.new(0, -0.001, 0),
			RaycastParams        = sceneParams(),
			MaxBounces           = 0,
			DragCoefficient      = 8e-5,
			TumbleSpeedThreshold = 580,   -- just under spawn speed
			TumbleDragMultiplier = 3.0,
			TumbleRecoverySpeed  = nil,
		})
		task.wait(2.5)
		return R
	end)

	check("OnTumbleBegin fires (serial)",   S.Begin > 0, string.format("count=%d", S.Begin))
	check("OnTumbleBegin fires (parallel)", P.Begin > 0, string.format("count=%d", P.Begin))
	-- Both must fire, THEN agree. A plain `abs(diff) <= 1` tolerance waves through
	-- exactly the divergence this exists to catch: 1-vs-0 passes it.
	check("tumble begin counts agree",
		S.Begin > 0 and P.Begin > 0 and math.abs(S.Begin - P.Begin) <= 1,
		string.format("serial=%d parallel=%d", S.Begin, P.Begin))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. MAGNUS / spin
-- ─────────────────────────────────────────────────────────────────────────────
local function testMagnus()
	section("9. Magnus / spin")

	local function run(magnus: number)
		return bothSolvers(nil, function(Solver, _p)
			local Cast = fire(Solver, Vector3.new(0, 1500, 8000), Vector3.new(1, 0, 0), 500, {
				MaxDistance       = 1e5,
				MinSpeed          = 0,
				Gravity           = Vector3.new(0, -0.001, 0),
				RaycastParams     = sceneParams(),
				MaxBounces        = 0,
				SpinVector        = Vector3.new(0, 200, 0),
				MagnusCoefficient = magnus,
				DragCoefficient   = 1e-5,   -- Magnus is applied during drag recalc
			})
			task.wait(1.5)
			return Cast.Alive and Cast:GetPosition() or nil
		end)
	end

	local SNo,  PNo  = run(0)
	local SYes, PYes = run(5e-5)

	-- Spin is +Y and travel is +X, so the Magnus force pushes along Z. Compare the
	-- Z deflection against a spin-free shot.
	if SNo and SYes then
		local Deflect = math.abs(SYes.Z - SNo.Z)
		check("Magnus deflects (serial)", Deflect > 1, string.format("dZ=%.2f studs", Deflect))
	else
		check("Magnus deflects (serial)", false, "cast died early")
	end
	if PNo and PYes then
		local Deflect = math.abs(PYes.Z - PNo.Z)
		check("Magnus deflects (parallel)", Deflect > 1, string.format("dZ=%.2f studs", Deflect))
	else
		check("Magnus deflects (parallel)", false, "cast died early")
	end
	if SYes and PYes then
		local d = (SYes - PYes).Magnitude
		check("Magnus agrees across solvers", d < 40, string.format("delta=%.2f studs", d))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. WIND + CORIOLIS
-- ─────────────────────────────────────────────────────────────────────────────
local function testWindCoriolis()
	section("10. Wind + Coriolis")

	local function run(wind: Vector3, coriolis: boolean)
		return bothSolvers(nil, function(Solver, _p)
			Solver:SetWind(wind)
			if coriolis then Solver:SetCoriolisConfig(45, 5000) end

			local Cast = fire(Solver, Vector3.new(0, 2000, 9000), Vector3.new(1, 0, 0), 400, {
				MaxDistance     = 1e5,
				MinSpeed        = 0,
				Gravity         = Vector3.new(0, -0.001, 0),
				RaycastParams   = sceneParams(),
				MaxBounces      = 0,
				WindResponse    = 1.0,
				DragCoefficient = 1e-5,   -- wind enters via the drag recalc path
			})
			task.wait(1.5)
			return Cast.Alive and Cast:GetPosition() or nil
		end)
	end

	local SNo,  PNo  = run(Vector3.zero, false)
	local SYes, PYes = run(Vector3.new(0, 0, 300), false)

	if SNo and SYes then
		local Deflect = math.abs(SYes.Z - SNo.Z)
		check("wind deflects (serial)", Deflect > 1, string.format("dZ=%.2f studs", Deflect))
	else
		check("wind deflects (serial)", false, "cast died early")
	end
	if PNo and PYes then
		local Deflect = math.abs(PYes.Z - PNo.Z)
		check("wind deflects (parallel)", Deflect > 1, string.format("dZ=%.2f studs", Deflect))
	else
		check("wind deflects (parallel)", false, "cast died early")
	end

	-- Coriolis is a genuinely tiny force at these speeds and distances (measured
	-- 0.15-2.8 studs over 1.5s, varying with frame timing). The bar is only "it moved
	-- the bullet at all" — anything tighter is measuring scheduler jitter, and the
	-- magnitude belongs in AccuracyTests, not here.
	local SCor, PCor = run(Vector3.zero, true)
	if SNo and SCor then
		local Deflect = (SCor - SNo).Magnitude
		check("Coriolis deflects (serial)", Deflect > 0.01, string.format("delta=%.3f studs", Deflect))
	end
	if PNo and PCor then
		local Deflect = (PCor - PNo).Magnitude
		check("Coriolis deflects (parallel)", Deflect > 0.01, string.format("delta=%.3f studs", Deflect))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. DYNAMIC OCCUPANCY
-- ─────────────────────────────────────────────────────────────────────────────
local function testDynamicOccupancy()
	section("11. Dynamic occupancy (correctness, not speed)")

	local Blocker = makeWall(Vector3.new(500, 500, 10000), Vector3.new(20, 200, 200), "DynOccBlocker")

	local DynGrid = Vetra.DynamicOccupancy.new(4)
	Vetra.DynamicOccupancy.Register(DynGrid, Blocker)
	Vetra.DynamicOccupancy.UpdateTransforms(DynGrid)

	local function run(useGrid: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local R = { Hit = 0, Pos = nil :: Vector3? }
			Solver:GetSignals().OnHit:Connect(function(_c, result)
				R.Hit += 1
				R.Pos = result and result.Position
			end)

			-- Dynamic occupancy tracks moving parts, so its transforms must be
			-- refreshed each frame or lookups read stale positions.
			local Conn
			if useGrid then
				Conn = RunService.Heartbeat:Connect(function()
					Vetra.DynamicOccupancy.UpdateTransforms(DynGrid)
				end)
			end

			local Behavior: any = {
				MaxDistance   = 1e4,
				Gravity       = Vector3.new(0, -0.001, 0),
				RaycastParams = sceneParams(),
				MaxBounces    = 0,
			}
			if useGrid then Behavior.DynamicOccupancy = DynGrid end

			fire(Solver, Vector3.new(0, 500, 10000), Vector3.new(1, 0, 0), 500, Behavior)
			task.wait(2)
			if Conn then Conn:Disconnect() end
			return R
		end)
	end

	local SOff, POff = run(false)
	local SOn,  POn  = run(true)

	-- The grid skips raycasts it can prove are clear. It must never change WHETHER a
	-- bullet hits — a miss here is the vacuous-clear class of bug (reporting a span
	-- clear when it isn't).
	check("dyn occupancy preserves hit (serial)",   SOn.Hit == SOff.Hit,
		string.format("with=%d without=%d", SOn.Hit, SOff.Hit))
	check("dyn occupancy preserves hit (parallel)", POn.Hit == POff.Hit,
		string.format("with=%d without=%d", POn.Hit, POff.Hit))

	if SOn.Pos and SOff.Pos then
		check("dyn occupancy same hit point (serial)", (SOn.Pos - SOff.Pos).Magnitude < 10,
			string.format("delta=%.2f", (SOn.Pos - SOff.Pos).Magnitude))
	end
	if POn.Pos and POff.Pos then
		check("dyn occupancy same hit point (parallel)", (POn.Pos - POff.Pos).Magnitude < 10,
			string.format("delta=%.2f", (POn.Pos - POff.Pos).Magnitude))
	end

	Vetra.DynamicOccupancy.Destroy(DynGrid)
	Blocker:Destroy()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. MaxDisplacement
-- ─────────────────────────────────────────────────────────────────────────────
local function testMaxDisplacement()
	section("12. MaxDisplacement")

	local S, P = bothSolvers(nil, function(Solver, _p)
		-- Only the count is asserted: the cast is already dead inside OnTerminated, so
		-- reading its position back through the context isn't reliable here.
		local R = { Term = 0 }
		Solver:GetSignals().OnTerminated:Connect(function() R.Term += 1 end)

		fire(Solver, Vector3.new(0, 2500, 11000), Vector3.new(1, 0, 0), 500, {
			MaxDistance     = 1e5,      -- distance must NOT be what kills it
			MaxDisplacement = 200,      -- straight-line from spawn
			Gravity         = Vector3.new(0, -0.001, 0),
			RaycastParams   = sceneParams(),
			MaxBounces      = 0,
		})
		task.wait(1.5)
		return R
	end)

	check("MaxDisplacement terminates (serial)",   S.Term == 1, string.format("count=%d", S.Term))
	check("MaxDisplacement terminates (parallel)", P.Term == 1, string.format("count=%d", P.Term))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. MATERIAL RESTITUTION
-- ─────────────────────────────────────────────────────────────────────────────
local function testMaterialRestitution()
	section("13. Material restitution")

	local Floor = makeWall(Vector3.new(0, 400, 12000), Vector3.new(2000, 4, 2000), "MatFloor")
	Floor.Material = Enum.Material.Metal

	local function run(useTable: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local R = { PostSpeed = nil :: number? }
			Solver:GetSignals().OnBounce:Connect(function(_ctx, _hit, postVel)
				R.PostSpeed = R.PostSpeed or postVel.Magnitude
			end)

			local Behavior: any = {
				MaxDistance          = 1e5,
				MinSpeed             = 0,
				RaycastParams        = sceneParams(),
				MaxBounces           = 2,
				Restitution          = 0.9,
				BounceSpeedThreshold = 0,
				CanBounceFunction    = allowBounce,
			}
			-- Key by the Enum.Material object, NOT a string. Serial indexes the map
			-- directly with the enum; the Coordinator converts the keys to strings
			-- itself before shipping to the worker (Actors can't carry enums). Passing
			-- strings looks reasonable and silently matches on neither path.
			if useTable then Behavior.MaterialRestitution = { [Enum.Material.Metal] = 0.1 } end

			fire(Solver, Vector3.new(0, 500, 12000), Vector3.new(0, -1, 0), 300, Behavior)
			task.wait(2)
			return R
		end)
	end

	local SPlain, PPlain = run(false)
	local SMat,   PMat   = run(true)

	if SPlain.PostSpeed and SMat.PostSpeed then
		check("material restitution applies (serial)", SMat.PostSpeed < SPlain.PostSpeed * 0.6,
			string.format("metal=%.1f default=%.1f", SMat.PostSpeed, SPlain.PostSpeed))
	else
		check("material restitution applies (serial)", false, "no bounce observed")
	end
	if PPlain.PostSpeed and PMat.PostSpeed then
		check("material restitution applies (parallel)", PMat.PostSpeed < PPlain.PostSpeed * 0.6,
			string.format("metal=%.1f default=%.1f", PMat.PostSpeed, PPlain.PostSpeed))
	else
		check("material restitution applies (parallel)", false, "no bounce observed")
	end

	Floor:Destroy()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. TrajectoryPositionProvider
-- ─────────────────────────────────────────────────────────────────────────────
local function testTrajectoryProvider()
	section("14. TrajectoryPositionProvider")

	-- A wall on the PROVIDER's path (+Z) but nowhere near the fired direction (+X).
	-- The provider supplies the positions the solver raycasts between, so if it's
	-- honoured the bullet hits this wall — a shot along its own +X heading never
	-- would. That's the observable: Cast:GetPosition() reconstructs analytically
	-- from ActiveTrajectory, which the provider never writes, so reading it back
	-- would show the kinematic path regardless and prove nothing.
	makeWall(Vector3.new(0, 3000, 13400), Vector3.new(400, 200, 4), "ProviderWall")

	local S, P = bothSolvers(nil, function(Solver, _p)
		local R = { Calls = 0, Hit = 0 }
		Solver:GetSignals().OnHit:Connect(function() R.Hit += 1 end)

		fire(Solver, Vector3.new(0, 3000, 13000), Vector3.new(1, 0, 0), 400, {
			MaxDistance                = 1e5,
			MinSpeed                   = 0,
			Gravity                    = Vector3.new(0, -0.001, 0),
			RaycastParams              = sceneParams(),
			MaxBounces                 = 0,
			TrajectoryPositionProvider = function(t: number)
				R.Calls += 1
				return Vector3.new(0, 3000, 13000 + t * 300)
			end,
		})
		task.wait(2)
		return R
	end)

	check("provider is called (serial)",   S.Calls > 0, string.format("calls=%d", S.Calls))
	check("provider is called (parallel)", P.Calls > 0, string.format("calls=%d", P.Calls))
	check("provider drives the raycast (serial)",   S.Hit == 1,
		string.format("hits=%d (wall only reachable via provider path)", S.Hit))
	check("provider drives the raycast (parallel)", P.Hit == 1,
		string.format("hits=%d (wall only reachable via provider path)", P.Hit))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. CanHomeFunction
-- ─────────────────────────────────────────────────────────────────────────────
local function testCanHome()
	section("15. CanHomeFunction")

	local Target = Vector3.new(0, 3500, 14500)

	local function run(allow: boolean)
		return bothSolvers(nil, function(Solver, _p)
			local Calls = 0
			local Cast = fire(Solver, Vector3.new(-1200, 3500, 14500), Vector3.new(0, 0, 1), 300, {
				MaxDistance            = 1e5,
				MinSpeed               = 0,
				Gravity                = Vector3.new(0, -0.001, 0),
				RaycastParams          = sceneParams(),
				MaxBounces             = 0,
				HomingMaxDuration      = 0,     -- never expire; isolate the gate
				HomingPositionProvider = function() return Target end,
				CanHomeFunction        = function()
					Calls += 1
					return allow
				end,
			})
			task.wait(1.2)
			local Dist = Cast.Alive and (Cast:GetPosition() - Target).Magnitude or math.huge
			return { Calls = Calls, Dist = Dist }
		end)
	end

	local SYes, PYes = run(true)
	local SNo,  PNo  = run(false)

	check("CanHomeFunction is called (serial)",   SYes.Calls > 0, string.format("calls=%d", SYes.Calls))
	check("CanHomeFunction is called (parallel)", PYes.Calls > 0, string.format("calls=%d", PYes.Calls))
	-- Returning false must veto steering: the bullet stays at its spawn radius.
	check("CanHome=false vetoes homing (serial)",   SNo.Dist > SYes.Dist,
		string.format("vetoed=%.0f allowed=%.0f", SNo.Dist, SYes.Dist))
	check("CanHome=false vetoes homing (parallel)", PNo.Dist > PYes.Dist,
		string.format("vetoed=%.0f allowed=%.0f", PNo.Dist, PYes.Dist))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RUN
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print(BAR)
print("  Vetra — FEATURE SUITE 2  (hooks, hitscan, and the rest)")
print(BAR)

local Start = os.clock()

local Suite: { { name: string, fn: () -> () } } = {
	{ name = "PreBounce",           fn = testPreBounce },
	{ name = "MidBounce",           fn = testMidBounce },
	{ name = "PierceHooks",         fn = testPierceHooks },
	{ name = "PreTermination",      fn = testPreTermination },
	{ name = "SegmentOpen",         fn = testSegmentOpen },
	{ name = "Hitscan",             fn = testHitscan },
	{ name = "Fragmentation",       fn = testFragmentation },
	{ name = "Tumble",              fn = testTumble },
	{ name = "Magnus",              fn = testMagnus },
	{ name = "WindCoriolis",        fn = testWindCoriolis },
	{ name = "DynamicOccupancy",    fn = testDynamicOccupancy },
	{ name = "MaxDisplacement",     fn = testMaxDisplacement },
	{ name = "MaterialRestitution", fn = testMaterialRestitution },
	{ name = "TrajectoryProvider",  fn = testTrajectoryProvider },
	{ name = "CanHome",             fn = testCanHome },
}

for _, Entry in Suite do
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
print(string.format("  RESULTS: %d passed, %d failed  (%.1fs)", Passes, Fails, os.clock() - Start))
if Fails > 0 then
	print("  Failed:")
	for _, Name in FailedNames do
		print("    · " .. Name)
	end
	print("")
	print("  A failure on ONE solver but not the other is a divergence bug.")
	print("  A failure on BOTH is more likely this test's geometry or thresholds.")
end
print(BAR)
print("")
