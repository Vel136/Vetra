--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Cast methods on the PARALLEL path — verification checklist
--
-- Covers the four fixes to Cast:* methods when the solver is Vetra.newParallel():
--   A1  Getters (GetPosition/GetVelocity/GetAcceleration) track the in-flight
--       bullet instead of returning frozen spawn state.
--   B1  Setters (SetVelocity / SetPosition / AddVelocity / …) actually redirect
--       the worker-side simulation instead of being silent no-ops.
--   B3  ResetPierceState restores the raycast filter on the worker.
--   6D  6DOF is simulated on the parallel worker (was a silent no-op): the body
--       orientation integrates and syncs back to Cast.Runtime.Orientation.
--
-- HOW TO RUN
--   Place under a Script/LocalScript that requires this file, or paste into the
--   command bar while the `src` model is under ReplicatedStorage. Read the console:
--   each section prints [PASS] / [FAIL] with the observed numbers.
--
-- WHY task.wait(1) FIRST
--   newParallel() spins up worker Actors asynchronously; casts fired before the
--   workers are ready are queued. We wait so the first cast steps immediately.
--
-- NOTE ON GETTERS
--   Getters read main-thread Cast.Runtime, which the parallel solver refreshes
--   analytically (local clock) + on segment changes (TrajUpdate). A dragless shot
--   is interpolated forward from spawn; a drag/6DOF shot also gets segment syncs.
--   Values are ~1 frame stale by design (same latency as all parallel output).
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

local BAR = string.rep("─", 68)

local Passes = 0
local Fails  = 0
local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("  [PASS] %-34s %s", name, detail))
	else
		Fails += 1
		warn(string.format("  [FAIL] %-34s %s", name, detail))
	end
end

local function approx(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= tol
end

-- ══════════════════════════════════════════════════════════════════════════════
print(BAR)
print("Vetra — Cast methods on parallel — verification")
print(BAR)

local Solver = Vetra.newParallel()

task.wait(1) -- let workers start

-- ──────────────────────────────────────────────────────────────────────────────
-- A1  GETTERS — position advances downrange (not frozen at spawn)
-- Fire a horizontal, dragless, gravity-free shot so the analytic position is a
-- clean straight line: expected X after t seconds ≈ Origin.X + Speed * t.
-- ──────────────────────────────────────────────────────────────────────────────
do
	local SPEED  = 200
	local ORIGIN = Vector3.new(0, 500, 0)
	local ctx = Vetra.BulletContext.new({
		Origin    = ORIGIN,
		Direction = Vector3.new(1, 0, 0),
		Speed     = SPEED,
	})
	-- NOTE: Gravity = Vector3.zero is REJECTED by Fire (magnitude 0 falls back to
	-- workspace.Gravity). Use a near-zero nonzero vector to actually get a flat shot.
	local Cast = Solver:Fire(ctx, {
		Gravity                 = Vector3.new(0, -0.0001, 0),
		DragCoefficient         = 0,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		MaxBounces              = 0,
		BounceSpeedThreshold    = 1e9,
		HighFidelitySegmentSize = 0,
	})

	local p0 = Cast:GetPosition()
	local WAIT = 0.5
	task.wait(WAIT)
	local p1 = Cast:GetPosition()
	local v1 = Cast:GetVelocity()

	-- Position must advance downrange AND at roughly the right rate (the clock-hitch
	-- bug made this read ~7x too fast: |v| ≈ 720 instead of 200).
	local movedX   = p1.X - p0.X
	local expectMin = SPEED * WAIT * 0.5   -- ≥ half the ideal progress (loose lower bound)
	local expectMax = SPEED * WAIT * 2.0   -- but NOT wildly more (catches clock over-advance)
	check("getter: position advances", movedX >= expectMin and movedX <= expectMax,
		string.format("ΔX=%.1f over %.1fs (expected %.0f–%.0f; frozen=0, hitch-bug≫max)",
			movedX, WAIT, expectMin, expectMax))
	check("getter: velocity ≈ speed", approx(v1.Magnitude, SPEED, SPEED * 0.15),
		string.format("|v|=%.1f (expected ≈ %d ±15%%)", v1.Magnitude, SPEED))

	Cast:Terminate()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- B1  SETTERS — SetVelocity redirects the worker simulation.
-- Fire along +X, then flip to +Z. If setters were no-ops (old bug) the bullet
-- keeps going +X and its Z barely changes. If they propagate, Z grows and X stalls.
-- We observe via FireTravelEvents so we get authoritative worker positions.
-- ──────────────────────────────────────────────────────────────────────────────
do
	local SPEED  = 200
	local last: Vector3? = nil
	local sig = Solver:GetSignals()
	local conn = sig.OnTravel:Connect(function(_Context, Position: Vector3)
		last = Position   -- authoritative worker position (not the getter)
	end)

	local ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, 500, 0),
		Direction = Vector3.new(1, 0, 0),
		Speed     = SPEED,
	})
	local Cast = Solver:Fire(ctx, {
		Gravity                 = Vector3.zero,
		DragCoefficient         = 0,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		MaxBounces              = 0,
		BounceSpeedThreshold    = 1e9,
		HighFidelitySegmentSize = 0,
		FireTravelEvents        = true,   -- authoritative worker position each frame
	})

	task.wait(0.4)
	local beforeZ = (last or Vector3.zero).Z

	Cast:SetVelocity(Vector3.new(0, 0, SPEED))   -- redirect to +Z
	task.wait(0.4)
	local afterZ = (last or Vector3.zero).Z

	local zGain = afterZ - beforeZ
	local expectZ = SPEED * 0.25   -- should travel a good chunk of +Z in ~0.4s
	check("setter: SetVelocity redirects", zGain >= expectZ,
		string.format("ΔZ after redirect=%.1f (expected ≥ %.1f; no-op bug ≈ 0)", zGain, expectZ))

	conn:Disconnect()
	Cast:Terminate()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- B3  ResetPierceState — smoke test: calling it on a parallel cast must not error
