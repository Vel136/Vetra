--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Raycast accuracy — verifies the claims the Tunnelling & Precision doc rests on.
--
-- The doc makes two factual assertions about workspace:Raycast. This test proves
-- or disproves each, independently, with no Vetra involvement (raw raycasts), so
-- the docs can't quietly drift from engine behaviour.
--
-- CLAIM 1  A STRAIGHT ray hits a wall squarely between its endpoints regardless
--          of the wall's thickness. (i.e. thinness alone does NOT cause a straight
--          ray to miss — so tunnelling is about curvature/chords, not thickness.)
--
-- CLAIM 2  Tunnelling on a CURVED path is real: a single straight A->B chord of an
--          arc misses a wall the arc passes through, and subdividing the arc into
--          shorter chords (high fidelity) catches it.
--
-- Plus two edges the doc mentions in passing:
--   EDGE A  Grazing angle: a nearly-parallel straight ray through a thin wall.
--   EDGE B  The precision seam (origin/endpoint dead band) that the ulp back-off
--           fixes — proving the fix is load-bearing, not decorative.
--
-- RUN: Edit or Play mode, server. Pure raycasts + analytic arcs, no solver needed.
-- Every line is PASS/FAIL so a regression in engine behaviour or in our reasoning
-- surfaces immediately.
-- ─────────────────────────────────────────────────────────────────────────────

local RAY_ORIGIN_EPSILON = 1.2e-6  -- mirror of Constants.RAY_ORIGIN_EPSILON

local Bin = Instance.new("Folder")
Bin.Name = "RaycastAccuracyTest"
Bin.Parent = workspace

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.FilterDescendantsInstances = {}  -- exclude nothing; our probe walls MUST be visible

local function clearBin()
	for _, c in ipairs(Bin:GetChildren()) do c:Destroy() end
end

-- A wall whose NEAR face (smaller X) sits at faceX, thickness `thick` along X.
local function makeWall(faceX: number, thick: number, y: number, z: number): BasePart
	local p = Instance.new("Part")
	p.Anchored   = true
	p.CanCollide = false
	p.Size       = Vector3.new(thick, 200, 200)
	p.Position   = Vector3.new(faceX + thick / 2, y, z)
	p.Parent     = Bin
	return p
end

local pass, fail = 0, 0
local function check(cond: boolean, label: string, detail: string?)
	if cond then
		pass += 1
		print(string.format("  PASS  %s%s", label, detail and ("  (" .. detail .. ")") or ""))
	else
		fail += 1
		warn(string.format("  FAIL  %s%s", label, detail and ("  (" .. detail .. ")") or ""))
	end
end

print(string.rep("═", 74))
print("Vetra — raycast accuracy (verifies the tunnelling doc's factual claims)")
print(string.rep("═", 74))

-- ═══ CLAIM 1: straight ray, thickness irrelevant ════════════════════════════
-- The claim is simply "a straight ray hits a wall between A and B, at ANY
-- thickness" — that's what makes tunnelling a curvature problem, not a thickness
-- one. We assert the HIT (the load-bearing fact) separately from WHERE it reports,
-- because Roblox parts have a small contact skin: the ray registers contact a
-- fraction of a stud OUTSIDE the nominal face, which for a sub-0.05 wall is a
-- visible fraction of its thickness. The skin is measured and reported, not
-- asserted against a guessed tolerance.
print("\n### CLAIM 1  straight ray hits a wall between A and B, at any thickness")
print("     ray A(0,0,0) -> B(100,0,0), wall near-face at x=50")
local maxSkin = 0
for _, thick in ipairs({ 10, 1, 0.1, 0.05, 0.01, 0.001, 0.0001 }) do
	clearBin()
	makeWall(50, thick, 0, 0)
	local r    = workspace:Raycast(Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), rp)
	local hit  = r ~= nil
	-- contact reported at or just before the face; skin = how far outside
	local skin = hit and (50 - r.Position.X) or math.huge
	if hit and skin > maxSkin then maxSkin = skin end
	check(hit,
		string.format("thickness %-8s is HIT (thinness never causes a straight miss)", tostring(thick)),
		hit and string.format("x=%.4f, contact skin %.4f studs", r.Position.X, skin) or "MISS")
