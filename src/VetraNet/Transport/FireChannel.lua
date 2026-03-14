--!strict
--FireChannel.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/FireChannel.lua
    Owns the fire request pipeline.

    Client side: serializes a fire request into a buffer payload and sends it
    to the server via RemoteEvent.

    Server side: receives incoming fire payloads, deserializes them, hands off
    to the registered callback (which runs FireValidator), and on successful
    validation replicates the authoritative fire event to all clients so they
    can spawn cosmetic bullets.

    FireChannel has no knowledge of validation logic — it is purely a message
    pipe. The registered callback is responsible for deciding whether to accept
    or reject the fire request.
]]

local Identity    = "FireChannel"

local FireChannel = {}
FireChannel.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Core      = script.Parent.Parent.Core
local Transport = script.Parent
local Types     = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local BlinkSchema = require(Transport.BlinkSchema)
local Constants   = require(Types.Constants)
local LogService  = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local buffer_len    = buffer.len
local string_format = string.format

-- ─── Client API ──────────────────────────────────────────────────────────────

-- Serialize and send a fire request to the server.
-- Context is a BulletContext (provides Origin, Direction, Speed).
-- BehaviorHash is the u16 resolved from BehaviorRegistry.GetHash.
-- CastId is the client-local cast identifier.
-- Timestamp is workspace:GetServerTimeNow() captured at fire moment —
-- capturing it here rather than in the server-side callback ensures the
-- timestamp reflects the actual client-side fire instant, not the server
-- processing time.
function FireChannel.SendFire(
	Remote       : RemoteEvent,
	Origin       : Vector3,
	Direction    : Vector3,
	Speed        : number,
	BehaviorHash : number,
	CastId       : number,
	Timestamp    : number
)
	local Payload = BlinkSchema.EncodeFire(Origin, Direction, Speed, BehaviorHash, CastId, Timestamp)
	Remote:FireServer(Payload)
end

-- ─── Server API ──────────────────────────────────────────────────────────────

-- Register a server-side callback for incoming fire requests.
-- Callback signature: (player: Player, payload: FirePayload) → void
-- The callback is responsible for validation and for firing the server bullet.
-- FireChannel only deserializes the buffer — it does not inspect the payload.
function FireChannel.OnFireReceived(
	Remote   : RemoteEvent,
	Callback : (Player: Player, Payload: any) -> ()
)
	Remote.OnServerEvent:Connect(function(Player: Player, RawPayload: any)
		-- Guard against non-buffer payloads. A client sending a string or table
		-- instead of a buffer is either buggy or exploiting — reject both cases.
		if typeof(RawPayload) ~= "buffer" then
			Logger:Warn(string_format(
				"FireChannel: player '%s' sent non-buffer fire payload (type: %s) — rejecting",
				Player.Name, typeof(RawPayload)
				))
			return
		end

		-- Guard against undersized buffers. A buffer shorter than the minimum
		-- payload size cannot be a valid fire request.
		if buffer_len(RawPayload) < Constants.FIRE_PAYLOAD_BYTES then
			Logger:Warn(string_format(
				"FireChannel: player '%s' sent truncated fire payload (%d bytes) — rejecting",
				Player.Name, buffer_len(RawPayload)
				))
			return
		end

		local Success, Result = pcall(BlinkSchema.DecodeFire, RawPayload)
		if not Success then
			Logger:Warn(string_format(
				"FireChannel: failed to decode fire payload from '%s': %s",
				Player.Name, tostring(Result)
				))
			return
		end

		Callback(Player, Result)
	end)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(FireChannel, {
	__index = function(_, Key)
		Logger:Warn(string_format("FireChannel: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("FireChannel: write to protected key '%s'", tostring(Key)))
	end,
}))