-- and must leave the cast alive and simulating. (Full filter-restore behavior is
-- exercised by the pierce feature tests; here we confirm the parallel wiring path
-- Cast:ResetPierceState -> Coordinator:_UpdateFilter doesn't throw.)
-- ──────────────────────────────────────────────────────────────────────────────
do
	local ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, 500, 0),
		Direction = Vector3.new(1, 0, 0),
		Speed     = 150,
	})
	local Cast = Solver:Fire(ctx, {
		Gravity                 = Vector3.zero,
		DragCoefficient         = 0,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		MaxBounces              = 0,
		BounceSpeedThreshold    = 1e9,
		HighFidelitySegmentSize = 0,
		MaxPierceCount          = 5,
		PierceSpeedThreshold    = 0,
		CanPierceFunction       = function() return true end,
	})

	task.wait(0.2)
	local ok = pcall(function() Cast:ResetPierceState() end)
	task.wait(0.2)
	check("ResetPierceState: no error on parallel", ok and Cast.Alive == true,
		ok and "call returned, cast still alive" or "threw an error")

	Cast:Terminate()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- 6D  6DOF simulates on parallel — orientation must CHANGE from spawn.
-- Fire a spin-stabilized round at an angle of attack (initial orientation offset
-- from velocity) so the aero torque rotates the body. If 6DOF ran (fixed), the
-- orientation drifts away from its initial value; if it's the old silent no-op,
-- GetOrientation() stays exactly at the spawn orientation forever.
-- ──────────────────────────────────────────────────────────────────────────────
do
	-- Velocity points +X; start the body pitched 20° off so there's a nonzero AoA.
	local initialOrientation = CFrame.Angles(0, 0, 0) * CFrame.fromEulerAnglesYXZ(0, math.rad(20), 0)
	local ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, 500, 0),
		Direction = Vector3.new(1, 0, 0),
		Speed     = 400,
	})
	local Cast = Solver:Fire(ctx, {
		Gravity                 = Vector3.zero,
		DragCoefficient         = 0.001,   -- ensures drag-interval segments tick
		DragSegmentInterval     = 0.05,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		MaxBounces              = 0,
		BounceSpeedThreshold    = 1e9,
		HighFidelitySegmentSize = 0,

		SixDOFEnabled           = true,
		InitialOrientation      = initialOrientation,
		PitchingMomentSlope     = -2.0,    -- restoring moment -> body pitches toward velocity
		LiftCoefficientSlope    = 2.0,
		ReferenceArea           = 0.0005,
		ReferenceLength         = 0.03,
		AirDensity              = 1.225,
		MomentOfInertia         = 0.0001,
		SpinMOI                 = 0.00005,
		MaxAngularSpeed         = 200,
		BulletMass              = 0.01,
	})

	local o0 = Cast:GetOrientation()
	task.wait(0.6)
	local o1  = Cast:GetOrientation()
	local aoa = Cast:GetAngleOfAttack()

	-- Angular difference between spawn and current look vectors, in degrees.
	local dot   = math.clamp(o0.LookVector:Dot(o1.LookVector), -1, 1)
	local deltaDeg = math.deg(math.acos(dot))

	check("6DOF: orientation integrates on parallel", deltaDeg > 0.5,
		string.format("look vector moved %.2f° from spawn (no-op bug = 0.00°)", deltaDeg))
	check("6DOF: AngleOfAttack is populated", aoa == aoa and aoa >= 0,
		string.format("AoA=%.4f rad (%.2f°)", aoa, math.deg(aoa)))

	Cast:Terminate()
end

-- ══════════════════════════════════════════════════════════════════════════════
print(BAR)
print(string.format("RESULT: %d passed, %d failed", Passes, Fails))
if Fails == 0 then
	print("[ALL PASS] Cast methods behave correctly on the parallel solver.")
else
	warn(string.format("[%d FAILURE(S)] Investigate the sections marked [FAIL] above.", Fails))
end
print(BAR)

Solver:Destroy()
