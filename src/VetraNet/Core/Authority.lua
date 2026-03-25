--!strict
--Authority.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Core/Authority.lua
    Determines whether the current runtime is server or client.

    Both flags are computed once at module load time and stored as booleans.
    All callers get a simple table-read instead of a repeated RunService call.
    RunService:IsServer() is not expensive, but eliminating it here establishes
    the invariant that Authority.IsServer() is always O(1) and pure — useful
    for hot-path callers that need the check without any overhead.
]]

local Identity  = "Authority"

local Authority = {}
Authority.__type = Identity

local AuthorityMetatable = table.freeze({
	__index = Authority,
})

-- ─── References ──────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local IS_SERVER: boolean = RunService:IsServer()

-- ─── API ─────────────────────────────────────────────────────────────────────

function Authority.IsServer(): boolean
	return IS_SERVER
end

function Authority.IsClient(): boolean
	return not IS_SERVER
end

-- AssertServer/AssertClient error immediately when a server-only or client-only
-- module is required from the wrong context. This surfaces misconfigurations at
-- require() time — before any state is built — rather than producing confusing
-- nil errors deep in a frame loop.
function Authority.AssertServer(Context: string)
	if not IS_SERVER then
		error(string_format(
			"[VetraNet.%s] This module is server-only and must not be required on the client.",
			Context
		), 2)
	end
end

function Authority.AssertClient(Context: string)
	if IS_SERVER then
		error(string_format(
			"[VetraNet.%s] This module is client-only and must not be required on the server.",
			Context
		), 2)
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(Authority, {
	__index = function(_, Key)
		error(string_format("[VetraNet.Authority] Nil key '%s'", tostring(Key)), 2)
	end,
	__newindex = function(_, Key, _Value)
		error(string_format("[VetraNet.Authority] Write to protected key '%s'", tostring(Key)), 2)
	end,
}))
