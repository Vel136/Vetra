--!strict
--!optimize 2
--!native

local Client   = {}
Client.__index = Client

local ClientMetatable = table.freeze({
	__index = Client,
})

local Core           = script.Parent.Core
local Transport      = script.Parent.Transport
local Reconciliation = script.Parent.Reconciliation
local Vetra          = script.Parent.Parent
local Types          = script.Parent.Types
local Dependencies   = Vetra.Dependencies
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config           = require(Core.Config)

local BlinkSchema       = require(Transport.BlinkSchema)
local BehaviorRegistry  = require(Transport.BehaviorRegistry)
local ModifierRegistry  = require(Transport.ModifierRegistry)
local CosmeticTracker   = require(Reconciliation.CosmeticTracker)
local DriftCorrector    = require(Reconciliation.DriftCorrector)
local LatencyBuffer     = require(Reconciliation.LatencyBuffer)

local BulletContext    = require(Vetra.Core.BulletContext)
local Constants        = require(Types.Constants)
local Enums            = require(Types.Enums)

local ModifierTypes    = require(ReplicatedStorage.Shared.Modules.Utilities.Quantix.ModifierTypes)
local VeSignal         = require(Dependencies.Signal)

Client.Enums            = Enums
Client.BehaviorRegistry = BehaviorRegistry
Client.ModifierRegistry = ModifierRegistry

local math_clamp    = math.clamp
local string_format = string.format

local FOLDER_NAME   = Constants.NETWORK_FOLDER_NAME
local REMOTE_NET    = Constants.REMOTE_NET
local CHANNEL_FIRE  = Constants.CHANNEL_FIRE
local CHANNEL_HIT   = Constants.CHANNEL_HIT
local CHANNEL_STATE = Constants.CHANNEL_STATE

local function GetOrCreateRemotes(): any
	local Folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 10)
	if not Folder then
		error("[VetraNet] ReplicatedStorage." .. FOLDER_NAME .. " not found within 10 seconds — ensure the server requires VetraNet before the client.", 2)
	end
	return { Net = Folder:WaitForChild(REMOTE_NET, 5) :: RemoteEvent }
end

function Client.new(
	Solver         : any,
	NetworkConfig_ : any?
)
	local ResolvedConfig = Config.Resolve(NetworkConfig_)
	local Remotes        = GetOrCreateRemotes()

	local OnReplicatedFire = VeSignal.new()
	local OnReplicatedHit  = VeSignal.new()

	local Connections: { RBXScriptConnection } = {}

	local Tracker   = CosmeticTracker.new()
	local Corrector = DriftCorrector.new(ResolvedConfig)

	local LastFrameId = 0

	local REJECTED_TYPES = {
		BehaviorOverride  = true,
		BehaviorDeepMerge = true,
		BehaviorHook      = true,
		BehaviorExclusive = true,
		BehaviorReplace   = true,
	}

	local function EvaluateWithHashes(behavior: any, hashes: { number }): any
		local numericByField: { [string]: { any } } = {}

		for _, hash in hashes do
			local mods = ModifierRegistry.Get(hash)
			if not mods then continue end
			for _, mod in mods do
				if REJECTED_TYPES[mod.Type] or mod.Source ~= "Ballistics" then continue end

				if mod.Stat then
					local list = numericByField[mod.Stat]
					if not list then
						list = {}
						numericByField[mod.Stat] = list
					end
					table.insert(list, mod)
				end
			end
		end

		local final = behavior

		for field, mods in numericByField do
			local base = final[field]
			if base == nil then continue end
			local nr = ModifierTypes.Evaluate(base, mods)
			if final == behavior then final = table.clone(behavior) end
			final[field] = nr.final
		end

		return final
	end

	local function HandleFire(Payload: any)
		local Behavior = BehaviorRegistry.Get(Payload.BehaviorHash)
		if not Behavior then
			warn(string_format("Client: unknown behavior hash %d", Payload.BehaviorHash))
			return
		end

		local Hashes = Payload.ModifierBuffer and ModifierRegistry.Unpack(Payload.ModifierBuffer) or {}
		Behavior = EvaluateWithHashes(Behavior, Hashes)

		local ServerCastId = Payload.CastId
		local LocalCastId  = Payload.LocalCastId or 0

		if LocalCastId > 0 then
			local ExistingCast = Tracker:GetLocal(LocalCastId)
			if ExistingCast then
				Tracker:Unregister(LocalCastId)
				Tracker:Register(ServerCastId, ExistingCast)
			end
			return
		end

		local Delay
		if ResolvedConfig.LatencyBuffer ~= 0 then
			Delay = ResolvedConfig.LatencyBuffer
		else
			Delay = LatencyBuffer.GetDelay()
		end

		local function SpawnCosmetic()
			if not Solver or not Solver.Fire then return end
			local FireContext = BulletContext.new({
				Origin    = Payload.Origin,
				Direction = Payload.Direction,
				Speed     = Payload.Speed,
				SolverData = { ServerCastId = ServerCastId },
			})
			local Context = Solver:Fire(FireContext, Behavior)
			if not Context then
				warn(string_format("Client: solver Fire() returned nil for castId %d", ServerCastId))
				return
			end
			Tracker:Register(ServerCastId, Context)
			OnReplicatedFire:Fire(ServerCastId, Context)
		end

		if Delay > 0.001 then
			task.delay(Delay, SpawnCosmetic)
		else
			SpawnCosmetic()
		end
	end

	local function HandleHit(HitPayload: any)
		local LocalCast = Tracker:GetLocal(HitPayload.CastId)
		if LocalCast and LocalCast.Alive then
			Tracker:Unregister(HitPayload.CastId)
			OnReplicatedHit:Fire(HitPayload.CastId, HitPayload)
		else
			Tracker:Unregister(HitPayload.CastId)
		end
	end

	local function HandleState(Batch: any)
		if Batch.FrameId <= LastFrameId then return end
		LastFrameId = Batch.FrameId

		local DeltaTime = math_clamp(Batch.FrameDelta, 1/120, 1/10)

		for _, Entry in Batch.States do
			local LocalCast = Tracker:GetLocal(Entry.CastId)
			if not LocalCast or not LocalCast.Alive then continue end
			if Corrector:Evaluate(LocalCast, Entry.Position) then
				Corrector:Correct(LocalCast, Entry.Position, Entry.Velocity, DeltaTime)
			end
		end
	end

	Connections[#Connections + 1] = Remotes.Net.OnClientEvent:Connect(function(RawBuf: any)
		if typeof(RawBuf) ~= "buffer" then return end

		local BufLen = buffer.len(RawBuf)
		local Offset = 0

		while Offset < BufLen do
			if Offset + 3 > BufLen then break end

			local Channel = buffer.readu8(RawBuf, Offset)   Offset += 1
			local MsgLen  = buffer.readu16(RawBuf, Offset)  Offset += 2

			if Offset + MsgLen > BufLen then
				warn(string_format("Client: message length %d overflows buffer at offset %d", MsgLen, Offset))
				break
			end

			local MsgBuf = buffer.create(MsgLen)
			buffer.copy(MsgBuf, 0, RawBuf, Offset, MsgLen)
			Offset += MsgLen

			if Channel == CHANNEL_FIRE then
				local Success, Result = pcall(BlinkSchema.DecodeFire, MsgBuf)
				if Success then
					HandleFire(Result)
				else
					warn(string_format("Client: DecodeFire failed: %s", tostring(Result)))
				end
			elseif Channel == CHANNEL_HIT then
				local Success, Result = pcall(BlinkSchema.DecodeHit, MsgBuf)
				if Success then
					HandleHit(Result)
				else
					warn(string_format("Client: DecodeHit failed: %s", tostring(Result)))
				end
			elseif Channel == CHANNEL_STATE then
				local Success, Result = pcall(BlinkSchema.DecodeStateBatch, MsgBuf)
				if Success then
					HandleState(Result)
				else
					warn(string_format("Client: DecodeStateBatch failed: %s", tostring(Result)))
				end
			else
				warn(string_format("Client: unknown channel id %d", Channel))
			end
		end
	end)

	Connections[#Connections + 1] = Solver.Signals.OnTerminated:Connect(function(Context: any)
		local ServerCastId = Context.__solverData and Context.__solverData.ServerCastId
		if ServerCastId then
			Tracker:Unregister(ServerCastId)
		end
	end)

	local self = setmetatable({
		_Solver             = Solver,
		_EvaluateWithHashes = EvaluateWithHashes,
		_ResolvedConfig     = ResolvedConfig,
		_Net                = Remotes.Net,
		_Connections        = Connections,
		_Tracker            = Tracker,
		_Corrector          = Corrector,
		_Destroyed          = false,
		_NextLocalCastId    = 1,
		OnReplicatedFire    = OnReplicatedFire,
		OnReplicatedHit     = OnReplicatedHit,
	}, ClientMetatable)

	return self :: ClientNet
