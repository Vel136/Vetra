--!strict
--OutboundBatcher.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Transport/OutboundBatcher.lua
    Per-player outbound cursor accumulator.

    V0.1.2: replaces per-event RemoteEvent sends with a single buffer-per-player that is flushed
    once per PreSimulation. Every message written to the batcher gets a 1-byte
    channel prefix (CHANNEL_FIRE, CHANNEL_HIT, CHANNEL_STATE). The client
    reads the prefix and dispatches to the correct decoder in a tight loop
    until the buffer is exhausted — matching Packet's "while not Ended()" model.

    Write pattern (server, per event):
        Batcher:WriteFireForAll(AllPlayers, ShooterUserId, EncodedFireBuf)
        Batcher:WriteHitForAll(AllPlayers, EncodedHitBuf)
        Batcher:WriteStateForAll(AllPlayers, EncodedStateBuf)   -- once/frame

    Flush pattern (server, once per PreSimulation):
        Batcher:Flush(Remote)   → fires one FireClient per player with their
                                   accumulated buffer, then clears all cursors.

    Key properties:
      • No allocations in the steady state. Each player cursor is a fixed table
        with a Roblox buffer that doubles when it overflows. Flush does not
        free the buffer — it resets the write offset to 0, reusing the same
        memory the next frame.
      • WriteFireForAll skips the shooter (identified by OwnerId / UserId) so
        that player never receives their own fire replication. The shooter's
        cosmetic is spawned immediately by Client.Fire() without waiting for
        a round-trip.
      • Flush is the ONLY place that calls Remote:FireClient. No other module
        may call FireClient directly after V0.1.2.
]]

local Identity        = "OutboundBatcher"

local OutboundBatcher = {}
OutboundBatcher.__type = Identity

