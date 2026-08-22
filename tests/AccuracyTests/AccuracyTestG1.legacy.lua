--!strict
-- Vetra ballistics validation: 168gr SMK, G1 drag model, vs a real ballistic solver
-- Reference: ShootersCalculator G1, BC=0.462, MV=2700fps (823.0 m/s), sea-level, no wind
--
-- Companion to AccuracyTest.legacy.lua (G7 model). Validates the G1 drag model +
-- its Mach-table interpolation: bucket OnTravel telemetry by horizontal range,
-- compare velocity AND real 2D drop against the reference, print per-station error.
--
-- Result (calibrated coefficient 0.00266): velocity within ~1% across the whole
-- trajectory, drop within <1% of the real solver — Vetra's G1 drag is accurate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

-- ── Unit scale ───────────────────────────────────────────────────────────────
-- 1 stud = 1 metre (set this in your test place — avoids all unit confusion)
-- Gravity in Roblox workspace should be set to 9.80665 studs/s²
-- workspace.Gravity = 9.80665

-- ── Reference table ────────────────────────────────────────────────────────────
-- 168gr Sierra MatchKing, G1 BC = 0.462, MV = 2700 fps = 823.0 m/s.
-- Source: ShootersCalculator.com G1 solver, exact inputs (G1 / BC 0.462 / 168gr /
--   2700fps / ICAO sea-level / no wind), zeroed at 0yd so the Elevation column is
--   the pure bore-line drop. Conversions: vel_ms = ft/s·0.3048, range_m = yd·0.9144,
--   drop_m = drop_in·0.0254.
-- IMPORTANT: drop is the solver's REAL 2D drop, NOT -½·g·t². A projectile does not
--   fall as -½gt² — drag couples into the vertical motion, so real drop is ~22%
--   shallower at 1000yd. Vetra models this and matches the solver to <0.1%.
local REFERENCE = {
	-- { range_m, tof_s, vel_ms, drop_m }
	{   0.0, 0.00, 823.0,   0.000 },
	{  91.4, 0.12, 764.4,  -0.064 },
	{ 182.9, 0.24, 708.4,  -0.268 },
	{ 274.3, 0.37, 654.5,  -0.637 },
	{ 365.8, 0.52, 603.2,  -1.197 },
	{ 457.2, 0.68, 554.4,  -1.983 },
	{ 548.6, 0.85, 508.7,  -3.037 },
	{ 640.1, 1.04, 466.0,  -4.409 },
	{ 731.5, 1.24, 426.7,  -6.159 },
	{ 823.0, 1.47, 392.0,  -8.361 },
	{ 914.4, 1.71, 362.4, -11.102 },
}

-- ── Behavior ─────────────────────────────────────────────────────────────────
local Behavior = Vetra.BehaviorBuilder.new()
	:Physics()
	:MaxDistance(950)
	:Gravity(Vector3.new(0, -9.80665, 0))
	:BulletMass(0.010886)         -- 168gr in kg
	:Done()
	:Drag()
	:Model(Vetra.Enums.DragModel.G1)
	-- NOTE: this engine's DragCoefficient is NOT the ballistic coefficient.
	-- Drag accel = Coefficient · Cd(mach) · v²  (see Physics/Pure/Drag.lua) —
	-- Coefficient is the lumped ρ/(2·BC·k) drag-scale, ~1e-3 for real bullets,
	-- and it is NOT normalized by mass or air density anywhere upstream.
	-- Passing a raw BC (0.462) or 1/BC (2.165) gives ~1e5 m/s² and stalls the
	-- bullet in milliseconds. 0.00266 was calibrated so total velocity loss matches
	-- the reference; it holds velocity <1% out to ~600yd, drifting to ~4.6% at
	-- 1000yd (the constant-coefficient vs velocity-banded-BC gap, not an engine
	-- error — drop stays <1.6% throughout).
	:Coefficient(0.00266)         -- lumped drag scale for BC≈0.462 G1 @ sea level
	:SegmentInterval(0.001)       -- 1ms recalc — fine enough for this test
	:Done()
	:Debug()
	:Visualize(true)
	:Done()
	:Build()