end

function Client:Fire(Context: BulletContext.BulletContext, BehaviorName: string, Modifiers: { string }?) : BulletContext.BulletContext
	if self._Destroyed then
		warn("Client.Fire: called on destroyed handle")
		return
	end

	local BehaviorHash = BehaviorRegistry.GetHash(BehaviorName)
	if BehaviorHash == 0 then
		warn(string_format("Client.Fire: behavior '%s' is not registered", BehaviorName))
		return
	end

	local Hashes = {}
	if Modifiers then
		for _, name in Modifiers do
			local h = ModifierRegistry.GetHash(name)
			if h ~= 0 then table.insert(Hashes, h) end
		end
	end

	local LocalCastId       = self._NextLocalCastId
	self._NextLocalCastId   = LocalCastId + 1

	local Behavior = BehaviorRegistry.Get(BehaviorHash)
	if Behavior and self._Solver and self._Solver.Fire then

		local TimeDelay = self._ResolvedConfig.LatencyBuffer ~= 0 and self._ResolvedConfig.LatencyBuffer or LatencyBuffer.GetDelay()

		local Tracker = self._Tracker

		local FinalBehavior = self._EvaluateWithHashes(Behavior, Hashes)

		local function SpawnLocal()
			if self._Destroyed then return end
			Context.__solverData = { LocalCastId = LocalCastId }
			local LocalCast = self._Solver:Fire(Context, FinalBehavior)

			if LocalCast and Tracker then
				Tracker:Register(LocalCastId, LocalCast)
			end
		end

		if TimeDelay > 0.001 then
			task.delay(TimeDelay, SpawnLocal)
		else
			SpawnLocal()
		end
	end

	return Context :: BulletContext.BulletContext
end

function Client:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	for _, Connection in self._Connections do
		Connection:Disconnect()
	end

	self._Tracker:Destroy()
	self._Corrector:Destroy()
	self.OnReplicatedFire:Destroy()
	self.OnReplicatedHit:Destroy()
	setmetatable(self, nil)
end

export type ClientNet = typeof(setmetatable(
	{} :: {
		_Solver             : any,
		_EvaluateWithHashes : (behavior: any, hashes: { number }) -> any,
		_ResolvedConfig     : any,
		_Net                : RemoteEvent,
		_Connections        : { RBXScriptConnection },
		_Tracker            : any,
		_Corrector          : any,
		_NextLocalCastId    : number,
		_Destroyed          : boolean,
		OnReplicatedFire    : any,
		OnReplicatedHit     : any,
	},
	{__index = Client}
))

return Client
