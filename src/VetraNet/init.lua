--!strict
--init.lua
--!native
--!optimize 2

-- ─── References ──────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── Module Implementation ───────────────────────────────────────────────────

if RunService:IsServer() then
	return require(script.Server)
else
	return require(script.Client)
end
