--!strict
--Session.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Core/Session.lua
    Tracks active network sessions per player on the server.

    A session is created the first time a player fires and destroyed when they
    leave the game. The session tracks how many bullets the player currently has
    in flight so FireValidator can enforce the MaxConcurrentPerPlayer cap.

    SERVER-ONLY. Errors at require() time if loaded on the client.
    Client code has no concept of sessions — the session layer is entirely
    server-side authority infrastructure.
]]

local Identity = "Session"

local Session  = {}
Session.__type = Identity

local SessionMetatable = table.freeze({
	__index = Session,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent

-- ─── Module References ───────────────────────────────────────────────────────

local Authority  = require(Core.Authority)
local LogService = require(Core.Logger)
local Enums      = require(script.Parent.Parent.Types.Enums)

-- Fail immediately if required on the client. Session state on the client
-- would be meaningless and could mislead exploiters into thinking their
-- session is valid when the real authority is on the server.
Authority.AssertServer("Session")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_max      = math.max
local table_clear   = table.clear
local string_format = string.format

-- ─── Types ───────────────────────────────────────────────────────────────────

type SessionEntry = {
	_ActiveCastIds : { [number]: true },
	_CastCount     : number,
}

-- ─── Factory ─────────────────────────────────────────────────────────────────

function Session.new(ResolvedConfig: any): any
	local self = setmetatable({
		_Config    = ResolvedConfig,
		_Destroyed = false,
		_Sessions = {},
	}, SessionMetatable)
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

-- Create a fresh session for a player. Called the first time they fire or
-- when they connect, depending on the consumer's preference.
-- Calling Register on an already-registered player is a no-op with a warning
-- rather than an error — PlayerAdded can fire multiple times in edge cases.
function Session.Register(self: any, Player: Player)
	if self._Sessions[Player] then
		Logger:Warn(string_format(
			"Session.Register: player '%s' already has an active session — ignoring duplicate",
			Player.Name
			))
		return
	end
	self._Sessions[Player] = {
		_ActiveCastIds = {},
		_CastCount     = 0,
	}
end

-- Destroy the session for a disconnected player and release all tracked cast
-- references. Called from Players.PlayerRemoving.
function Session.Unregister(self: any, Player: Player)
	if not self._Sessions[Player] then
		-- Not an error — PlayerRemoving can fire for players who never fired.
		return
	end
	self._Sessions[Player] = nil
end

-- Returns a SessionStatus string:
--   "ok"       — player has an active session with room for another bullet.
--   "cap"      — concurrent bullet count is at the configured maximum.
--   "inactive" — no session is registered for this player.
--
-- Note: this function does NOT lazily create sessions. Sessions are always
-- created by ServerHooks (via PlayerAdded and the pre-existing-player loop).
-- Returning "inactive" here surfaces a real registration gap rather than
-- hiding it behind a silent auto-create.
function Session.CanFire(self: any, Player: Player): string
	local Entry = self._Sessions[Player]
	if not Entry then
		return Enums.SessionStatus.Inactive
	end
	
	if Entry._CastCount >= self._Config.MaxConcurrentPerPlayer then
		return Enums.SessionStatus.AtLimit
	end	
	return Enums.SessionStatus.Ready
end

-- Record a new in-flight cast for the player. Called after FireValidator passes.
function Session.AddCast(self: any, Player: Player, CastId: number)
	local Entry = self._Sessions[Player]
	if not Entry then
		Logger:Warn(string_format(
			"Session.AddCast: no session for player '%s' — creating lazily",
			Player.Name
			))
		self:Register(Player)
		Entry = self._Sessions[Player]
	end
	if Entry._ActiveCastIds[CastId] then
		-- Duplicate cast ID — possible if a client sends the same fire event
		-- twice (retransmit exploit). Reject silently.
		Logger:Warn(string_format(
			"Session.AddCast: duplicate castId %d for player '%s' — ignoring",
			CastId, Player.Name
			))
		return
	end
	Entry._ActiveCastIds[CastId] = true
	Entry._CastCount += 1
end

-- Release a terminated cast from the player's session budget.
-- Called from Vetra's OnTerminated signal.
function Session.RemoveCast(self: any, Player: Player, CastId: number)
	local Entry = self._Sessions[Player]
	if not Entry then
		-- Player disconnected before the bullet terminated — not an error.
		return
	end
	if not Entry._ActiveCastIds[CastId] then
		-- The cast was never registered (e.g. it was rejected at validation).
		return
	end
	Entry._ActiveCastIds[CastId] = nil
	Entry._CastCount = math_max(0, Entry._CastCount - 1)
end

-- Returns all currently tracked cast IDs for a player.
-- Used by LateJoinHandler to determine which bullets need initial sync.
function Session.GetActiveCasts(self: any, Player: Player): { number }
	local Entry = self._Sessions[Player]
	if not Entry then
		return {}
	end
	
	local CastIds = {}
	for CastId in Entry._ActiveCastIds do
		CastIds[#CastIds + 1] = CastId
	end
	
	return CastIds
end

-- Idempotent — calling Destroy twice must not error.
function Session.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Sessions)
	self._Sessions = nil
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(Session, {
	__index = function(_, Key)
		Logger:Warn(string_format("Session: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("Session: write to protected key '%s'", tostring(Key)))
	end,
}))