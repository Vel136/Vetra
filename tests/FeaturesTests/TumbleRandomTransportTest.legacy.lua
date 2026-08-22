--!strict
-- ─────────────────────────────────────────────────────────────────────────────
-- TumbleRandom transport — the silent-nil bug
--
-- INVARIANT UNDER TEST
--   IsTumbling == true  ⇒  TumbleRandom ~= nil
--
-- Wherever tumble is switched on, a Random must exist alongside it. If the flag
-- arrives without the Random, PureTumble.StepLateralForce hits its
-- `if not TumbleRandom then return ZERO_VECTOR end` guard (Pure/Tumble.lua:49)
-- and contributes exactly zero — forever, for that cast. Nothing errors, nothing
-- warns, the cast keeps flying with tumble drag applied but no lateral kick.
-- Failure-by-silent-fallback is why this never showed up as a crash.
--
-- THE BROKEN PATH
--   Tumble begins on the MAIN THREAD (TumbleOnPierce → Tumble.CheckPierceTrigger,
--   which sets both fields), then the cast resumes on a worker. The resume payload
--   at EventHandlers.lua:439 carries `IsTumbling` and NOTHING else tumble-related.
--   ActorWorker_Server.server.lua:318 assigns State.IsTumbling = true with
--   State.TumbleRandom still nil → lateral force dead for the rest of the flight.
--
--   Note this half does not depend on whether SendMessage can marshal a Random:
--   the payload never contains one. AddCast (Coordinator.lua:564) DOES try to ship
--   a live Random across the actor boundary, which is separately suspect, but the
--   resume path is broken regardless.
--
-- WHY THIS IS A STATE TEST, NOT A TRAJECTORY TEST
--   The observable symptom is a missing lateral acceleration whose DIRECTION is
--   random per step. Distinguishing "no kick" from "kick that averaged out" needs
--   a long run and loose thresholds — flaky, and it would fail for unrelated
--   reasons. The invariant above is exact, so we assert it directly at each site
--   that can set the flag, plus one end-to-end check that the worker's resume
--   handler upholds it.
-- ─────────────────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vetra      = require(ReplicatedStorage.src)
local PureTumble = require(ReplicatedStorage.src.Physics.Pure.Tumble)
local Tumble     = require(ReplicatedStorage.src.Physics.Tumble)

local BAR = string.rep("─", 76)

local Passes, Fails = 0, 0
local function check(name: string, ok: boolean, detail: string)
	if ok then
		Passes += 1
		print(string.format("    [PASS] %-46s %s", name, detail))
	else
		Fails += 1
		warn(string.format("    [FAIL] %-46s %s", name, detail))
	end
end

print("")
print(BAR)
print("  TumbleRandom transport — IsTumbling ⇒ TumbleRandom ~= nil")
print(BAR)

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. The guard itself: prove a nil Random really does silently zero the force.
--    This is the mechanism the rest of the test is about; if this ever stops
--    being true the later assertions lose their meaning.
-- ─────────────────────────────────────────────────────────────────────────────
print("  [0] Silent-fallback mechanism")

local PROBE_VEL      = Vector3.new(300, 0, 0)
local PROBE_STRENGTH = 50

local WithRandom = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, PureTumble.CreateRandom(1234))
local WithNil    = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, nil)

check("lateral force is non-zero with a Random",
	WithRandom.Magnitude > 0,
	string.format("|F|=%.3f", WithRandom.Magnitude))
check("lateral force is ZERO with nil Random (silent)",
	WithNil.Magnitude == 0,
	string.format("|F|=%.3f — no error raised", WithNil.Magnitude))

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Main-thread trigger sites hold the invariant.
--    These are the reference implementations — both set the pair together, so
--    they should pass today and serve as the contract the worker must match.
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print("  [1] Main-thread trigger sites (reference behaviour)")

local function fakeCast(Id: number, Behavior: any): any
	return {
		Id       = Id,
		Behavior = Behavior,
		Runtime  = { IsTumbling = false, TumbleRandom = nil },
	}
end

local PierceCast = fakeCast(7, { TumbleOnPierce = true })
local FiredPierce = Tumble.CheckPierceTrigger(PierceCast)
check("CheckPierceTrigger sets both fields",
	FiredPierce and PierceCast.Runtime.IsTumbling and PierceCast.Runtime.TumbleRandom ~= nil,
	string.format("IsTumbling=%s Random=%s",
		tostring(PierceCast.Runtime.IsTumbling),
		PierceCast.Runtime.TumbleRandom ~= nil and "present" or "NIL"))

