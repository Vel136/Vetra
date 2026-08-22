--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Spatial-partitioning tier test (PARALLEL path)
--
-- Verifies that the parallel solver actually throttles step cadence by spatial
-- tier. This is the feature that was previously DEAD on parallel: the worker's
-- SpatialTier was hardcoded to HOT, so WARM/COLD casts were never down-stepped.
-- (Fixed by broadcasting the grid to workers + per-frame tier lookup in
-- LODSpatial.Resolve.)
--
-- HOW IT OBSERVES THE FEATURE
--   OnTravel fires once per NON-SKIPPED step. A HOT cast steps every frame; a
--   WARM cast every 2nd frame; a COLD cast every 4th. So the count of OnTravel
--   events over a fixed window is a direct proxy for the tier:
--       COLD count  ≈  HOT count / 4
--       WARM count  ≈  HOT count / 2
--
-- SETUP
--   Cell size 50, HotRadius 1 (±1 cell), WarmRadius 3 (±3 cells) — the defaults.
--   Two identical slow casts fly parallel down +X, far apart on Z:
--     • NEAR cast: an interest point sits on its corridor  -> HOT
--     • FAR  cast: no interest point within 3 cells (150+) -> COLD
--   Both are fired with FireTravelEvents = true (required for parallel OnTravel)
--   and a low, constant speed so they stay in their respective cells long enough
--   to accumulate a countable sample.
--
-- PASS CRITERIA
--   1. HOT cast produced a healthy number of travel events (sanity: sim ran).
--   2. FAR/COLD cast produced markedly FEWER events than the NEAR/HOT cast
--      (ratio near ¼, tolerant band 0.15–0.45). Anything ≈1.0 means the tier is
--      being ignored — the exact regression this guards against.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

-- ── Geometry ────────────────────────────────────────────────────────────────
-- NOTE ON GRAVITY: Vetra ignores a zero-magnitude Gravity vector (a zero vector
-- reads as "unset" and falls back to workspace.Gravity), so the casts follow a
-- real parabola. Rather than fight that, we sample the NEAR cast's parabola and
-- lay a trail of interest points along it so it stays HOT for the whole window.
-- The two casts are IDENTICAL except for a large Z offset, so their (X,Y) paths
-- coincide — only the FAR cast's Z keeps it outside the HOT/WARM region.
local CELL          = 50           -- default SpatialPartition cell size
local SAMPLE_TIME    = 3.0          -- seconds to collect travel events
local SPEED          = 40           -- studs/s horizontal
local START_X        = 0
local START_Y        = 500          -- high enough not to hit the ground in the window
local NEAR_Z         = 0
local FAR_Z          = 6000         -- 120 cells away on Z — nothing near it is HOT/WARM
local GRAVITY        = workspace.Gravity  -- what Vetra will actually apply

local NEAR_ORIGIN = Vector3.new(START_X, START_Y, NEAR_Z)
local FAR_ORIGIN  = Vector3.new(START_X, START_Y, FAR_Z)

-- Sample the parabola x(t)=SPEED·t, y(t)=START_Y − ½·g·t² across the window and
-- drop an interest point at each sample. HotRadius 1 (±1 cell = ±50 studs)
-- bridges the gaps between closely-spaced samples, keeping the whole NEAR path HOT.
local INTEREST_POINTS = {}
do
	local STEPS = 40
	for i = 0, STEPS do
		local t = (i / STEPS) * SAMPLE_TIME
		local x = START_X + SPEED * t
		local y = START_Y - 0.5 * GRAVITY * t * t
		table.insert(INTEREST_POINTS, Vector3.new(x, y, NEAR_Z))
	end
end

-- ── Solver (parallel) ─────────────────────────────────────────────────────────
local Solver = Vetra.newParallel({
	SpatialPartition = {
		Enabled        = true,
		CellSize       = CELL,
		HotRadius      = 1,
		WarmRadius     = 3,
		UpdateInterval = 1,     -- rebuild + broadcast every frame for a tight test
		FallbackTier   = 4,     -- Constants.SPATIAL_TIERS.COLD — cells with no interest point step at ¼ rate
	},
})

