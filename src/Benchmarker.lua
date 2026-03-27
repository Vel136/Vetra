--!strict
--!optimize 2

--[[
	MIT License
	Copyright (c) 2026 VeDevelopment

	VetraBenchmark — Serial vs Parallel solver performance profiler.

	Measures frame time, throughput, and overhead ratio across a configurable
	range of bullet counts and behavior profiles.

	HOW TO SET UP:
	  1. Place Vetra V4's src folder in ServerStorage, renamed "VetraV4"
	  2. Place a Part named "Start" in Workspace (fire origin)
	  3. Drop this ModuleScript into ServerScriptService
	  4. Require it, create a Benchmark instance, and call :Run()

	WHAT IS MEASURED:
	  • Frame time  (ms) — average Heartbeat wall-clock duration while N bullets are live
	  • Throughput       — total cast-steps processed per second
	  • Overhead ratio   — parallel / serial frame time  (< 1 = parallel wins)

	USAGE:
	  local VetraBenchmark = require(ServerScriptService.VetraBenchmark)

	  local Benchmark = VetraBenchmark.new({
	      BulletCounts       = { 100, 500, 1000 },
	      SampleFrames       = 120,
	      ParallelOnlyThreshold = 5000,
	  })

	  Benchmark:Run()
]]

-- ─── Identity ──────────────────────────────────────────────────────────────────

local Identity   = "VetraBenchmark"
local Benchmark  = {}
Benchmark.__type = Identity

-- ─── Services ──────────────────────────────────────────────────────────────────

local RunService    = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

-- ─── Module References ─────────────────────────────────────────────────────────

local VetraReference = script:WaitForChild('VetraReference',10)
if not VetraReference then
	error('Missing Vetra Reference , Make sure theres an object value called VetraReference')
end
local VetraV4Module = VetraReference.Value

-- ─── Types ─────────────────────────────────────────────────────────────────────

export type BenchmarkConfig = {
	--- Bullet counts to test at each profile.
	BulletCounts              : { number }?,
	--- At this count and above, the serial solver is skipped.
	ParallelOnlyThreshold     : number?,
	--- Heartbeat frames to sample per (solver × count × profile) cell.
	SampleFrames              : number?,
	--- Frames to wait after seeding bullets before sampling begins.
	WarmupFrames              : number?,
	--- Number of parallel Actor shards.
	ShardCount                : number?,
	--- World-space origin that all bullets are fired from.
	Origin                    : Vector3?,
	--- Half-angle of the firing cone in degrees.
	SpreadDeg                 : number?,
}

export type BehaviorProfile = {
	name     : string,
	behavior : { [string]: any },
}

export type SampleResult = {
	solverName     : string,
	profile        : string,
	bulletCount    : number,
	avgFrameMs     : number,
	minFrameMs     : number,
	maxFrameMs     : number,
	stdDevMs       : number,
	avgActiveCasts : number,
	throughput     : number,
}

export type ResultPair = {
	serial   : SampleResult?,
	parallel : SampleResult,
}

-- ─── Default Configuration ─────────────────────────────────────────────────────

local DEFAULT_CONFIG: BenchmarkConfig = {
	BulletCounts              = { 10, 25, 50, 100, 200, 500, 1000, 2000, 5000, 7500, 10000, 15000, 20000 },
	ParallelOnlyThreshold     = 7500,
	SampleFrames              = 120,
	WarmupFrames              = 30,
	ShardCount                = 64,
	Origin                    = Vector3.new(0, 50, 0),
	SpreadDeg                 = 25,
}

-- ─── Default Behavior Profiles ─────────────────────────────────────────────────

local DEFAULT_PROFILES: { BehaviorProfile } = {
	{
		name     = "Travel-only",
		behavior = {
			VisualizeCasts       = true,
			MaxDistance          = 2000,
			BounceSpeedThreshold = 9999,
			MaxBounces           = 0,
		},
	},
	{
		name     = "Bounce (no callback)",
		behavior = {
			MaxDistance          = 1000,
			MaxBounces           = 8,
			Restitution          = 0.65,
			BounceSpeedThreshold = 10,
		},
	},
	{
		name     = "Bounce (callback)",
		behavior = {
			MaxDistance          = 1000,
			MaxBounces           = 8,
			Restitution          = 0.65,
			BounceSpeedThreshold = 10,
			CanBounceFunction    = function(_Context: any, _result: any, _vel: Vector3): boolean
				return true
			end,
		},
	},
	{
		name     = "Pierce (callback)",
		behavior = {
			MaxDistance          = 1500,
			MaxPierceCount       = 5,
			PierceSpeedThreshold = 10,
			CanPierceFunction    = function(_Context: any, _result: any, _vel: Vector3): boolean
				return true
			end,
		},
	},
}

