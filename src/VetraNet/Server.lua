--!strict
--!optimize 2
--!native

local Server   = {}
Server.__index = Server

local ServerMetatable = table.freeze({
	__index = Server,
})

local VetraNet          = script.Parent
local Core              = VetraNet.Core
local Transport         = VetraNet.Transport
local AuthorityFolder   = VetraNet.Authority
local Reconciliation    = VetraNet.Reconciliation
local Vetra             = VetraNet.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Config            = require(Core.Config)
local Session           = require(Core.Session)

local StateBatcher      = require(Transport.StateBatcher)
local OutboundBatcher   = require(Transport.OutboundBatcher)
local BlinkSchema       = require(Transport.BlinkSchema)
local BehaviorRegistry  = require(Transport.BehaviorRegistry)
local ModifierRegistry  = require(Transport.ModifierRegistry)

local OwnershipRegistry = require(AuthorityFolder.OwnershipRegistry)
local LateJoinHandler   = require(Reconciliation.LateJoinHandler)

local ModifierTypes     = require(game.ReplicatedStorage.Shared.Modules.Utilities.Quantix.ModifierTypes)

local Constants         = require(VetraNet.Types.Constants)

Server.BehaviorRegistry = BehaviorRegistry
Server.ModifierRegistry  = ModifierRegistry

local string_format = string.format

local function StripVisuals(behavior: any): any
	if behavior.CosmeticBulletTemplate == nil
		and behavior.CosmeticBulletContainer == nil
		and behavior.CosmeticBulletProvider == nil
		and behavior.AutoDeleteCosmeticBullet == nil
	then
		return behavior
	end
	local b = table.clone(behavior)
	b.CosmeticBulletTemplate   = nil
	b.CosmeticBulletContainer  = nil
	b.CosmeticBulletProvider   = nil
	b.AutoDeleteCosmeticBullet = nil
	return b
end

local FOLDER_NAME = Constants.NETWORK_FOLDER_NAME
local REMOTE_NET  = Constants.REMOTE_NET

local function GetOrCreateRemotes(): any
	local Folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) :: any
	if not Folder then
		Folder = Instance.new("Folder")
		Folder.Name   = FOLDER_NAME
		Folder.Parent = ReplicatedStorage
	end

	local function GetOrCreate(Name: string): RemoteEvent
		local Remote = Folder:FindFirstChild(Name) :: RemoteEvent?
		if not Remote then
			Remote = Instance.new("RemoteEvent")
			Remote.Name   = Name
			Remote.Parent = Folder
		end
		return Remote
	end

	return { Net = GetOrCreate(REMOTE_NET) }
end

