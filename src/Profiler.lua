--!native
--!optimize 2

local Profiler = {}

Profiler.Enabled = false


local function def(key: string, kind: "phase" | "counter", labelText: string)
	return { key = key, kind = kind, label = labelText }
end

Profiler.Phase = {
	DragRecalc  = def("dragRecalc",   "phase", "drag recalc"),
	Kinematics  = def("kinematics",   "phase", "kinematics (position/velocity)"),
	Occupancy   = def("occupancy",    "phase", "occupancy grid check"),
	Raycast     = def("raycast",      "phase", "raycast"),
	Signals     = def("signals",      "phase", "hit/travel signals"),
	Lod         = def("ff_lod",       "phase", "LOD + spatial gating"),
	StepBase    = def("ff_step_base", "phase", "step (base fidelity)"),
	StepHf      = def("ff_step_hf",   "phase", "step (high fidelity)"),
	Writeback   = def("ff_writeback", "phase", "write results to state"),
	Pack        = def("ff_pack",      "phase", "pack batch buffer"),
	HfDda       = def("hf_dda",       "phase", "HF occupancy march (DDA)"),
	HfRaycast   = def("hf_raycast",   "phase", "HF raycast"),
	CoordUnpack   = def("coord_unpack",   "phase", "main: unpack event buffer"),
	CoordDispatch = def("coord_dispatch", "phase", "main: event handler dispatch"),
	CoordCosmetic = def("coord_cosmetic", "phase", "main: cosmetic BulkMoveTo"),
	CoordFlush    = def("coord_flush",    "phase", "main: travel-batch flush"),
	CoordProvider = def("coord_provider", "phase", "main: homing/trajectory provider calls"),
	CoordProvUser = def("coord_prov_user", "phase", "  ├─ user provider pcall"),
	CoordProvSend = def("coord_prov_send", "phase", "  ├─ SendMessage to worker"),
	CoordProvMath = def("coord_prov_math", "phase", "  └─ position/velocity math"),
}

Profiler.Counter = {
	CastsStepped = def("casts_stepped", "counter", "casts stepped"),
	OccCalls     = def("occ_calls",     "counter", "occupancy checks run"),
	DynCalls     = def("dyn_calls",     "counter", "dynamic-occupancy checks"),
	OccSkips     = def("occ_skips",     "counter", "raycasts skipped by occupancy"),
	GateFrozen   = def("gate_frozen",   "counter", "casts frozen (HF budget spent)"),
	LodSkipped   = def("lod_skipped",   "counter", "casts skipped by LOD"),
	CoordEvents  = def("coord_events",  "counter", "main: events unpacked"),
}

local REGISTRY: { [string]: { key: string, kind: string, label: string } } = {}
for _, group in { Profiler.Phase, Profiler.Counter } do
	for _, d in group do
		REGISTRY[d.key] = d
	end
end


local buckets: { [string]: { time: number, calls: number } } = {}
local frames = 0

local os_clock = os.clock

function Profiler.Reset()
	table.clear(buckets)
	frames = 0
end

function Profiler.MarkFrame()
	if Profiler.Enabled then frames += 1 end
end

local function keyOf(phase): string
	return type(phase) == "table" and phase.key or phase
end

function Profiler.Add(phase, dt: number)
	local name = keyOf(phase)
	local b = buckets[name]
	if b then
		b.time  += dt
		b.calls += 1
	else
		buckets[name] = { time = dt, calls = 1 }
	end
end

function Profiler.Count(counter)
	Profiler.Add(counter, 0)
end

function Profiler.CountN(counter, n: number)
	if n <= 0 then return end
	local name = keyOf(counter)
	local b = buckets[name]
	if b then
		b.calls += n
	else
		buckets[name] = { time = 0, calls = n }
	end
end

function Profiler.Wrap(phase, fn, ...)
	if not Profiler.Enabled then return fn(...) end
	local t0 = os_clock()
	local a, b, c, d = fn(...)
	Profiler.Add(phase, os_clock() - t0)
	return a, b, c, d
end


local function labelOf(name: string): string
	local d = REGISTRY[name]
	return d and d.label or name
end

local function isCounter(name: string): boolean
	local d = REGISTRY[name]
	return d ~= nil and d.kind == "counter"
end

function Profiler.Report(Label: string?)
	local timings:  { { name: string, time: number, calls: number } } = {}
	local counters: { { name: string, count: number } } = {}
	local total = 0
	for name, b in buckets do
		if isCounter(name) then
			counters[#counters + 1] = { name = name, count = b.calls }
		else
			timings[#timings + 1] = { name = name, time = b.time, calls = b.calls }
			total += b.time
		end
	end
	table.sort(timings,  function(x, y) return x.time > y.time end)
	table.sort(counters, function(x, y) return x.count > y.count end)

	local line = string.rep("─", 72)
	local f    = frames > 0 and frames or 1

	print("")
	print(line)
	print(string.format("  %s", Label or "Vetra Step Profiler"))
	print(string.format("  %d frames sampled  ·  %.2f ms measured  ·  %.4f ms per frame",
		frames, total * 1000, total / f * 1000))
	print(line)

	print("  WHERE THE TIME GOES")
	print(string.format("    %-30s %10s %8s", "phase", "ms/frame", "share"))
	for _, r in timings do
		local pct     = total > 0 and (r.time / total * 100) or 0
		local msFrame = r.time / f * 1000
		local bars    = math.floor(pct / 5 + 0.5)
		print(string.format("    %-30s %10.4f %7.1f%%  %s",
			labelOf(r.name), msFrame, pct, string.rep("▇", bars)))
	end

	if #counters > 0 then
		print("")
		print("  COUNTS (per frame)")
		for _, c in counters do
			print(string.format("    %-30s %10.1f", labelOf(c.name), c.count / f))
		end
	end

	print(line)
	print("")
end

return Profiler