-- ─── Utility ───────────────────────────────────────────────────────────────────

--- Rounds `n` to `decimals` decimal places and returns it as a string.
local function FormatNumber(n: number, decimals: number): string
	local factor = 10 ^ decimals
	return tostring(math.round(n * factor) / factor)
end

--- Returns a random unit direction within a cone of `halfAngleDeg` degrees
--- opening along the +X axis.
local function RandomConeDirection(halfAngleDeg: number): Vector3
	local rad    = math.rad(halfAngleDeg)
	local theta  = math.random() * math.pi * 2
	local phi    = math.random() * rad
	local sinPhi = math.sin(phi)

	return Vector3.new(
		math.cos(phi),
		sinPhi * math.sin(theta),
		sinPhi * math.cos(theta)
	).Unit
end

-- ─── Benchmark Methods ─────────────────────────────────────────────────────────

local BenchmarkMetatable = table.freeze({ __index = Benchmark })

--- Fires `count` bullets from the configured origin.
local function FireBullets(
	self       : any,
	solver     : any,
	count      : number,
	behavior   : { [string]: any }
)
	local BulletContext = self._BulletContext
	local Origin        = self._Config.Origin :: Vector3
	local SpreadDeg     = self._Config.SpreadDeg :: number

	for _ = 1, count do
		local Context = BulletContext.new({
			Origin    = Origin,
			Direction = RandomConeDirection(SpreadDeg),
			Speed     = 150 + math.random() * 100,
		})
		solver:Fire(Context, behavior)
	end
end

--- Connects an OnTerminated signal that immediately respawns terminated bullets
--- so active count stays near `targetCount` throughout the sample window.
local function BindKeepAlive(
	self       : any,
	solver     : any,
	target     : number,
	behavior   : { [string]: any }
)
	local BulletContext = self._BulletContext
	local Origin        = self._Config.Origin :: Vector3
	local SpreadDeg     = self._Config.SpreadDeg :: number

	solver.Signals.OnTerminated:Connect(function()
		task.defer(function()
			if #solver._ActiveCasts >= target then return end

			local Context = BulletContext.new({
				Origin    = Origin,
				Direction = RandomConeDirection(SpreadDeg),
				Speed     = 150 + math.random() * 100,
			})
			solver:Fire(Context, behavior)
		end)
	end)
end

--- Seeds `targetCount` bullets, waits through warmup, tops up any deficit,
--- then collects `SampleFrames` wall-clock frame-time readings.
--- Returns a fully populated SampleResult.
local function CollectSamples(
	self        : any,
	solverName  : string,
	solver      : any,
	targetCount : number,
	behavior    : { [string]: any },
	profileName : string
): SampleResult

	local Config       = self._Config
	local WarmupFrames = Config.WarmupFrames :: number
	local SampleFrames = Config.SampleFrames :: number

	-- Seed initial bullets and let the simulation settle.
	FireBullets(self, solver, targetCount, behavior)

	for _ = 1, WarmupFrames do
		RunService.Heartbeat:Wait()
	end

	-- Top up any bullets lost during warmup.
	local Deficit = targetCount - #solver._ActiveCasts
	if Deficit > 0 then
		FireBullets(self, solver, Deficit, behavior)
	end

	-- Collect wall-clock frame durations.
	local Samples    : { number } = table.create(SampleFrames)
	local ActiveSum  : number     = 0

	for i = 1, SampleFrames do
		local T0 = os.clock()
		RunService.Heartbeat:Wait()
		Samples[i]  = (os.clock() - T0) * 1000   -- convert to ms
		ActiveSum  += #solver._ActiveCasts
	end

	-- Reduce: min, max, sum.
	local Sum  = 0
	local MinV = math.huge
	local MaxV = -math.huge

	for _, V in Samples do
		Sum  += V
		MinV  = math.min(MinV, V)
		MaxV  = math.max(MaxV, V)
	end

	local Avg = Sum / SampleFrames

	-- Variance → standard deviation.
	local Variance = 0
	for _, V in Samples do
		local Delta = V - Avg
		Variance   += Delta * Delta
	end
	local StdDev = math.sqrt(Variance / SampleFrames)

	local AvgActive  = ActiveSum / SampleFrames
	local Throughput = AvgActive * (1000 / Avg)

	return {
		solverName     = solverName,
		profile        = profileName,
		bulletCount    = targetCount,
		avgFrameMs     = Avg,
		minFrameMs     = MinV,
		maxFrameMs     = MaxV,
		stdDevMs       = StdDev,
		avgActiveCasts = AvgActive,
		throughput     = Throughput,
	}
