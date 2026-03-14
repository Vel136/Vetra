--!strict

-- ─── Parallel ────────────────────────────────────────────────────────────────
--[[
    Parallel sub-module index.
    Exists so Coordinator.luau can resolve siblings via script.Parent.X.
]]

return {
    Coordinator    = require(script.Coordinator),
	ParallelPhysics = require(script.Physics.ParallelPhysics),
}