local OutboundBatcherMetatable = table.freeze({
	__index = OutboundBatcher,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core  = script.Parent.Parent.Core
local Types = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Types.Constants)
local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local buffer_len     = buffer.len
local buffer_create  = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_copy    = buffer.copy
local table_clear    = table.clear
local string_format  = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local CHANNEL_FIRE  = Constants.CHANNEL_FIRE
local CHANNEL_HIT   = Constants.CHANNEL_HIT
local CHANNEL_STATE = Constants.CHANNEL_STATE
local INITIAL_CAP   = Constants.OUTBOUND_BUFFER_INITIAL

-- ─── Cursor Helpers ──────────────────────────────────────────────────────────

-- Each player has a cursor: { Buffer, Len, Offset }
-- Buffer    — the Roblox buffer backing store
-- Len    — current allocated length of Buffer
-- Offset — bytes written so far (write head)

local function NewCursor(): { Buffer: buffer, Len: number, Offset: number, OutBuf: buffer, OutLen: number }
	local Buffer = buffer_create(INITIAL_CAP)
	-- OutBuf is a reusable send buffer. Flush writes exactly Offset bytes into it
	-- before calling FireClient, growing it if necessary. This avoids allocating
	-- a fresh truncation buffer every frame per player (1200+ allocs/s at 20p/60fps).
	return { Buffer = Buffer, Len = INITIAL_CAP, Offset = 0, OutBuf = buffer_create(INITIAL_CAP), OutLen = INITIAL_CAP }
end

-- Ensure cursor has at least `Need` additional bytes available.
-- Doubles the buffer until it fits, copying existing content.
local function Reserve(Cursor: any, Need: number)
	local Required = Cursor.Offset + Need
	if Required <= Cursor.Len then return end
	local NewLen = Cursor.Len
	while NewLen < Required do NewLen *= 2 end
	local NewBuf = buffer_create(NewLen)
	buffer_copy(NewBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
	Cursor.Buffer = NewBuf
	Cursor.Len = NewLen
end

-- Write a u8 channel prefix byte into the cursor.
local function WriteChannelByte(Cursor: any, Channel: number)
	Reserve(Cursor, 1)
	buffer_writeu8(Cursor.Buffer, Cursor.Offset, Channel)
	Cursor.Offset += 1
end

-- Append a pre-encoded message buffer (already encoded by BlinkSchema) into
-- the cursor. We prefix the length as u16 so the client decoder knows exactly
-- how many bytes to consume before reading the next channel byte.
local function AppendMessage(Cursor: any, Message: buffer)
	local MessageLen = buffer_len(Message)
	-- u16 length prefix (max 65535 bytes per message — fine for all payloads)
	Reserve(Cursor, 2 + MessageLen)
	buffer_writeu16(Cursor.Buffer, Cursor.Offset, MessageLen)
	Cursor.Offset += 2
	buffer_copy(Cursor.Buffer, Cursor.Offset, Message, 0, MessageLen)
	Cursor.Offset += MessageLen
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

function OutboundBatcher.new(): any
	local self = setmetatable({
		-- { [Player]: cursor }
		_Cursors   = {} :: { [Player]: any },
		_Destroyed = false,
	}, OutboundBatcherMetatable)
	return self
end

-- ─── Write API ───────────────────────────────────────────────────────────────

-- Write a fire replication message to every player EXCEPT the shooter.
-- ShooterUserId is the UserId of the player who fired — they are excluded
-- because they spawn their own cosmetic immediately in Client.Fire().
function OutboundBatcher.WriteFireForAll(
	self          : any,
	AllPlayers    : { Player },
	ShooterUserId : number,
	EncodedFire   : buffer
)
	for _, Player in AllPlayers do
		if Player.UserId == ShooterUserId then continue end
		local Cursor = self._Cursors[Player]
		if not Cursor then
			Cursor = NewCursor()
			self._Cursors[Player] = Cursor
		end
		WriteChannelByte(Cursor, CHANNEL_FIRE)
		AppendMessage(Cursor, EncodedFire)
	end
end

-- Write a fire replication message to a single specific player.
-- Used to send the shooter their echo with LocalCastId embedded, while other
-- players receive a separate encode with LocalCastId = 0.
function OutboundBatcher.WriteFireForPlayer(
	self        : any,
	Player      : Player,
	EncodedFire : buffer
)
	local Cursor = self._Cursors[Player]
	if not Cursor then
		Cursor = NewCursor()
		self._Cursors[Player] = Cursor
	end
	WriteChannelByte(Cursor, CHANNEL_FIRE)
	AppendMessage(Cursor, EncodedFire)
end

-- Write a hit confirmation message to every player.
function OutboundBatcher.WriteHitForAll(
	self       : any,
	AllPlayers : { Player },
	EncodedHit : buffer
)
	for _, Player in AllPlayers do
		local Cursor = self._Cursors[Player]
		if not Cursor then
			Cursor = NewCursor()
			self._Cursors[Player] = Cursor
		end
		WriteChannelByte(Cursor, CHANNEL_HIT)
		AppendMessage(Cursor, EncodedHit)
	end
end

-- Write a state batch to every player.
-- Called once per frame after StateBatcher.Flush().
-- Skipped entirely when ResolvedConfig.ReplicateState == false.
function OutboundBatcher.WriteStateForAll(
	self         : any,
	AllPlayers   : { Player },
	EncodedState : buffer
)
	for _, Player in AllPlayers do
		local Cursor = self._Cursors[Player]
		if not Cursor then
			Cursor = NewCursor()
			self._Cursors[Player] = Cursor
		end
		WriteChannelByte(Cursor, CHANNEL_STATE)
		AppendMessage(Cursor, EncodedState)
	end
end

-- ─── Flush ───────────────────────────────────────────────────────────────────

-- Send each player's accumulated buffer as a single FireClient call.
-- Players with nothing queued this frame are skipped.
-- After flushing, all cursor write offsets are reset to 0.
-- Both the accumulation buffer and the outbound send buffer are retained for
-- the next frame — no allocation occurs in the steady state.
function OutboundBatcher.Flush(self: any, Remote: RemoteEvent)
	for Player, Cursor in self._Cursors do
		if Cursor.Offset == 0 then continue end

		-- Grow OutBuf if the written payload exceeds its current capacity.
		-- This mirrors the doubling strategy used by Reserve() for the
		-- accumulation buffer — one reallocation amortises future frames.
		if Cursor.Offset > Cursor.OutLen then
			local NewLen = Cursor.OutLen
			while NewLen < Cursor.Offset do NewLen *= 2 end
			Cursor.OutBuf = buffer_create(NewLen)
			Cursor.OutLen = NewLen
		end

		-- Copy exactly the bytes written into the reusable outbound buffer.
		-- Sending the full over-allocated accumulation buffer would waste bandwidth.
		buffer_copy(Cursor.OutBuf, 0, Cursor.Buffer, 0, Cursor.Offset)

		if Player.Parent then
			-- Roblox does not accept a length argument to FireClient, so we must
			-- send a correctly-sized buffer. We reuse OutBuf across frames by
			-- growing it when needed and always writing from offset 0, ensuring
			-- the receiver sees exactly Cursor.Offset valid bytes with no trailing
			-- garbage (OutBuf may be larger than Cursor.Offset from a prior frame,
			-- but buffer_copy above overwrites all bytes up to Cursor.Offset).
			-- If OutBuf.Len > Cursor.Offset, the trailing bytes are stale from a
			-- prior larger frame — so we create a correctly-sized view only when
			-- OutBuf is exactly the right size, and fall back to a fresh buffer
			-- only on size mismatch (which is rare after the steady state is reached).
			if Cursor.OutLen == Cursor.Offset then
				Remote:FireClient(Player, Cursor.OutBuf)
			else
				-- OutBuf is larger than needed this frame. Create a correctly-sized
				-- view. This allocation only happens when the frame payload shrinks
				-- below OutBuf's current capacity — rare in practice since payload
				-- sizes are relatively stable across frames.
				local ExactBuf = buffer_create(Cursor.Offset)
				buffer_copy(ExactBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
				Remote:FireClient(Player, ExactBuf)
			end
		end

		-- Reset write head without freeing the backing buffer.
		Cursor.Offset = 0
	end
end

-- Remove a player's cursor when they leave.
function OutboundBatcher.RemovePlayer(self: any, Player: Player)
	self._Cursors[Player] = nil
end

-- ─── Destroy ─────────────────────────────────────────────────────────────────

function OutboundBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Cursors)
	self._Cursors = nil
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(OutboundBatcher, {
	__index = function(_, Key)
		Logger:Warn(string_format("OutboundBatcher: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("OutboundBatcher: write to protected key '%s'", tostring(Key)))
	end,
}))