end
-- The contact skin should be small and bounded, a fraction of a stud, never enough
-- to make the ray miss. Assert it stays within a sane bound so a future engine
-- change that widened it would surface here.
check(maxSkin < 0.05, "engine contact skin stays small and bounded",
	string.format("max observed %.4f studs", maxSkin))

-- ═══ EDGE A: grazing angle through a thin wall ══════════════════════════════
print("\n### EDGE A  grazing straight ray through a thin (0.05) wall")
print("     shallower angle-to-face = harder; does it still register?")
for _, ang in ipairs({ 45, 20, 5, 1, 0.25 }) do
	clearBin()
	makeWall(50, 0.05, 0, 0)
	local rad    = math.rad(ang)
	-- direction crosses the x=50 plane at `ang` degrees off the face normal's
	-- perpendicular; small X component, large Y component when ang is small.
	local dir    = Vector3.new(math.cos(rad), math.sin(rad), 0).Unit * 400
	local origin = Vector3.new(50 - dir.Unit.X * 30, -dir.Unit.Y * 30, 0)
	local r      = workspace:Raycast(origin, dir, rp)
	check(r ~= nil,
		string.format("angle-to-normal %-5s deg registers", tostring(ang)),
		r and string.format("x=%.3f y=%.3f", r.Position.X, r.Position.Y) or "MISS")
end

-- ═══ CLAIM 2: curved arc, chord misses, sub-chords catch ════════════════════
print("\n### CLAIM 2  a curved arc tunnels a single chord; sub-segments catch it")
-- Analytic arc: launch up-range with strong gravity so it bows noticeably.
-- origin (0, 0, 0), v = (120, 90, 0), a = (0, -300, 0). Over ~0.75s it arcs up
-- then down. Place a thin wall where the ARC passes but the A->B chord doesn't.
local o   = Vector3.new(0, 0, 0)
local v   = Vector3.new(120, 90, 0)
local acc = Vector3.new(0, -300, 0)
local function P(t: number): Vector3
	return o + v * t + acc * (0.5 * t * t)
end

local tA, tB = 0.0, 0.6
local A, B = P(tA), P(tB)

-- Find the arc's apex-ish sample and drop a thin wall straddling the arc there,
-- offset so the straight chord A->B passes to one side of it.
local tMid   = (tA + tB) * 0.5
local arcMid = P(tMid)
local chordMid = A:Lerp(B, 0.5)
local gap = (arcMid - chordMid).Magnitude
print(string.format("     arc bows %.2f studs off its chord at mid-frame", gap))

-- Thin wall centered on the ARC midpoint, thin along X (the travel axis).
-- Height is deliberately bounded: tall enough that a mid-frame sub-chord (which
-- runs along the arc, through arcMid) passes through it, but short enough that its
-- bottom edge stays ABOVE the straight A->B chord, which sits `gap` studs below the
-- arc apex. Half-height gap*0.4 < gap guarantees the chord slips under it, so
-- "single chord misses" is a real miss, not an accident of a too-short wall.
clearBin()
local wall = Instance.new("Part")
wall.Anchored = true wall.CanCollide = false
wall.Size     = Vector3.new(0.1, gap * 0.8, 40)  -- half-height = gap*0.4
wall.Position = arcMid
wall.Parent   = Bin
print(string.format("     wall: thin(0.1) x tall(%.2f) at arc apex y=%.2f; chord mid y=%.2f",
	gap * 0.8, arcMid.Y, chordMid.Y))

-- (a) single chord A->B
local chord = workspace:Raycast(A, B - A, rp)
-- (b) subdivide the arc into N chords and cast each
local function sweptArc(subs: number): boolean
	for i = 1, subs do
		local t0 = tA + (tB - tA) * (i - 1) / subs
		local t1 = tA + (tB - tA) * i / subs
		local p0, p1 = P(t0), P(t1)
		if workspace:Raycast(p0, p1 - p0, rp) then return true end
	end
	return false
end

local sub8  = sweptArc(8)
local sub32 = sweptArc(32)
check(chord == nil, "single chord MISSES the wall the arc crosses",
	chord and ("unexpected hit x=" .. string.format("%.2f", chord.Position.X)) or "missed as predicted")
check(sub8,  "8 sub-segments CATCH it",  sub8  and "hit" or "still missed")
check(sub32, "32 sub-segments CATCH it", sub32 and "hit" or "still missed")