Solver:SetInterestPoints(INTEREST_POINTS)

-- ── Count travel events per cast ──────────────────────────────────────────────
local Counts: { [number]: number } = {}
local Signals = Solver:GetSignals()
Signals.OnTravel:Connect(function(Context)
	local Id = Context.Id
	Counts[Id] = (Counts[Id] or 0) + 1
end)

-- ── Behavior: dragless, long-lived, travel events on ──────────────────────────
-- Gravity is left at the workspace default (Vetra ignores a zero vector), and the
-- interest-point trail above is computed against that same gravity.
local function makeBehavior()
	return {
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		DragCoefficient         = 0,
		MaxBounces              = 0,
		BounceSpeedThreshold    = 1e9,
		CanBounceFunction       = function() return false end,
		HighFidelitySegmentSize = 0,                   -- base step; tier gate is what we test
		FireTravelEvents        = true,                -- REQUIRED for parallel OnTravel
	}
end

local function fire(origin: Vector3): number
	local ctx = Vetra.BulletContext.new({
		Origin    = origin,
		Direction = Vector3.new(1, 0, 0),
		Speed     = SPEED,
	})
	Solver:Fire(ctx, makeBehavior())
	return ctx.Id
end

-- ── Run ───────────────────────────────────────────────────────────────────────
-- Parallel workers init asynchronously; give them a beat before firing or the
-- casts can drop silently (known parallel startup race).
task.wait(1)

local NearId = fire(NEAR_ORIGIN)   -- expected HOT
local FarId  = fire(FAR_ORIGIN)    -- expected COLD

task.wait(SAMPLE_TIME)

-- ── Report ──────────────────────────────────────────────────────────────────
local NearCount = Counts[NearId] or 0
local FarCount  = Counts[FarId]  or 0
local Ratio     = NearCount > 0 and (FarCount / NearCount) or math.huge

print(string.rep("─", 68))
print("Vetra — Spatial Partitioning tier test (parallel)")
print(string.rep("─", 68))
print(string.format("  NEAR cast (HOT , id=%d) : %4d travel events", NearId, NearCount))
print(string.format("  FAR  cast (COLD, id=%d) : %4d travel events", FarId,  FarCount))
print(string.format("  FAR / NEAR ratio        : %.3f   (COLD≈0.25, no-throttle≈1.0)", Ratio))
print(string.rep("─", 68))

-- Expect the HOT cast to have stepped a meaningful number of times so the ratio
-- is meaningful. At 60fps over 3s that's ~180; be generous for lower framerates.
local HOT_MIN         = 30
local RATIO_LOW       = 0.15   -- below this, throttling is stronger than expected (still a pass — feature works)
local RATIO_HIGH      = 0.45   -- above this, the COLD cast is stepping too often -> tier ignored

local sanityOk = NearCount >= HOT_MIN
local tierOk   = Ratio >= RATIO_LOW and Ratio <= RATIO_HIGH

if not sanityOk then
	warn(string.format(
		"[FAIL] HOT cast only produced %d travel events (< %d). Sim didn't run " ..
		"long enough, workers didn't start, or travel events aren't firing.",
		NearCount, HOT_MIN))
elseif not tierOk then
	if Ratio > RATIO_HIGH then
		warn(string.format(
			"[FAIL] FAR/NEAR ratio %.3f is too high — the COLD cast is stepping " ..
			"almost as often as the HOT one. Spatial tier is being IGNORED on the " ..
			"parallel path (the regression this test guards).", Ratio))
	else
		warn(string.format(
			"[FAIL] FAR/NEAR ratio %.3f is below %.2f — unexpectedly heavy " ..
			"throttling. Check tier/UpdateInterval or interest-point placement.",
			Ratio, RATIO_LOW))
	end
else
	print(string.format(
		"[PASS] Spatial partitioning throttles by tier on parallel " ..
		"(ratio %.3f ≈ COLD ¼-rate).", Ratio))
end
print(string.rep("─", 68))
