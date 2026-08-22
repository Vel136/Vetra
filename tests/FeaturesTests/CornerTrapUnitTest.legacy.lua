--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- Corner-trap detector — DIRECT algorithm test (no physics/geometry)
--
-- Exercises PureBounce.IsCornerTrap on hand-crafted bounce sequences with KNOWN
-- ground truth, driving state through the real PureBounce.RecordBounceState update
-- exactly as production does. This isolates the detection ALGORITHM from the
-- simulation, giving an exact confusion matrix over labelled scenarios.
--
-- The four detection criteria (any → trap):
--   1. TIME     : bounce interval < CornerTimeThreshold
--   2. REVISIT  : new contact within CornerDisplacementThreshold of a history entry
--   3. EMA      : |velocity-direction EMA| < CornerEMAThreshold (after ≥1 bounce)
--   4. PROGRESS : after ≥3 bounces, net displacement < count·MinProgressPerBounce
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PureBounce = require(ReplicatedStorage.src.Physics.Pure.Bounce)

-- Default corner-trap tuning (mirrors BehaviorBuilder Defaults).
local CFG = {
	CornerTimeThreshold         = 0.002,
	CornerDisplacementThreshold = 0.5,
	CornerEMAAlpha              = 0.4,
	CornerEMAThreshold          = 0.25,
	CornerMinProgressPerBounce  = 0.3,
	CornerPositionHistorySize   = 4,
}

local function freshState(): any
	return {
		TotalRuntime                = 0,
		LastBounceTime              = -999,   -- long ago → criterion 1 won't false-trip on bounce 1
		BouncePositionHistory       = {},
		BouncePositionHead          = 0,
		CornerBounceCount           = 0,
		VelocityDirectionEMA        = Vector3.zero,
		FirstBouncePosition         = nil,
		CornerTimeThreshold         = CFG.CornerTimeThreshold,
		CornerDisplacementThreshold = CFG.CornerDisplacementThreshold,
		CornerEMAAlpha              = CFG.CornerEMAAlpha,
		CornerEMAThreshold          = CFG.CornerEMAThreshold,
		CornerMinProgressPerBounce  = CFG.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = CFG.CornerPositionHistorySize,
	}
end

-- Feed a sequence of bounces { {pos=Vector3, vel=Vector3, dt=number}, ... } through
-- the real update path, calling IsCornerTrap BEFORE each recorded bounce (as
-- production does). Returns true if the detector fires on ANY bounce in the run,
-- and the 1-based index of the first firing bounce (or nil).
local function runSequence(bounces: { any }): (boolean, number?)
	local state = freshState()
	for i, b in bounces do
		state.TotalRuntime = state.TotalRuntime + b.dt

		-- Detector runs on the incoming contact, using state accumulated so far.
		local trapped = PureBounce.IsCornerTrap(state, b.pos, state.TotalRuntime)
		if trapped then
			return true, i
		end

		-- Record the bounce (advances history, EMA, counts, LastBounceTime).
		local NewLastBounceTime, NewHead, NewHistory, NewCount, NewEMA, NewFirst =
			PureBounce.RecordBounceState(state, b.pos, b.vel, state.TotalRuntime)
		state.LastBounceTime        = NewLastBounceTime
		state.BouncePositionHead    = NewHead
		state.BouncePositionHistory = NewHistory
		state.CornerBounceCount     = NewCount
		state.VelocityDirectionEMA  = NewEMA
		state.FirstBouncePosition   = NewFirst
	end
	return false, nil
end

-- ── Scenario builders ─────────────────────────────────────────────────────────
local DT_NORMAL = 0.05   -- comfortably above CornerTimeThreshold (0.002)

-- TRAP 1: rapid-fire bounces (tiny dt) — trips TIME criterion.
local function trap_time(): { any }
	local out = {}
	for i = 1, 6 do
		-- spread far in space + consistent direction so ONLY the time criterion can fire
		out[i] = { pos = Vector3.new(i * 100, 0, 0), vel = Vector3.new(1, 0, 0) * 300, dt = 0.0005 }
	end
	return out
end

-- TRAP 2: bounces cycling in the same ~0.1-stud spot — trips REVISIT criterion.
local function trap_revisit(): { any }
	local out = {}
	local spots = {
		Vector3.new(0, 0, 0), Vector3.new(0.1, 0, 0),
		Vector3.new(0, 0.1, 0), Vector3.new(0.05, 0.05, 0),
		Vector3.new(0, 0, 0.1), Vector3.new(0.1, 0.1, 0),
	}
	for i, p in spots do
		out[i] = { pos = p, vel = Vector3.new(math.random(), math.random(), math.random()) * 300, dt = DT_NORMAL }
	end
	return out
end

-- TRAP 3: alternating opposite directions — trips EMA-collapse criterion. Positions
-- spaced > displacement threshold and dt large, so only the EMA can fire.
local function trap_ema(): { any }
	local out = {}
	for i = 1, 8 do
		local dir = (i % 2 == 0) and Vector3.new(1, 0, 0) or Vector3.new(-1, 0, 0)
		out[i] = { pos = Vector3.new(i * 5, 0, 0), vel = dir * 300, dt = DT_NORMAL }
	end
	return out
