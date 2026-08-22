--!strict
-- Vetra ballistics validation against JBM 175gr SMK G7 reference
-- JBM run: BC=0.243 G7, MV=3000fps, ICAO standard atmosphere, no wind

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vetra = require(ReplicatedStorage.src)

-- ── Unit scale ───────────────────────────────────────────────────────────────
-- 1 stud = 1 metre (set this in your test place — avoids all unit confusion)
-- Gravity in Roblox workspace should be set to 9.80665 studs/s²
-- workspace.Gravity = 9.80665

-- ── Reference table (from JBM TOF column, bore-axis drop = -½·g·t²) ─────────
local REFERENCE = {
	-- { range_m, tof_s, vel_ms, bore_drop_m }
	{   0.0, 0.000, 914.4,   0.000 },
	{  91.4, 0.103, 856.2,  -0.052 },
	{ 182.9, 0.214, 797.9,  -0.225 },
	{ 274.3, 0.333, 741.9,  -0.543 },
	{ 365.8, 0.461, 688.2,  -1.043 },
	{ 457.2, 0.599, 636.8,  -1.759 },
	{ 548.6, 0.748, 587.7,  -2.742 },
	{ 640.1, 0.911, 540.5,  -4.063 },
	{ 731.5, 1.087, 495.0,  -5.791 },
	{ 823.0, 1.281, 451.2,  -8.044 },
	{ 914.4, 1.494, 409.3, -10.946 },
}

-- ── Behavior ─────────────────────────────────────────────────────────────────
local Behavior = Vetra.BehaviorBuilder.new()
	:Physics()
	:MaxDistance(950)
	:Gravity(Vector3.new(0, -9.80665, 0))
	:BulletMass(0.01134)          -- 175gr in kg
	:Done()
	:Drag()
	:Model(Vetra.Enums.DragModel.G7)
	:Coefficient(0.243) -- ≈ 4.115)           -- Litz measured G7 BC
	:SegmentInterval(0.001)       -- 5ms recalc — fine enough for this test
	:Done()
	:Debug()
	:Visualize(true)
	:Done()
	:Build()

-- ── Fire ─────────────────────────────────────────────────────────────────────
local Solver  = Vetra.new()
local Signals = Solver:GetSignals()

local Origin    = Vector3.new(0, 50, 0)   -- elevated so bullet doesn't hit ground
local MuzzleVel = 914.4                    -- 3000 ft/s in m/s

local lastLoggedYd = -1
local results = {}

Signals.OnTravel:Connect(function(context, position, velocity)
	local dist = context.Length
	local yd     = math.floor(dist / 0.9144)   -- metres to yards
	local bucket = math.floor(yd / 100) * 100  -- snap to 100yd buckets
	
	if bucket > lastLoggedYd and bucket <= 1000 then
		lastLoggedYd = bucket
		table.insert(results, {
			range_yd  = bucket,
			range_m   = math.round(dist * 10) / 10,
			vel_ms    = math.round(velocity.Magnitude * 10) / 10,
			drop_m    = math.round((position.Y - Origin.Y) * 1000) / 1000,
		})
	end
end)

Signals.OnTerminated:Connect(function()
	-- Print comparison table
	print(string.format("\n%-8s %-10s %-12s %-12s %-10s %-10s %-10s",
		"Range", "Vel(m/s)", "JBM vel", "Vel err%", "Drop(m)", "JBM drop", "Drop err%"))
	print(string.rep("-", 80))

	for _, row in results do
		-- Find matching reference row
		local ref = nil
		for _, r in REFERENCE do
			if math.abs(r[1] - row.range_m) < 10 then
				ref = r
				break
			end
		end
		if ref then
			local velErr  = math.abs(row.vel_ms  - ref[3]) / ref[3] * 100
			local dropErr = ref[4] ~= 0 and math.abs(row.drop_m - ref[4]) / math.abs(ref[4]) * 100 or 0
			print(string.format("%-8s %-10.1f %-12.1f %-12.2f %-10.3f %-10.3f %-10.2f",
				row.range_yd.."yd",
				row.vel_ms, ref[3], velErr,
				row.drop_m, ref[4], dropErr))
		end
	end
	print("\nPass criteria: velocity error < 1% at all ranges, drop error < 3% at 1000yd")
end)

-- Fire horizontally (no elevation — pure bore axis)
local BulletContext = Vetra.BulletContext.new({
	Origin    = Origin,
	Direction = Vector3.new(1, 0, 0),   -- dead flat, no elevation
	Speed     = MuzzleVel,
})

Solver:Fire(BulletContext, Behavior)