end

-- ─── Printing Helpers ──────────────────────────────────────────────────────────

--- Prints a single measurement row to Output.
local function PrintResult(Result: SampleResult)
	print(string.format(
		"  %-12s | %-24s | %5d bullets | avg %s ms  min %s  max %s  σ %s | %s cast-steps/s",
		Result.solverName,
		Result.profile,
		Result.bulletCount,
		FormatNumber(Result.avgFrameMs, 3),
		FormatNumber(Result.minFrameMs, 3),
		FormatNumber(Result.maxFrameMs, 3),
		FormatNumber(Result.stdDevMs,   3),
		FormatNumber(Result.throughput, 0)
		))
end

--- Prints the parallel/serial ratio and winner label beneath a result pair.
local function PrintComparison(Serial: SampleResult, Parallel: SampleResult)
	local Ratio  = Parallel.avgFrameMs / Serial.avgFrameMs
	local Winner = if Ratio < 0.95 then "PARALLEL FASTER"
		elseif Ratio > 1.05 then "SERIAL FASTER"
		else "ROUGHLY EQUAL"

	print(string.format(
		"    → parallel/serial ratio: %sx  [%s]",
		FormatNumber(Ratio, 3),
		Winner
		))
end

-- ─── Printing Helpers ──────────────────────────────────────────────────────────

local SEPARATOR_HEAVY = string.rep("─", 75)
local SEPARATOR_LIGHT = string.rep("─", 75)

--- Prints the header banner that appears at the start of a run.
local function PrintHeader(Config: BenchmarkConfig)
	local SampleFrames          = Config.SampleFrames          :: number
	local ShardCount            = Config.ShardCount            :: number
	local ParallelOnlyThreshold = Config.ParallelOnlyThreshold :: number

	print("")
	print(SEPARATOR_HEAVY)
	print("  Vetra V4  —  Serial vs Parallel Benchmark")
	print(string.format("  Samples per cell : %d frames", SampleFrames))
	print(string.format("  Shard count      : %d", ShardCount))
	print(string.format("  Serial skipped   : %d+ bullets (parallel only)", ParallelOnlyThreshold))
	print(SEPARATOR_HEAVY)
	print("  NOTE: frame time = wall-clock Heartbeat duration (solver step + scheduler overhead).")
	print("        Treat values as relative, not absolute.")
	print("")
end

--- Prints the consolidated summary table after all profiles have been measured.
local function PrintSummary(AllResults: { ResultPair })
	print("")
	print(SEPARATOR_HEAVY)
	print("  SUMMARY")
	print(SEPARATOR_LIGHT)
	print(string.format(
		"  %-26s  %-10s  %-12s  %-12s  %-8s",
		"Profile · Bullets", "Winner", "Serial ms", "Parallel ms", "Ratio"
		))
	print(SEPARATOR_LIGHT)

	for _, Pair in AllResults do
		local Serial   = Pair.serial
		local Parallel = Pair.parallel

		if Serial then
			local Ratio  = Parallel.avgFrameMs / Serial.avgFrameMs
			local Winner = if Ratio < 0.95 then "PARALLEL" elseif Ratio > 1.05 then "SERIAL" else "EQUAL"

			print(string.format(
				"  %-22s ×%-5d  %-10s  %-12s  %-12s  %-8s",
				Serial.profile:sub(1, 22),
				Serial.bulletCount,
				Winner,
				FormatNumber(Serial.avgFrameMs,   3),
				FormatNumber(Parallel.avgFrameMs, 3),
				FormatNumber(Ratio, 3) .. "x"
				))
		else
			print(string.format(
				"  %-22s ×%-5d  %-10s  %-12s  %-12s  %-8s",
				Parallel.profile:sub(1, 22),
				Parallel.bulletCount,
				"PARALLEL",
				"skipped",
				FormatNumber(Parallel.avgFrameMs, 3),
				"n/a"
				))
		end
	end

	print(SEPARATOR_HEAVY)
	print(string.format("  [%s] Done.", Identity))
	print("")
