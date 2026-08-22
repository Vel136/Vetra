--!strict
--!optimize 2
--!native

local OutboundBatcher = {}
OutboundBatcher.__index = OutboundBatcher

local Core  = script.Parent.Parent.Core
local Types = script.Parent.Parent.Types

local Constants = require(Types.Constants)

local buffer_len      = buffer.len
local buffer_create   = buffer.create
local buffer_writeu8  = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_copy     = buffer.copy
local table_clear     = table.clear

local CHANNEL_FIRE  = Constants.CHANNEL_FIRE
local CHANNEL_HIT   = Constants.CHANNEL_HIT
local CHANNEL_STATE = Constants.CHANNEL_STATE
local INITIAL_CAP   = Constants.OUTBOUND_BUFFER_INITIAL

local function NewCursor(): { Buffer: buffer, Len: number, Offset: number, OutBuf: buffer, OutLen: number }
	local Buffer = buffer_create(INITIAL_CAP)
	return { Buffer = Buffer, Len = INITIAL_CAP, Offset = 0, OutBuf = buffer_create(INITIAL_CAP), OutLen = INITIAL_CAP }
end

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

local function WriteChannelByte(Cursor: any, Channel: number)
	Reserve(Cursor, 1)
	buffer_writeu8(Cursor.Buffer, Cursor.Offset, Channel)
	Cursor.Offset += 1
end

local function AppendMessage(Cursor: any, Message: buffer)
	local MessageLen = buffer_len(Message)
	Reserve(Cursor, 2 + MessageLen)
	buffer_writeu16(Cursor.Buffer, Cursor.Offset, MessageLen)
	Cursor.Offset += 2
	buffer_copy(Cursor.Buffer, Cursor.Offset, Message, 0, MessageLen)
	Cursor.Offset += MessageLen
end

function OutboundBatcher.new(): any
	return setmetatable({
		_Cursors   = {} :: { [Player]: any },
		_Destroyed = false,
	}, OutboundBatcher)
end

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

function OutboundBatcher.Flush(self: any, Remote: RemoteEvent)
	for Player, Cursor in self._Cursors do
		if Cursor.Offset == 0 then continue end

		if Cursor.Offset > Cursor.OutLen then
			local NewLen = Cursor.OutLen
			while NewLen < Cursor.Offset do NewLen *= 2 end
			Cursor.OutBuf = buffer_create(NewLen)
			Cursor.OutLen = NewLen
		end

		buffer_copy(Cursor.OutBuf, 0, Cursor.Buffer, 0, Cursor.Offset)

		if Player.Parent then
			if Cursor.OutLen == Cursor.Offset then
				Remote:FireClient(Player, Cursor.OutBuf)
			else
				local ExactBuf = buffer_create(Cursor.Offset)
				buffer_copy(ExactBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
				Remote:FireClient(Player, ExactBuf)
			end
		end

		Cursor.Offset = 0
	end
end

function OutboundBatcher.FlushPlayer(self: any, Remote: RemoteEvent, Player: Player)
	local Cursor = self._Cursors[Player]
	if not Cursor or Cursor.Offset == 0 then return end

	if Cursor.Offset > Cursor.OutLen then
		local NewLen = Cursor.OutLen
		while NewLen < Cursor.Offset do NewLen *= 2 end
		Cursor.OutBuf = buffer_create(NewLen)
		Cursor.OutLen = NewLen
	end

	buffer_copy(Cursor.OutBuf, 0, Cursor.Buffer, 0, Cursor.Offset)

	if Player.Parent then
		if Cursor.OutLen == Cursor.Offset then
			Remote:FireClient(Player, Cursor.OutBuf)
		else
			local ExactBuf = buffer_create(Cursor.Offset)
			buffer_copy(ExactBuf, 0, Cursor.Buffer, 0, Cursor.Offset)
			Remote:FireClient(Player, ExactBuf)
		end
	end

	Cursor.Offset = 0
end

function OutboundBatcher.RemovePlayer(self: any, Player: Player)
	self._Cursors[Player] = nil
end

function OutboundBatcher.Destroy(self: any)
	if self._Destroyed then return end
	self._Destroyed = true
	table_clear(self._Cursors)
	self._Cursors = nil
	setmetatable(self, nil)
end

return table.freeze(OutboundBatcher)
