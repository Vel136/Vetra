--!native
--!optimize 2
--!strict

-- ─── ParallelPhysics (aggregator) ────────────────────────────────────────────

local Identity        = "ParallelPhysics"
local ParallelPhysics = {}
ParallelPhysics.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Parent.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

local StepModule             = require(script.Parent.Step)
local StepHighFidelityModule = require(script.Parent.StepHighFidelity)
local LODSpatial             = require(script.Parent.LODSpatial)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Public API ──────────────────────────────────────────────────────────────

ParallelPhysics.Step                     = StepModule.Step
ParallelPhysics.StepHighFidelity         = StepHighFidelityModule.StepHighFidelity
ParallelPhysics.ResolveLODAndSpatialSkip = LODSpatial.Resolve

-- ─── Module Return ───────────────────────────────────────────────────────────

local ParallelPhysicsMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("ParallelPhysics: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"ParallelPhysics: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(ParallelPhysics, ParallelPhysicsMetatable)