--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- LOD / throttle: does OnTravel ever report a position that was never raycast?
--
-- THE INVARIANT
--   A throttled cast is stepped every Nth frame, and only a step raycasts. Travel
--   must never report the bullet somewhere the sim hasn't swept — otherwise a
--   tracer draws through a wall a frame before OnHit lands behind it.
--
--       overshoot = (max travel x) - (hit x)
--
--   overshoot > 0  => travel led the contact point. BUG.
--   overshoot <= 0 => travel lagged or matched it. Correct.
--
--   Lagging is fine and expected on parallel: it reports at the worker's last
--   confirmed clock, so travel trails the sim by up to one throttle interval.
--   Lagging is honest; leading is a lie.
--
--   NOTE: a terminal event's TotalRuntime is the clock at the END of the step that
--   found the hit, NOT the contact clock — the position it implies is the
--   sub-segment's far end, past the wall. Re-deriving travel from it reports 153.75
--   against a wall at 150. Use EventData.HitPosition if you ever need the contact
--   point; do not reconstruct it from the clock.
--
-- WHAT EACH PATH DOES
--   • serial          skipped casts are queued and flushed AFTER the step loop,
--                     reporting at TotalRuntime — which only advances on a real
--                     step, so it repeats the last stepped position. Firing from
--                     inside the loop instead handed listeners a half-updated cast
--                     and made bullets miss walls outright.
--   • serial suspend  same treatment: suspend means "don't step", not "don't
--                     report". Pause is the only true stop.
--   • parallel        the coordinator's clock advances every frame (so GetPosition
--                     stays smooth) but the worker steps a throttled cast 1-in-N.
--                     The worker confirms its post-step clock via a throttle record
--                     (ResultBuffer EVENT_THROTTLE_STATE); travel clamps to that.
--                     The coordinator cannot derive the schedule itself — the
--                     throttle is worker-owned and any record of it arrives a frame
--                     late, so mirroring the counter drifts out of phase.
--   • HF + LOD        NOT mutually exclusive on parallel, despite the `not IsLOD`
--                     gate: UseHighFidelity is computed from the PREVIOUS frame's
--                     State.IsLOD, before Resolve runs, so HF still steps the
--                     accumulated catch-up delta in sub-segments. Scenario 7 shows
--                     this — it does not behave like scenario 6.
--
-- HOW IT OBSERVES
--   A wall at x=WALL_X, one lane per scenario. Casts are fired at it from x=0 with
--   LOD forced on (LODOrigin parked far away, so every cast is instantly beyond
--   LODDistance and stays there). Log every OnTravel x, the OnHit x, compare.
--
-- READING IT
--   Diagnostic, not pass/fail. Two things are actually wrong if you see them:
--     · overshoot > 0     travel led the hit. The invariant is broken.
--     · NO HIT            the catch-up raycast lost the wall. Real bug — this is
--                         what a badly-placed travel fire looks like, not a
--                         reporting quirk.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

-- ── Tunables ────────────────────────────────────────────────────────────────
local WALL_X        = 150      -- wall face position on +X
local WALL_THICK    = 4
local SPEED         = 300      -- studs/s -> ~5 studs/frame at 60fps
local LOD_INTERVAL  = 4        -- step 1 frame in 5 while in LOD (exaggerated to make the gap obvious)
local FLIGHT_TIME   = 2.0      -- seconds to let the shot resolve
local START_Y       = 500      -- clear of the baseplate
local Z_SPACING     = 200      -- keep each scenario's lane separate

-- ── Wall ────────────────────────────────────────────────────────────────────
-- One wall per lane so scenarios can't interfere with each other.
local Walls = Instance.new("Folder")
Walls.Name   = "LODTravelHitOrderTest_Walls"
Walls.Parent = workspace