end

-- TRAP 4: many bounces, near-zero NET progress, but each > displacement threshold
-- from the last and directions varied (so criteria 2 and 3 don't fire) — isolates
-- the PROGRESS criterion. Bounces wander within a small ~1.5-stud shell.
local function trap_progress(): { any }
	local out = {}
	local ring = {
		Vector3.new( 1.0, 0, 0), Vector3.new(-1.0, 0.2, 0), Vector3.new( 0.9, 0, 0.3),
		Vector3.new(-0.8, 0, 0), Vector3.new( 1.0, -0.2, 0), Vector3.new(-0.9, 0, -0.3),
	}
	for i, p in ring do
		local vel = (i % 2 == 0) and Vector3.new(0, 1, 0) or Vector3.new(0, 0, 1)
		out[i] = { pos = p, vel = vel * 300, dt = DT_NORMAL }
	end
	return out
end

-- NON-TRAP 1: clean ricochet down a hallway — far apart, consistent direction,
-- well-spaced in time. Should NOT fire.
local function legit_ricochet(): { any }
	local out = {}
	for i = 1, 8 do
		out[i] = { pos = Vector3.new(i * 40, (i % 2) * 20, 0), vel = Vector3.new(1, (i % 2 == 0) and 0.4 or -0.4, 0).Unit * 300, dt = DT_NORMAL }
	end
	return out
end

-- NON-TRAP 2: a single bounce — no history, must never fire.
local function legit_single(): { any }
	return { { pos = Vector3.new(0, 0, 0), vel = Vector3.new(1, 0, 0) * 300, dt = DT_NORMAL } }
end

-- NON-TRAP 3: two well-separated bounces, consistent direction. Must not fire.
local function legit_two(): { any }
	return {
		{ pos = Vector3.new(0, 0, 0),   vel = Vector3.new(1, 0.3, 0).Unit * 300, dt = DT_NORMAL },
		{ pos = Vector3.new(50, 15, 0), vel = Vector3.new(1, -0.3, 0).Unit * 300, dt = DT_NORMAL },
	}
end

-- NON-TRAP 4: steady shallow skips down a floor — many bounces but strong net
-- forward progress and forward-consistent direction. The realistic false-positive
-- risk case. Must not fire.
local function legit_skips(): { any }
	local out = {}
	for i = 1, 10 do
		out[i] = { pos = Vector3.new(i * 30, 0, 0), vel = Vector3.new(1, 0.15, 0).Unit * 300, dt = DT_NORMAL }
	end
	return out
end

-- ── Run the matrix ────────────────────────────────────────────────────────────
local POSITIVES = {
	{ name = "TRAP time-rate",    build = trap_time },
	{ name = "TRAP revisit",      build = trap_revisit },
	{ name = "TRAP ema-collapse", build = trap_ema },
	{ name = "TRAP min-progress", build = trap_progress },
}
local NEGATIVES = {
	{ name = "OK ricochet-hall",  build = legit_ricochet },
	{ name = "OK single-bounce",  build = legit_single },
	{ name = "OK two-bounce",     build = legit_two },
	{ name = "OK floor-skips",    build = legit_skips },
}

print(string.rep("─", 72))
print("Vetra — Corner-trap detector unit test (pure algorithm)")
print(string.rep("─", 72))

local TP, FN = 0, 0
print("  POSITIVES (should DETECT):")
for _, case in POSITIVES do
	local fired, at = runSequence(case.build())
	if fired then TP += 1 else FN += 1 end
	print(string.format("    %-18s → %s%s", case.name,
		fired and "DETECTED" or "MISSED  ",
		fired and string.format(" (at bounce #%d)", at) or ""))
end

local TN, FP = 0, 0
print("  NEGATIVES (should NOT detect):")
for _, case in NEGATIVES do
	local fired, at = runSequence(case.build())
	if fired then FP += 1 else TN += 1 end
	print(string.format("    %-18s → %s%s", case.name,
		fired and "FLAGGED " or "passed  ",
		fired and string.format(" (false positive at #%d)", at) or ""))
end

print(string.rep("─", 72))
local nPos = #POSITIVES
local nNeg = #NEGATIVES
print(string.format("  TRUE-positive rate  : %.0f%%  (%d/%d traps detected)", TP / nPos * 100, TP, nPos))
print(string.format("  FALSE-positive rate : %.0f%%  (%d/%d legit flagged)",  FP / nNeg * 100, FP, nNeg))
print(string.rep("─", 72))
if TP == nPos and FP == 0 then
	print("[PASS] every trap detected, no legit bounce flagged.")
else
	warn(string.format("[REVIEW] TP=%d/%d FP=%d/%d — see per-case lines above.", TP, nPos, FP, nNeg))
end
print(string.rep("─", 72))
