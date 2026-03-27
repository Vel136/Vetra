--!native
--!optimize 2
--!strict

-- ─── GyroDrift ────────────────────────────────────────────────────────────────
--[[
    Gyroscopic spin-drift wrapper — Cast-aware delegation to Pure/GyroDrift.

    Thin Cast-aware layer that reads GyroDriftRate and GyroDriftAxis from the
    behavior and delegates all math to Physics/Pure/GyroDrift, which is also
    called directly by the parallel DragRecalc path.

    See Physics/Pure/GyroDrift for a full explanation of the physics model.
]]

local Identity   = "GyroDrift"
local GyroDrift  = {}
GyroDrift.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra   = script.Parent.Parent
local Physics = script.Parent
local Core    = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService     = require(Core.Logger)
local PureGyroDrift  = require(Physics.Pure.GyroDrift)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

-- Thin delegation — pure math lives in Physics/Pure/GyroDrift.
function GyroDrift.ComputeForce(
	Velocity      : Vector3,
	DriftRate     : number,
	ReferenceAxis : Vector3?
): Vector3
	return PureGyroDrift.ComputeForce(Velocity, DriftRate, ReferenceAxis)
end

function GyroDrift.IsActive(Behavior: any): boolean
	return Behavior.GyroDriftRate ~= nil and Behavior.GyroDriftRate ~= 0
end

-- ─── Module Return ────────────────────────────────────────────────────────────

local GyroDriftMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("GyroDrift: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"GyroDrift: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
		))
	end,
})

return setmetatable(GyroDrift, GyroDriftMetatable)