local function makeWall(z: number): BasePart
	local p = Instance.new("Part")
	p.Name        = string.format("Wall_z%d", z)
	p.Anchored    = true
	p.CanCollide  = false          -- irrelevant to raycasts; avoids physics noise
	p.Size        = Vector3.new(WALL_THICK, 200, 100)
	p.Position    = Vector3.new(WALL_X + WALL_THICK * 0.5, START_Y, z)
	p.Color       = Color3.fromRGB(200, 80, 80)
	p.Transparency = 0.5
	p.Parent      = Walls
	return p
end

-- ── Behavior ────────────────────────────────────────────────────────────────
-- Zero gravity is honoured, so a flat path (wall hit at a known x, no parabola)
-- just asks for it directly.
local FLAT_GRAVITY = Vector3.zero

local function makeBehavior(opts: { hf: boolean?, lod: boolean? }): any
	return {
		Gravity                 = FLAT_GRAVITY,
		MaxDistance             = 1e6,
		MinSpeed                = 0,
		DragCoefficient         = 0,
		MaxBounces              = 0,
		FireTravelEvents        = true,
		-- HF on => sub-segment raycasting. The theory is that HF makes the
		-- travel/hit gap worse; the gates say HF is disabled while in LOD.
		HighFidelitySegmentSize = opts.hf and 5 or 0,
		LODDistance             = opts.lod and 1 or 0,   -- 1 stud => instantly in LOD
		LODInterval             = LOD_INTERVAL,
	}
end

-- ── One scenario ────────────────────────────────────────────────────────────
type Rec = {
	name        : string,
	travelXs    : { number },
	hitX        : number?,
	travelCount : number,
	steppedHint : string,
}

local function runScenario(
	solver: any,
	name: string,
	z: number,
	behaviorOpts: { hf: boolean?, lod: boolean? },
	suspend: boolean?
): Rec
	makeWall(z)

	local rec: Rec = {
		name        = name,
		travelXs    = {},
		hitX        = nil,
		travelCount = 0,
		steppedHint = "",
	}

	local signals = solver:GetSignals()
	local myId: number? = nil

	local travelConn = signals.OnTravel:Connect(function(ctx, pos)
		if ctx.Id ~= myId then return end
		rec.travelCount += 1
		table.insert(rec.travelXs, pos.X)
	end)
	local hitConn = signals.OnHit:Connect(function(ctx, result)
		if ctx.Id ~= myId then return end
		if rec.hitX == nil and result then
			rec.hitX = result.Position.X
		end
	end)

	-- Park the LOD origin far away so any cast with LODDistance>0 is instantly
	-- beyond it and stays in LOD for the whole flight.
	solver:SetLODOrigin(Vector3.new(0, -1e5, 0))

	local ctx = Vetra.BulletContext.new({
		Origin    = Vector3.new(0, START_Y, z),
		Direction = Vector3.new(1, 0, 0),
		Speed     = SPEED,
	})
	myId = ctx.Id
	local cast = solver:Fire(ctx, makeBehavior(behaviorOpts))

	if suspend and cast then
		-- Suspend across the window where the bullet would reach the wall.
		-- Code says this path `continue`s before firing travel => expect silence.
		cast:SuspendFrame(30)
		rec.steppedHint = "SuspendFrame(30)"
	end

	task.wait(FLIGHT_TIME)

	travelConn:Disconnect()
	hitConn:Disconnect()
	return rec
end

-- ── Report helpers ──────────────────────────────────────────────────────────
local function maxOf(t: { number }): number?
	local m: number? = nil
	for _, v in t do
		if m == nil or v > m then m = v end
	end
	return m
end