function Server.new(Solver: any, NetworkConfig_: any?)
	local ResolvedConfig          = Config.Resolve(NetworkConfig_)
	local SessionInstance         = Session.new(ResolvedConfig)
	local OwnershipInstance       = OwnershipRegistry.new()
	local StateBatcherInstance    = StateBatcher.new()
	local OutboundBatcherInstance = OutboundBatcher.new()
	local Remotes                 = GetOrCreateRemotes()

	local Connections: { RBXScriptConnection } = {}

	local self_ = setmetatable({
		_Session             = SessionInstance,
		_Ownership           = OwnershipInstance,
		_StateBatcher        = StateBatcherInstance,
		_OutboundBatcher     = OutboundBatcherInstance,
		_FireFromServer      = nil,
		_Connections         = nil,
		_FrameConnection     = nil,
		_PlayerFilter        = nil,
		_Destroyed           = false,
	}, ServerMetatable)

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

	local function GetFiltered(): { Player }
		local All = Players:GetPlayers()
		local F = self_._PlayerFilter

		if not F then return All end
		local Out = {}
		for _, P in All do
			if F(P) then Out[#Out + 1] = P end
		end
		return Out
	end

	local NextCastIdCounter = 1
	local function NextCastId(): number
		local CastId = NextCastIdCounter
		NextCastIdCounter += 1
		return CastId
	end

	local ContextToCastId: { [number]: number } = {}

	local function CleanupCast(CastId: number)
		local Owner = OwnershipInstance:GetOwner(CastId)
		if Owner then
			SessionInstance:RemoveCast(Owner, CastId)
		end
		OwnershipInstance:Unregister(CastId)
	end

	local _baseTerm = Solver._Terminate
	Solver._Terminate = function(solver: any, cast: any, reason: string?)
		local ContextMap = solver._CastToBulletContext
		local BulletCtx  = ContextMap and ContextMap[cast]
		if BulletCtx then
			local CtxId = BulletCtx.Id
			local CastId = ContextToCastId[CtxId]
			if CastId then
				CleanupCast(CastId)
				ContextToCastId[CtxId] = nil
			end
		end
		_baseTerm(solver, cast, reason)
	end

	local function FireFromServer(Context: BulletContext, BehaviorHash: number, ModifierNames: { string }?): number
		local hashes: { number } = {}
		if ModifierNames then
			for _, name in ModifierNames do
				local h = ModifierRegistry.GetHash(name)
				if h ~= 0 then table.insert(hashes, h) end
			end
		end
		local ResolvedBuffer = ModifierRegistry.Pack(hashes)

		local Behavior = BehaviorRegistry.Get(BehaviorHash)
		if not Behavior then
			warn(string_format("Server: FireFromServer — unknown behavior hash %d", BehaviorHash))
			return 0
		end

		local FinalBehavior = EvaluateWithHashes(Behavior, hashes)
		FinalBehavior = StripVisuals(FinalBehavior)

		local CastId = NextCastId()
		Context.__solverData = { ServerCastId = CastId }

		local Result = Solver:Fire(Context, FinalBehavior)

		if not Result then
			warn(string_format("Server: FireFromServer — Solver:Fire returned nil for castId %d", CastId))
			return 0
		end

		ContextToCastId[Context.Id] = CastId

		local AllPlayers = GetFiltered()

		local EncodedFire = BlinkSchema.EncodeFire(
			Context.Origin,
			Context.Direction,
			Context.Speed,
			BehaviorHash,
			ResolvedBuffer,
			CastId % 65536,
			0
		)

		OutboundBatcherInstance:WriteFireForAll(AllPlayers, 0, EncodedFire)

		return CastId
	end

	Connections[#Connections + 1] = Players.PlayerAdded:Connect(function(Player: Player)
		SessionInstance:Register(Player)
		task.defer(function()
			LateJoinHandler.SyncPlayer(
				Player,
				Solver,
				OutboundBatcherInstance,
				Remotes.Net,
				StateBatcherInstance:GetNextFrameId()
			)
		end)
	end)

	for _, Player in Players:GetPlayers() do
		SessionInstance:Register(Player)
	end

	Connections[#Connections + 1] = Players.PlayerRemoving:Connect(function(Player: Player)
		local OwnedIds = {}
		for _, CastId in OwnershipInstance:GetCastsForPlayer(Player) do
			OwnedIds[CastId] = true
		end
		local ActiveCasts = Solver._ActiveCasts
		if ActiveCasts then
			for _, Cast in ActiveCasts do
				if Cast and Cast.Alive then
					local BulletCtx    = Solver._CastToBulletContext[Cast]
					local ServerCastId = BulletCtx and BulletCtx.__solverData and BulletCtx.__solverData.ServerCastId
					if ServerCastId and OwnedIds[ServerCastId] then
						Cast:Terminate()
					end
				end
			end
		end
		SessionInstance:Unregister(Player)
		OutboundBatcherInstance:RemovePlayer(Player)
	end)

	Connections[#Connections + 1] = Solver.Signals.OnHit:Connect(function(Context: any, Result: RaycastResult?, Velocity: Vector3, ImpactForce: Vector3)
		local CastId = ContextToCastId[Context.Id]
		if not CastId then return end

		local ContextPosition = Context.Position
		local HitPosition = (Result and Result.Position)
			or (typeof(ContextPosition) == "Vector3" and ContextPosition)
			or Context.Origin
		local HitNormal   = Result and Result.Normal or Vector3.yAxis

		local AllPlayers = GetFiltered()
		local EncodedHit = BlinkSchema.EncodeHit(
			CastId % 65536, HitPosition, HitNormal, Velocity
		)
		OutboundBatcherInstance:WriteHitForAll(AllPlayers, EncodedHit)
	end)

	Connections[#Connections + 1] = Solver.Signals.OnTerminated:Connect(function(Context: any)
		local CastId = ContextToCastId[Context.Id]
		if not CastId then return end
		ContextToCastId[Context.Id] = nil

		CleanupCast(CastId)
	end)

	local FrameConnection = RunService.Heartbeat:Connect(function(DeltaTime: number)
		StateBatcherInstance:Collect(Solver)

		if ResolvedConfig.ReplicateState and StateBatcherInstance._StateCount > 0 then
			local EncodedState = StateBatcherInstance:Flush(DeltaTime)
			OutboundBatcherInstance:WriteStateForAll(GetFiltered(), EncodedState)
		else
			StateBatcherInstance:Flush(DeltaTime)
		end

		OutboundBatcherInstance:Flush(Remotes.Net)
	end)

	self_._FireFromServer  = FireFromServer
	self_._Connections    = Connections
	self_._FrameConnection = FrameConnection

	return self_
end

function Server:Fire(Context: BulletContext, BehaviorHash: number, ModifierNames: { string }?): number
	return self._FireFromServer(Context, BehaviorHash, ModifierNames)
end

function Server:SetPlayerFilter(Fn: ((Player: Player) -> boolean)?)
	self._PlayerFilter = Fn
end

function Server:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	self._FrameConnection:Disconnect()

	for _, Connection in self._Connections do
		Connection:Disconnect()
	end

	self._Session:Destroy()
	self._Ownership:Destroy()
	self._StateBatcher:Destroy()
	self._OutboundBatcher:Destroy()
	setmetatable(self, nil)
end

export type ServerNet = typeof(setmetatable(
	{} :: {
		_Session          : any,
		_Ownership        : any,
		_StateBatcher     : any,
		_OutboundBatcher  : any,
		_FireFromServer   : any,
		_Connections      : { RBXScriptConnection },
		_FrameConnection  : RBXScriptConnection?,
		_PlayerFilter     : ((Player: Player) -> boolean)?,
		_Destroyed        : boolean,
	},
	{__index = Server}
))

return table.freeze(Server)
