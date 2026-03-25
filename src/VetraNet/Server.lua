--!strict
--Server.lua
--!native
--!optimize 2

local Identity = "Server"

local Server   = {}
Server.__type  = Identity

local ServerMetatable = table.freeze({
	__index = Server,
})

-- ─── References ──────────────────────────────────────────────────────────────

local VetraNet          = script.Parent
local Core              = VetraNet.Core
local Transport         = VetraNet.Transport
local AuthorityFolder   = VetraNet.Authority
local Reconciliation    = VetraNet.Reconciliation
local Hooks             = VetraNet.Hooks
local Vetra             = VetraNet.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

-- ─── Module References ───────────────────────────────────────────────────────

local AuthorityModule   = require(Core.Authority)
local Config            = require(Core.Config)
local LogService        = require(Core.Logger)
local Session           = require(Core.Session)
local VeSignal          = require(Vetra.Core.VeSignal)
local StateBatcher      = require(Transport.StateBatcher)
local OutboundBatcher   = require(Transport.OutboundBatcher)
local RateLimiter       = require(AuthorityFolder.RateLimiter)
local OwnershipRegistry = require(AuthorityFolder.OwnershipRegistry)
local ServerHooks       = require(Hooks.ServerHooks)
local Constants         = require(VetraNet.Types.Constants)
local Enums             = require(VetraNet.Types.Enums)

AuthorityModule.AssertServer("VetraNet.Server")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Constants ───────────────────────────────────────────────────────────────

local FOLDER_NAME = Constants.NETWORK_FOLDER_NAME
local REMOTE_NET  = Constants.REMOTE_NET

-- ─── Helpers ─────────────────────────────────────────────────────────────────

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

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    Create the server-side VetraNet handle.

    Parameters:
      Solver           — The live Vetra Factory instance (server solver).
      BehaviorRegistry — A shared BehaviorRegistry.new() instance pre-populated
                         with the same behaviors as the client registry.
      NetworkConfig_   — Optional NetworkConfig table (see Types/NetworkTypes.lua).

    Returns a ServerNetwork handle with:
      .OnValidatedHit  — VeSignal fired after a hit passes all authority checks.
      .OnFireRejected  — VeSignal fired when a fire request is rejected server-side.
      :Destroy()       — Cleans up all connections, remotes, and frame loops.
]]
function Server.new(Solver: any, BehaviorRegistry_: any, NetworkConfig_: any?): any
	local Mode           = (NetworkConfig_ and NetworkConfig_.Mode) or Enums.NetworkMode.ClientAuthoritative
	local ResolvedConfig = Config.Resolve(NetworkConfig_)
	local SessionInstance     = Session.new(ResolvedConfig)
	local RateLimiterInstance = RateLimiter.new(ResolvedConfig.TokensPerSecond, ResolvedConfig.BurstLimit)
	local OwnershipInstance   = OwnershipRegistry.new()
	local StateBatcherInstance    = StateBatcher.new()
	local OutboundBatcherInstance = OutboundBatcher.new()
	local Remotes             = GetOrCreateRemotes()

	local OnValidatedHit = VeSignal.new()
	local OnFireRejected = VeSignal.new()

	local Connections = ServerHooks.Bind({
		Solver            = Solver,
		Remotes           = Remotes,
		Session           = SessionInstance,
		RateLimiter       = RateLimiterInstance,
		BehaviorRegistry  = BehaviorRegistry_,
		OwnershipRegistry = OwnershipInstance,
		StateBatcher      = StateBatcherInstance,
		OutboundBatcher   = OutboundBatcherInstance,
		ResolvedConfig    = ResolvedConfig,
		OnValidatedHit    = OnValidatedHit,
		OnFireRejected    = OnFireRejected,
		Mode              = Mode,
	})

	local FrameConnection = RunService.Heartbeat:Connect(function(DeltaTime: number)
		RateLimiterInstance:Refill(DeltaTime)
		StateBatcherInstance:Collect(Solver)

		if ResolvedConfig.ReplicateState and StateBatcherInstance._StateCount > 0 then
			local EncodedState = StateBatcherInstance:Flush(DeltaTime)
			OutboundBatcherInstance:WriteStateForAll(Players:GetPlayers(), EncodedState)
		else
			StateBatcherInstance:Flush(DeltaTime)
		end

		OutboundBatcherInstance:Flush(Remotes.Net)
	end)

	local self = setmetatable({
		OnValidatedHit       = OnValidatedHit,
		OnFireRejected       = OnFireRejected,
		_Connections         = Connections,
		_FrameConnection     = FrameConnection,
		_Session             = SessionInstance,
		_RateLimiter         = RateLimiterInstance,
		_Ownership           = OwnershipInstance,
		_StateBatcher        = StateBatcherInstance,
		_OutboundBatcher     = OutboundBatcherInstance,
		_FireFromServer      = Connections._FireFromServer,
		_Mode                = Mode,
		_Destroyed           = false,
	}, ServerMetatable)

	Logger:Info("VetraNet Server initialised")
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

--[[
    Fire a server-owned bullet and replicate it to all clients.
    Only valid when Mode = ServerAuthority. Errors otherwise.

    Parameters:
      Origin       — World-space fire origin.
      Direction    — Unit direction vector.
      Speed        — Initial bullet speed (studs/s).
      BehaviorHash — u16 key into the shared BehaviorRegistry.
]]
function Server:Fire(Origin: Vector3, Direction: Vector3, Speed: number, BehaviorHash: number)
	if self._Mode ~= Enums.NetworkMode.ServerAuthority and self._Mode ~= Enums.NetworkMode.SharedAuthority then
		error("VetraNet.Server:Fire() is only available in ServerAuthority or Hybrid mode", 2)
	end
	return self._FireFromServer(Origin, Direction, Speed, BehaviorHash)
end

--[[
    Fire a server-owned bullet with additional context for game-code routing.
    Only valid when Mode = ServerAuthority or SharedAuthority.

    Parameters:
      Origin          — World-space fire origin.
      Direction       — Unit direction vector.
      Speed           — Initial bullet speed (studs/s).
      BehaviorHash    — u16 key into the shared BehaviorRegistry.
      UserData        — Attached to BulletContext.UserData (e.g. Player, GunInstance).
      RaycastOverride — Per-fire RaycastParams (e.g. to exclude the firing player's character).
]]
function Server:FireWithContext(
	Origin          : Vector3,
	Direction       : Vector3,
	Speed           : number,
	BehaviorHash    : number,
	UserData        : { [string]: any }?,
	RaycastOverride : RaycastParams?
)
	if self._Mode ~= Enums.NetworkMode.ServerAuthority and self._Mode ~= Enums.NetworkMode.SharedAuthority then
		error("VetraNet.Server:FireWithContext() is only available in ServerAuthority or Hybrid mode", 2)
	end
	return self._FireFromServer(Origin, Direction, Speed, BehaviorHash, UserData, RaycastOverride)
end

function Server:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	self._FrameConnection:Disconnect()

	for _, Connection in self._Connections do
		if typeof(Connection) == "RBXScriptConnection" then
			Connection:Disconnect()
		end
	end

	self._Session:Destroy()
	self._RateLimiter:Destroy()
	self._Ownership:Destroy()
	self._StateBatcher:Destroy()
	self._OutboundBatcher:Destroy()
	self.OnValidatedHit:Destroy()
	self.OnFireRejected:Destroy()
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Server)