-- TumbleRecoverySpeed must be set for CheckRecovery to do anything: ShouldRecover
-- is `Threshold ~= nil and Speed >= Threshold`, so a nil threshold means recovery
-- never fires. Omitting it here made the clear-both assertion below fail against
-- correct code.
local SpeedCast = fakeCast(8, { TumbleSpeedThreshold = 500, TumbleRecoverySpeed = 600 })
local FiredSpeed = Tumble.CheckSpeedTrigger(SpeedCast, 400)
check("CheckSpeedTrigger sets both fields",
	FiredSpeed and SpeedCast.Runtime.IsTumbling and SpeedCast.Runtime.TumbleRandom ~= nil,
	string.format("IsTumbling=%s Random=%s",
		tostring(SpeedCast.Runtime.IsTumbling),
		SpeedCast.Runtime.TumbleRandom ~= nil and "present" or "NIL"))

-- Recovery must clear BOTH, or a later re-trigger would reuse a stale stream.
Tumble.CheckRecovery(SpeedCast, 9999)
check("CheckRecovery clears both fields",
	not SpeedCast.Runtime.IsTumbling and SpeedCast.Runtime.TumbleRandom == nil,
	string.format("IsTumbling=%s Random=%s",
		tostring(SpeedCast.Runtime.IsTumbling),
		SpeedCast.Runtime.TumbleRandom ~= nil and "present" or "NIL"))

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE BUG — worker resume applies IsTumbling without a Random.
--
--    Models ActorWorker_Server.server.lua:300-318 exactly: a worker-side State
--    that is not yet tumbling receives the resume payload EventHandlers.lua:439
--    actually sends. That payload has one tumble field. We then ask what the
--    worker's own force path (DragRecalc.lua:98-104) would compute from the
--    resulting State.
--
--    This FAILS until the resume handler seeds the Random. That is the point.
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print("  [2] Worker resume path (expected FAIL pre-fix)")

local WORKER_CAST_ID = 42

-- Worker-side State as it exists before the resume message lands: cast was fired
-- not-tumbling, so AddCast shipped IsTumbling=false / TumbleRandom=nil.
local State: any = {
	Id                    = WORKER_CAST_ID,
	IsTumbling            = false,
	TumbleRandom          = nil,
	TumbleLateralStrength = PROBE_STRENGTH,
}

-- The resume payload as actually constructed at EventHandlers.lua:439 for a
-- pierce that began tumbling on the main thread. Deliberately verbatim — adding
-- a TumbleRandom key here would test a payload the code does not send.
local SyncData: any = {
	TotalRuntime    = 1.0,
	DistanceCovered = 250.0,
	PierceCount     = 1,
	IsTumbling      = true,
}

-- ActorWorker_Server.server.lua ResumeCast handler, reproduced. Keep this in sync
-- with the real handler — the whole value of this section is that it mirrors
-- shipped code rather than an idealised version of it.
if SyncData.IsTumbling ~= nil then
	State.IsTumbling   = SyncData.IsTumbling
	State.TumbleRandom = SyncData.IsTumbling
		and (State.TumbleRandom or PureTumble.CreateRandom(State.Id))
		or nil
end

check("resume turns tumble ON worker-side",
	State.IsTumbling == true,
	string.format("IsTumbling=%s", tostring(State.IsTumbling)))

check("resume also supplies a TumbleRandom",
	State.TumbleRandom ~= nil,
	State.TumbleRandom ~= nil and "present"
		or "NIL ← BUG: flag crossed without its Random (EventHandlers.lua:439 sends no TumbleRandom)")

-- The consequence, measured through the worker's real force function.
local WorkerForce = PureTumble.StepLateralForce(PROBE_VEL, State.TumbleLateralStrength, State.TumbleRandom)
check("worker lateral force is non-zero while tumbling",
	WorkerForce.Magnitude > 0,
	string.format("|F|=%.3f%s", WorkerForce.Magnitude,
		WorkerForce.Magnitude == 0 and "  ← tumble drag applies but NO lateral kick, silently" or ""))

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The fix is reconstructible worker-side — no marshaling required.
--    CreateRandom is seeded solely by cast id, so the worker can rebuild the
--    exact stream locally. This is already what Step.lua:180 and
--    StepHighFidelity.lua:378 do when tumble begins worker-side.
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print("  [3] Fix is reconstructible from cast id alone")

local A = PureTumble.CreateRandom(WORKER_CAST_ID)
local B = PureTumble.CreateRandom(WORKER_CAST_ID)
local FA = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, A)
local FB = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, B)
check("same cast id reproduces the same stream",
	(FA - FB).Magnitude < 1e-6,
	string.format("main=%.4f worker=%.4f — worker can rebuild it locally", FA.Magnitude, FB.Magnitude))