local function report(rec: Rec, expected: string)
	local maxTravelX = maxOf(rec.travelXs)
	print(string.rep("─", 74))
	print(string.format("  %s", rec.name))
	if rec.steppedHint ~= "" then
		print(string.format("    (%s)", rec.steppedHint))
	end
	print(string.format("    expectation from code : %s", expected))
	print(string.format("    travel events         : %d", rec.travelCount))
	print(string.format("    max travel x          : %s",
		maxTravelX and string.format("%.2f", maxTravelX) or "— (no travel fired)"))
	print(string.format("    hit x                 : %s",
		rec.hitX and string.format("%.2f", rec.hitX) or "— (NO HIT)"))
	print(string.format("    wall face at          : %.2f", WALL_X))

	if not rec.hitX then
		warn("    [!!] NO HIT — the catch-up raycast missed the wall entirely. Real bug, not just reporting.")
		return
	end

	if maxTravelX then
		local overshoot = maxTravelX - rec.hitX
		print(string.format("    overshoot (travel-hit): %+.2f studs", overshoot))
		if overshoot > 0.5 then
			warn(string.format(
				"    [!!] REGRESSION: travel led the contact point by %.2f studs — it reported",
				overshoot))
			warn("         the bullet past the wall before the hit landed behind it.")
		else
			print("    >> ok: travel never got ahead of the hit point.")
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
print(string.rep("═", 74))
print("Vetra — LOD/throttle travel-vs-hit ordering")
print(string.format("  wall x=%d | speed=%d (~%.1f studs/frame @60fps) | LODInterval=%d",
	WALL_X, SPEED, SPEED / 60, LOD_INTERVAL))
print(string.rep("═", 74))

-- ── SERIAL ──────────────────────────────────────────────────────────────────
local Serial = Vetra.new()

print("\n### SERIAL")

report(
	runScenario(Serial, "1. baseline: no LOD, no HF", Z_SPACING * 0, { lod = false, hf = false }),
	"steps every frame -> travel tracks the raycast, overshoot 0"
)

report(
	runScenario(Serial, "2. LOD on", Z_SPACING * 1, { lod = true, hf = false }),
	"fires on skipped frames at the last STEPPED position -> overshoot 0"
)

report(
	runScenario(Serial, "3. LOD + HF", Z_SPACING * 2, { lod = true, hf = true }),
	"HF gated off by `not IsLOD` -> same as #2"
)

report(
	runScenario(Serial, "4. HF only, no LOD", Z_SPACING * 3, { lod = false, hf = true }),
	"HF active, every frame -> overshoot 0 (control for #3)"
)

report(
	runScenario(Serial, "5. suspended", Z_SPACING * 4, { lod = false, hf = false }, true),
	"suspend != silence -> travel fires, held at the suspended position, overshoot 0"
)

Serial:Destroy()

-- ── PARALLEL ────────────────────────────────────────────────────────────────
print("\n### PARALLEL")
local Par = Vetra.newParallel()
task.wait(1)   -- workers init async; firing immediately drops casts silently

report(
	runScenario(Par, "6. parallel, LOD on", Z_SPACING * 5, { lod = true, hf = false }),
	"clamped to the worker's confirmed clock -> overshoot <= 0, lagging by up to one interval"
)

-- Wall 150 + segment size 5 divides evenly, so every sub-segment boundary lands
-- exactly on the wall face — the case that used to sail straight through (raycast
-- dead bands at both ray origin and endpoint dropped it). RAY_ORIGIN_EPSILON's
-- back-off in StepHighFidelity's sub-loop is what makes this hit. Keep this geometry:
-- a wall at an "unlucky" x (e.g. 148) does NOT exercise the seam.
report(
	runScenario(Par, "7. parallel, LOD + HF", Z_SPACING * 6, { lod = true, hf = true }),
	"boundary lands on the wall face -> must HIT (regression guard for the sub-ray seam)"
)

Par:Destroy()

print(string.rep("═", 74))
print("Every overshoot should be <= 0: travel never leads the contact point.")
print("Parallel lags (negative) by up to one throttle interval — it reports at the")
print("worker's last confirmed clock. That direction is the safe one.")
print("A positive overshoot, or a NO HIT, is a real regression.")
print(string.rep("═", 74))

Walls:Destroy()