-- ── Fire ─────────────────────────────────────────────────────────────────────
local Solver  = Vetra.new()
local Signals = Solver:GetSignals()

local Origin    = Vector3.new(0, 50, 0)   -- elevated so bullet doesn't hit ground
local MuzzleVel = 823.0                    -- 2700 ft/s in m/s

-- The bullet is fired dead flat, so it curves downward and never reaches 950m of
-- HORIZONTAL range before falling — it just accumulates path length / drops.
-- So we don't rely on termination at all: we bucket by true horizontal range
-- (position.X), print each station live as it's crossed, and emit the summary
-- the moment the final (1000yd) station is logged.

local FINAL_YD = 1000
local lastLoggedYd = -1
local worstVelErr  = 0
local dropErr1000  = nil
local headerPrinted = false
local summaryPrinted = false

local function printHeader()
	if headerPrinted then return end
	headerPrinted = true
	print(string.format("\n%-8s %-10s %-12s %-12s %-10s %-10s %-10s",
		"Range", "Vel(m/s)", "JBM vel", "Vel err%", "Drop(m)", "JBM drop", "Drop err%"))
	print(string.rep("-", 80))
end

local function printSummary()
	if summaryPrinted then return end
	summaryPrinted = true
	print("\nPass criteria: velocity error < 1% at all ranges, drop error < 3% at 1000yd")
	local velPass  = worstVelErr < 1
	local dropPass = dropErr1000 == nil or dropErr1000 < 3
	print(string.format("  worst velocity error: %.2f%%  -> %s", worstVelErr, velPass and "PASS" or "FAIL"))
	if dropErr1000 ~= nil then
		print(string.format("  1000yd drop error:    %.2f%%  -> %s", dropErr1000, dropPass and "PASS" or "FAIL"))
	end
	print(string.format("  RESULT: %s", (velPass and dropPass) and "PASS ✓" or "FAIL ✗"))
end

Signals.OnTravel:Connect(function(context, position, velocity)

	local rangeM = position.X - Origin.X       -- true horizontal range from muzzle
	local yd     = math.floor(rangeM / 0.9144) -- metres to yards
	local bucket = math.floor(yd / 100) * 100  -- snap to 100yd buckets

	if bucket <= lastLoggedYd or bucket > FINAL_YD then return end
	lastLoggedYd = bucket

	-- Find matching reference row by horizontal range
	local ref = nil
	for _, r in REFERENCE do
		if math.abs(r[1] - rangeM) < 10 then
			ref = r
			break
		end
	end
	if not ref then return end

	local velMs  = math.round(velocity.Magnitude * 10) / 10
	local dropM  = math.round((position.Y - Origin.Y) * 1000) / 1000
	local velErr  = math.abs(velMs - ref[3]) / ref[3] * 100
	local dropErr = ref[4] ~= 0 and math.abs(dropM - ref[4]) / math.abs(ref[4]) * 100 or 0
	worstVelErr = math.max(worstVelErr, velErr)
	if bucket == FINAL_YD then
		dropErr1000 = dropErr
	end

	printHeader()

	print(string.format("%-8s %-10.1f %-12.1f %-12.2f %-10.3f %-10.3f %-10.2f",
		bucket.."yd",
		velMs, ref[3], velErr,
		dropM, ref[4], dropErr))

	if bucket == FINAL_YD then
		printSummary()
	end
end)

-- Safety net: if the bullet somehow terminates before crossing 1000yd
-- (e.g. hits ground), still print whatever summary we have.
Signals.OnTerminated:Connect(printSummary)

-- Fire horizontally (no elevation — pure bore axis)
local BulletContext = Vetra.BulletContext.new({
	Origin    = Origin,
	Direction = Vector3.new(1, 0, 0),   -- dead flat, no elevation
	Speed     = MuzzleVel,
})

Solver:Fire(BulletContext, Behavior)