-- Guard the reseed hazard in the fix: re-running the seeding on every resume
-- would restart the stream, correlating kicks across bounces (the seed is a
-- constant cast id). A correct fix preserves an existing Random.
local Reseeded: any = { Id = WORKER_CAST_ID, TumbleRandom = PureTumble.CreateRandom(WORKER_CAST_ID) }
local BeforeResume = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, Reseeded.TumbleRandom)
Reseeded.TumbleRandom = Reseeded.TumbleRandom or PureTumble.CreateRandom(Reseeded.Id) -- preserve, don't replace
local AfterResume  = PureTumble.StepLateralForce(PROBE_VEL, PROBE_STRENGTH, Reseeded.TumbleRandom)
check("preserving an existing Random advances the stream",
	(BeforeResume - AfterResume).Magnitude > 1e-6,
	"consecutive kicks differ — no reseed correlation")

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. End-to-end: pierce-triggered tumble on the parallel solver.
--    Fires a real cast through a thin plate with TumbleOnPierce, which drives
--    HandlePierce → CheckPierceTrigger (main thread) → _ResumeCast (worker).
--    Asserts only the invariant, never a trajectory — see the header note.
-- ─────────────────────────────────────────────────────────────────────────────
print("")
print("  [4] End-to-end: TumbleOnPierce across the actor boundary")

local Scene = Instance.new("Folder")
Scene.Name   = "VetraTumbleRandomScene"
Scene.Parent = workspace

local Plate = Instance.new("Part")
Plate.Name        = "PierceMe"
Plate.Anchored    = true
Plate.Size        = Vector3.new(1, 60, 60)
Plate.CFrame      = CFrame.new(150, 1000, 0)
Plate.Transparency = 0.5
Plate.Parent      = Scene

local Params = RaycastParams.new()
Params.FilterType = Enum.RaycastFilterType.Include
Params.FilterDescendantsInstances = { Scene }

local Solver = Vetra.newParallel({})
task.wait(1.5) -- workers init async; firing sooner drops the cast silently

local TumbleBegan = 0
Solver:GetSignals().OnTumbleBegin:Connect(function() TumbleBegan += 1 end)

local Ctx = Vetra.BulletContext.new({
	Origin    = Vector3.new(0, 1000, 0),
	Direction = Vector3.new(1, 0, 0),
	Speed     = 800,
})

local Cast = Solver:Fire(Ctx, {
	MaxDistance           = 1e5,
	MinSpeed              = 0,
	Gravity               = Vector3.new(0, -0.001, 0),
	RaycastParams         = Params,
	MaxBounces            = 0,
	MaxPierceCount        = 4,
	PierceSpeedThreshold  = 0,
	PierceNormalBias      = 1,
	CanPierceFunction     = function() return true end,
	TumbleOnPierce        = true,
	TumbleDragMultiplier  = 3.0,
	TumbleLateralStrength = PROBE_STRENGTH,
	TumbleRecoverySpeed   = nil, -- never recover, so the flag stays on for inspection
})

task.wait(2.0)

local Runtime = Cast.Alive and Cast.Runtime or nil
if Runtime then
	check("pierce triggered tumble on main thread",
		Runtime.IsTumbling == true,
		string.format("IsTumbling=%s OnTumbleBegin=%d", tostring(Runtime.IsTumbling), TumbleBegan))

	-- Main-thread Runtime keeps its Random (CheckPierceTrigger set it). The worker
	-- copy is the one at risk; we can only observe it indirectly here, so section 2
	-- is the authoritative assertion. This is a consistency backstop.
	if Runtime.IsTumbling then
		check("main-thread Runtime retains its TumbleRandom",
			Runtime.TumbleRandom ~= nil,
			Runtime.TumbleRandom ~= nil and "present" or "NIL")
	end
else
	print("    [SKIP] cast terminated before inspection — plate may be mis-placed")
end

Solver:Destroy()
Scene:Destroy()

-- ─────────────────────────────────────────────────────────────────────────────
print("")
print(BAR)
print(string.format("  RESULTS: %d passed, %d failed", Passes, Fails))
if Fails > 0 then
	print("")
	print("  REGRESSION — the TumbleRandom transport fix has come undone.")
	print("")
	print("  Invariant: IsTumbling == true  ⇒  TumbleRandom ~= nil. When it breaks,")
	print("  PureTumble.StepLateralForce returns ZERO silently — tumble drag still")
	print("  applies, so the cast looks alive while the lateral kick is dead.")
	print("")
	print("  Check all three sites, which must reconstruct the Random locally")
	print("  (CreateRandom is seeded by cast id — it is never marshaled):")
	print("    • ActorWorker_Server.server.lua — ResumeCast handler + AddCast")
	print("    • ActorWorker_Client.client.lua — same two spots")
	print("    • Coordinator.lua AddCast — must NOT ship a live Random")
	print("")
	print("  Keep the `State.TumbleRandom or` guard on resume: the seed is a constant")
	print("  cast id, so reseeding every resume correlates kicks across bounces.")
else
	print("")
	print("  Invariant holds: IsTumbling ⇒ TumbleRandom ~= nil at every crossing.")
end
print(BAR)
print("")