end
-- ─── Public API ────────────────────────────────────────────────────────────────

--- Runs the full benchmark suite across all configured profiles and bullet counts.
--- Blocks the calling coroutine until complete (intended to be called inside a task.spawn).
function Benchmark.Run(self: any)
	assert(not self._Ran, "[" .. Identity .. "] Run() called more than once on the same instance.")
	self._Ran = true

	local Config    = self._Config
	local Vetra     = self._Vetra
	local Profiles  = self._Profiles

	local AllResults: { ResultPair } = {}

	task.wait(2)
	PrintHeader(Config)

	local BulletCounts         = Config.BulletCounts         :: { number }
	local ShardCount           = Config.ShardCount           :: number
	local ParallelOnlyThreshold = Config.ParallelOnlyThreshold :: number

	for _, Profile in Profiles do
		print(string.format("── Profile: %s ──", Profile.name))

		for _, Count in BulletCounts do
			local IsParallelOnly = Count >= ParallelOnlyThreshold
			local SerialResult : SampleResult? = nil

			-- ── Serial ──────────────────────────────────────────────────────────
			if not IsParallelOnly then
				local SerialSolver = Vetra.new()
				BindKeepAlive(self, SerialSolver, Count, Profile.behavior)

				SerialResult = CollectSamples(
					self, "serial", SerialSolver, Count, Profile.behavior, Profile.name
				)

				PrintResult(SerialResult)
				SerialSolver:Destroy()
				task.wait(0.1)
			else
				print(string.format(
					"  %-12s | %-24s | %5d bullets | [serial skipped — parallel only above %d]",
					"serial", Profile.name, Count, ParallelOnlyThreshold
					))
			end

			-- ── Parallel ────────────────────────────────────────────────────────
			local ParallelSolver = Vetra.newParallel({ ShardCount = ShardCount })
			BindKeepAlive(self, ParallelSolver, Count, Profile.behavior)

			local ParallelResult = CollectSamples(
				self, "parallel", ParallelSolver, Count, Profile.behavior, Profile.name
			)

			PrintResult(ParallelResult)

			if SerialResult then
				PrintComparison(SerialResult, ParallelResult)
			end

			table.insert(AllResults, {
				serial   = SerialResult,
				parallel = ParallelResult,
			})

			ParallelSolver:Destroy()
			task.wait(0.1)
		end

		print("")
	end

	PrintSummary(AllResults)
end

-- ─── Factory ───────────────────────────────────────────────────────────────────

local Factory = {}
Factory.__type = Identity

--- Creates a new Benchmark instance.
---
--- @param UserConfig   BenchmarkConfig?   Overrides for the default config.
--- @param UserProfiles { BehaviorProfile }?  Replace all profiles if supplied.
---
--- @return Benchmark
function Factory.new(UserConfig: BenchmarkConfig?, UserProfiles: { BehaviorProfile }?): any
	assert(VetraV4Module, string.format(
		"[%s] VetraReference ObjectValue is missing or its Value is nil — point it at the VetraV4 ModuleScript.",
		Identity
		))

	local Vetra         = require(VetraV4Module)
	local BulletContext = require(VetraV4Module.Core.BulletContext)

	-- Merge user overrides onto defaults.
	local ResolvedConfig: BenchmarkConfig = {}

	for Key, DefaultValue in DEFAULT_CONFIG :: any do
		local Override = (UserConfig :: any) and (UserConfig :: any)[Key]
		;(ResolvedConfig :: any)[Key] = if Override ~= nil then Override else DefaultValue
	end

	local ResolvedProfiles = UserProfiles or DEFAULT_PROFILES

	local Instance = setmetatable({
		_Config        = ResolvedConfig,
		_Profiles      = ResolvedProfiles,
		_Vetra         = Vetra,
		_BulletContext = BulletContext,
		_Ran           = false,
	}, BenchmarkMetatable)

	return Instance
end

-- ─── Module Return ─────────────────────────────────────────────────────────────

local ModuleMetatable = table.freeze({
	__index = function(_, Key: string)
		warn(string.format("[%s] Attempted to access nil key '%s'", Identity, tostring(Key)))
	end,
	__newindex = function(_, Key: string, Value: any)
		error(string.format(
			"[%s] Attempted to write to protected key '%s' = '%s'",
			Identity, tostring(Key), tostring(Value)
			), 2)
	end,
})

return setmetatable(Factory, ModuleMetatable)