-- ═══ EDGE B: the precision seam and the ulp back-off ════════════════════════
print("\n### EDGE B  precision seam: a face on an exact ray boundary")
print("     wall face at x=150; two consecutive 5-stud rays share the boundary 150")
clearBin()
makeWall(150, 4, 0, 0)

-- naive: ray1 145->150 (ends on face), ray2 150->155 (starts on face)
local naive1 = workspace:Raycast(Vector3.new(145, 0, 0), Vector3.new(5, 0, 0), rp)
local naive2 = workspace:Raycast(Vector3.new(150, 0, 0), Vector3.new(5, 0, 0), rp)
local naiveHit = (naive1 ~= nil) or (naive2 ~= nil)

-- fixed: back each origin off by the ulp-scaled epsilon (matches the shipped fix)
local function backedOff(a: Vector3, b: Vector3)
	local dir = b - a
	local mag = math.max(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
	local o2  = a - dir.Unit * (math.max(mag, 1) * RAY_ORIGIN_EPSILON)
	return workspace:Raycast(o2, b - o2, rp)
end
local fixed1 = backedOff(Vector3.new(145, 0, 0), Vector3.new(150, 0, 0))
local fixed2 = backedOff(Vector3.new(150, 0, 0), Vector3.new(155, 0, 0))
local fixedHit = (fixed1 ~= nil) or (fixed2 ~= nil)

-- control: one span 145->155 hits, proving the wall is there
local span = workspace:Raycast(Vector3.new(145, 0, 0), Vector3.new(10, 0, 0), rp)

check(span ~= nil, "control: full span 145->155 hits (wall is present)",
	span and string.format("x=%.3f", span.Position.X) or "MISS")
check(not naiveHit, "naive boundary-aligned sub-rays MISS (the seam exists)",
	naiveHit and "unexpectedly hit" or "both missed, as the bug predicts")
check(fixedHit, "ulp back-off sub-rays HIT (the shipped fix works)",
	fixedHit and "caught" or "STILL MISSING — fix ineffective")

-- ═══ EDGE C: the origin dead band is half a float32 ulp ═════════════════════
-- The doc claims the band is ~0.5 * ulp(x) and scales with coordinate magnitude,
-- which is WHY the fix's epsilon is relative, not a constant. Measure it directly:
-- binary-search how far before a face a ray must start to still register the hit.
print("\n### EDGE C  origin dead band == half a float32 ulp, at two magnitudes")
local function f32ulp(x: number): number
	-- ulp = 2^floor(log2(x)) * 2^-23  for a float32 significand
	local e = math.floor(math.log(x) / math.log(2))
	return (2 ^ e) * (2 ^ -23)
end
-- Smallest back-off (before the face) at which the ray still sees the wall.
local function measureBand(faceX: number): number
	clearBin()
	makeWall(faceX, 4, 0, 0)
	local lo, hi = 0, 1e-2  -- lo misses, hi hits (hi is comfortably outside)
	for _ = 1, 60 do
		local mid = (lo + hi) * 0.5
		local r = workspace:Raycast(Vector3.new(faceX - mid, 0, 0), Vector3.new(10, 0, 0), rp)
		if r and math.abs(r.Position.X - faceX) < 0.05 then hi = mid else lo = mid end
	end
	return hi
end
for _, faceX in ipairs({ 150, 15000 }) do
	local band  = measureBand(faceX)
	local ulp   = f32ulp(faceX)
	local ratio = band / ulp
	-- Expect ~0.5. Allow a generous window (0.25..0.9) so it asserts the ORDER and
	-- the half-ulp character without being brittle to exact rounding at the boundary.
	check(ratio > 0.25 and ratio < 0.9,
		string.format("band at x=%d is ~half an ulp", faceX),
		string.format("band=%.3e  ulp=%.3e  band/ulp=%.2f", band, ulp, ratio))
end

-- ═══ summary ════════════════════════════════════════════════════════════════
Bin:Destroy()
print(string.rep("═", 74))
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail == 0 then
	print("All claims hold: thickness is irrelevant to a straight ray; curvature")
	print("causes tunnelling; sub-segments and the ulp back-off both fix what they claim.")
else
	warn("A claim the docs depend on did not hold — investigate before trusting the page.")
end
print(string.rep("═", 74))
