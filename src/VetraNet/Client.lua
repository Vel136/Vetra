--!strict
--Client.lua
--!native
--!optimize 2

local Identity = "Client"

local Client   = {}
Client.__type  = Identity

local ClientMetatable = table.freeze({
	__index = Client,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Core           = script.Parent.Core
local Transport      = script.Parent.Transport
local Reconciliation = script.Parent.Reconciliation
local Hooks          = script.Parent.Hooks
local Vetra          = script.Parent.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── Module References ───────────────────────────────────────────────────────

local AuthorityModule  = require(Core.Authority)
local Config           = require(Core.Config)
local LogService       = require(Core.Logger)
local FireChannel      = require(Transport.FireChannel)
local LatencyBuffer    = require(Reconciliation.LatencyBuffer)
local ClientHooks      = require(Hooks.ClientHooks)
local BulletContext    = require(Vetra.Core.BulletContext)
local Constants        = require(script.Parent.Types.Constants)

AuthorityModule.AssertClient("VetraNet.Client")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Constants ───────────────────────────────────────────────────────────────

local FOLDER_NAME = Constants.NETWORK_FOLDER_NAME
local REMOTE_NET  = Constants.REMOTE_NET

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function GetOrCreateRemotes(): any
	local Folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 10)
	if not Folder then
		error("[VetraNet] ReplicatedStorage." .. FOLDER_NAME .. " not found within 10 seconds — ensure the server requires VetraNet before the client.", 2)
	end
	return { Net = Folder:WaitForChild(REMOTE_NET, 5) :: RemoteEvent }
end

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    Create the client-side VetraNet handle.

    Parameters:
      Solver           — The client-side Vetra Factory instance.
      BehaviorRegistry — A shared BehaviorRegistry.new() instance pre-populated
                         with the same behaviors in the same order as the server.
      NetworkConfig_   — Optional NetworkConfig table.
      OnCosmeticFire   — Optional VeSignal fired after a cosmetic bullet spawns.
      OnCosmeticHit    — Optional VeSignal fired after a cosmetic bullet terminates.

    Returns a ClientNetwork handle with:
      :Fire(origin, direction, speed, behaviorName) — Send a fire request.
      :Destroy()                                    — Clean up all connections.
]]
function Client.new(
	Solver            : any,
	BehaviorRegistry_ : any,
	NetworkConfig_    : any?,
	OnCosmeticFire    : any?,
	OnCosmeticHit     : any?
): any
	local ResolvedConfig = Config.Resolve(NetworkConfig_)
	local Remotes        = GetOrCreateRemotes()

	local Connections = ClientHooks.Bind(
		Solver,
		BehaviorRegistry_,
		Remotes.Net,
		ResolvedConfig,
		OnCosmeticFire,
		OnCosmeticHit
	)

	local self = setmetatable({
		_Solver           = Solver,
		_BehaviorRegistry = BehaviorRegistry_,
		_ResolvedConfig   = ResolvedConfig,
		_Net              = Remotes.Net,
		_Connections      = Connections,
		_Destroyed        = false,
		-- Monotonic local cast ID counter. Used to tag the shooter's own
		-- cosmetic bullet so it can be registered in CosmeticTracker and
		-- correctly unregistered when the server hit confirmation arrives.
		-- Starts at 1; 0 is reserved as "invalid" (matches UNKNOWN_BEHAVIOR_HASH
		-- convention). This counter is LOCAL ONLY — the server generates its own
		-- authoritative ServerCastId. We send this value in the fire payload so
		-- the server can echo it back in the fire replication, letting the client
		-- correlate its own cosmetic with the server-confirmed bullet.
		_NextLocalCastId  = 1,
	}, ClientMetatable)

	Logger:Info("VetraNet Client initialised")
	return self
end

-- ─── API ─────────────────────────────────────────────────────────────────────

--[[
    Serialize and send a fire request to the server.

    Parameters:
      Origin        — World-space fire origin (Vector3).
      Direction     — Unit direction vector (Vector3).
      Speed         — Initial bullet speed in studs/second (number).
      BehaviorName  — The registered behavior name string.
]]
function Client:Fire(
	Origin       : Vector3,
	Direction    : Vector3,
	Speed        : number,
	BehaviorName : string
)
	if self._Destroyed then
		Logger:Warn("Client.Fire: called on destroyed handle — ignoring")
		return
	end

	local BehaviorHash = self._BehaviorRegistry:GetHash(BehaviorName)
	if BehaviorHash == 0 then
		Logger:Warn(string_format(
			"Client.Fire: behavior '%s' is not registered — request not sent",
			BehaviorName
			))
		return
	end

	-- Assign a local cast ID for this fire event. This ID is sent in the
	-- payload and echoed back by the server in the fire replication so the
	-- client can register the shooter's own cosmetic in CosmeticTracker.
	-- Without this, the shooter's local bullet is permanently unlinked from
	-- the server bullet: hit confirmations arrive with a ServerCastId the
	-- tracker doesn't know about, so OnCosmeticHit never fires for the shooter,
	-- and drift correction never applies to their own bullets.
	local LocalCastId       = self._NextLocalCastId
	self._NextLocalCastId   = LocalCastId + 1

	local Behavior = self._BehaviorRegistry:Get(BehaviorHash)
	if Behavior and self._Solver and self._Solver.Fire then
		
		local TimeDelay = self._ResolvedConfig.LatencyBuffer ~= 0 and self._ResolvedConfig.LatencyBuffer or LatencyBuffer.GetDelay()

		local Tracker = self._Connections._Tracker

		local function SpawnLocal()
			if self._Destroyed then return end
			local FireContext = BulletContext.new({
				Origin     = Origin,
				Direction  = Direction,
				Speed      = Speed,
				-- Embed LocalCastId so ServerHooks can echo it back in the
				-- replicated fire event. The server will stamp ServerCastId
				-- into the replication payload; the client decoder in ClientHooks
				-- uses that to register this cosmetic under the correct key.
				SolverData = { IsLocalCosmetic = true, LocalCastId = LocalCastId },
			})
			local LocalCast = self._Solver:Fire(FireContext, Behavior)
			
			-- Register immediately so the tracker can match the server's echo.
			-- The server echoes ServerCastId (not LocalCastId) in the replication,
			-- so we register under LocalCastId here and ClientHooks will re-register
			-- under ServerCastId when the echo arrives.
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

	local Timestamp = workspace:GetServerTimeNow()
	FireChannel.SendFire(
		self._Net,
		Origin,
		Direction,
		Speed,
		BehaviorHash,
		LocalCastId,
		Timestamp
	)
end

function Client:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	for _, Connection in self._Connections do
		if typeof(Connection) == "RBXScriptConnection" then
			Connection:Disconnect()
		end
	end

	if self._Connections._Tracker then
		self._Connections._Tracker:Destroy()
	end
	if self._Connections._Corrector then
		self._Connections._Corrector:Destroy()
	end
	setmetatable(self, nil)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(Client)