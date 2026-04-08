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
local FireChannel       = require(Transport.FireChannel)
local BlinkSchema       = require(Transport.BlinkSchema)
local RateLimiter       = require(AuthorityFolder.RateLimiter)
local OwnershipRegistry = require(AuthorityFolder.OwnershipRegistry)
local FireValidator     = require(AuthorityFolder.FireValidator)
local LateJoinHandler   = require(Reconciliation.LateJoinHandler)
local BulletContext     = require(Vetra.Core.BulletContext)
local Constants         = require(VetraNet.Types.Constants)
local Enums             = require(VetraNet.Types.Enums)

AuthorityModule.AssertServer("VetraNet.Server")

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

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
      .OnValidatedHit     — VeSignal fired after a hit passes all authority checks.
      .OnFireRejected     — VeSignal fired when a fire request is rejected server-side.
      :Fire(Ctx, Hash)    — Fire a server-owned bullet (ServerAuthority / SharedAuthority).
      :SetPlayerFilter(F) — Gate which players receive replication.
      :Destroy()          — Cleans up all connections, remotes, and frame loops.
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

	local ServerCanFire = (Mode == Enums.NetworkMode.ServerAuthority or Mode == Enums.NetworkMode.SharedAuthority)
	local ClientCanFire = (Mode == Enums.NetworkMode.ClientAuthoritative or Mode == Enums.NetworkMode.SharedAuthority)

	local Connections: { RBXScriptConnection } = {}

	-- ── self_ ───────────────────────────────────────────────────────────────────
	-- Built before connections so closures below can read _PlayerFilter at call
	-- time. _FireFromServer, _Connections, and _FrameConnection are not ready yet
	-- and are assigned after the wiring is complete.
	local self_ = setmetatable({
		OnValidatedHit       = OnValidatedHit,
		OnFireRejected       = OnFireRejected,
		_Session             = SessionInstance,
		_RateLimiter         = RateLimiterInstance,
		_Ownership           = OwnershipInstance,
		_StateBatcher        = StateBatcherInstance,
		_OutboundBatcher     = OutboundBatcherInstance,
		_FireFromServer      = nil,
		_Connections         = nil,
		_FrameConnection     = nil,
		_Mode                = Mode,
		_PlayerFilter        = nil,
		_Destroyed           = false,
	}, ServerMetatable)

	-- Returns the current player list with the optional predicate applied.
	-- No allocation on the fast path (filter is nil).
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

	-- Per-instance cast ID counter. Starts at 1; 0 is reserved as "invalid".
	local NextCastIdCounter = 1
	local function NextCastId(): number
		local CastId = NextCastIdCounter
		NextCastIdCounter += 1
		return CastId
	end

	-- ── ContextToCastId ────────────────────────────────────────────────────────
	-- Maps BulletContext.Id → ServerCastId for the lifetime of each network cast.
	-- Populated in the FireChannel handler right after Solver:Fire succeeds.
	--
	-- Why this exists instead of reading Context.__solverData in signal handlers:
	--
	--   Deferred-signal race: VeSignal.FireSafe defers to task.defer when
	--   re-entrant (Firing > 0). If OnTerminated fires while another signal is
	--   already dispatching (e.g. a bullet terminates inside OnHit), the handler
	--   runs one frame later — after Vetra's Terminate() has already called
	--   BulletContext:Terminate(), which nils __solverData. Reading __solverData
	--   at that point always returns nil → Session:RemoveCast is never called →
	--   _CastCount leaks → player permanently rate-limited.
	--
	--   Direct-termination path: Cast:Terminate() calls Solver._Terminate
	--   directly, bypassing FireOnTerminated entirely. OnTerminated never fires,
	--   so __solverData is irrelevant on that path regardless.
	--   See the _Terminate wrapper below.
	--
	-- Keyed by BulletContext.Id (number) rather than by table identity.
	-- VeSignal.FireSafe deep-copies table arguments (SafeCopyArg), so the
	-- Context received by OnHit/OnTerminated handlers is a COPY of the
	-- original BulletContext — table identity lookup would always miss.
	-- BulletContext.Id is a monotonic number that survives copying.
	local ContextToCastId: { [number]: number } = {}

	-- Internal cleanup: removes the cast from all authority tables.
	-- Called from both OnTerminated (normal path) and the _Terminate wrapper
	-- (direct Cast:Terminate() path). Idempotent — safe to call twice.
	local function CleanupCast(CastId: number)
		local Owner = OwnershipInstance:GetOwner(CastId)
		if Owner then
			SessionInstance:RemoveCast(Owner, CastId)
		end
		OwnershipInstance:Unregister(CastId)
	end

	-- ── _Terminate wrapper ─────────────────────────────────────────────────────
	-- Intercepts every Solver._Terminate call so we can run CleanupCast even
	-- when the caller bypassed the normal simulation path (e.g. Cast:Terminate(),
	-- PlayerRemoving force-terminates, or any game code that calls :Terminate()
	-- on a cast directly).
	--
	-- Execution order on the normal path (SimulateCast):
	--   FireOnTerminated → OnTerminated handler runs → CleanupCast → removes from
	--   ContextToCastId → _Terminate called → wrapper sees nil → skips duplicate.
	--
	-- Execution order on the direct path (Cast:Terminate()):
	--   _Terminate called directly → wrapper sees entry still present → runs
	--   CleanupCast → removes from ContextToCastId → calls _baseTerm.
	--
	-- In both cases exactly one CleanupCast runs per cast.
	local _baseTerm = Solver._Terminate
	Solver._Terminate = function(solver: any, cast: any, reason: string?)
		-- Read _CastToBulletContext BEFORE _baseTerm destroys the mapping.
		local ContextMap = solver._CastToBulletContext
		local BulletCtx  = ContextMap and ContextMap[cast]
		if BulletCtx then
			local CtxId = BulletCtx.Id
			local CastId = ContextToCastId[CtxId]
			if CastId then
				-- OnTerminated did not run before us (direct termination path).
				-- Run cleanup now and clear the entry so OnTerminated, if it does
				-- fire later via a deferred signal, finds nothing and returns early.
				CleanupCast(CastId)
				ContextToCastId[CtxId] = nil
			end
		end
		_baseTerm(solver, cast, reason)
	end

	-- ── FireFromServer: server-initiated fire (ServerAuthority mode) ────────
	-- Accepts the caller's BulletContext directly — stamps __solverData onto it
	-- and forwards it to the solver unchanged. UserData and RaycastParams are
	-- read from the context, so there is nothing to reconstruct here.
	-- Returns the server CastId on success, or 0 on failure.
	local function FireFromServer(Context: BulletContext, BehaviorHash: number): number
		if not ServerCanFire then
			Logger:Error("Server: FireFromServer called but Mode is ClientAuthoritative")
			return 0
		end

		local Behavior = BehaviorRegistry_:Get(BehaviorHash)
		if not Behavior then
			Logger:Warn(string_format(
				"Server: FireFromServer — unknown behavior hash %d",
				BehaviorHash
			))
			return 0
		end

		local CastId = NextCastId()

		-- Stamp networking metadata. OwnerId = 0 means server-authority bullet.
		Context.__solverData = { OwnerId = 0, ServerCastId = CastId }

		local Result = Solver:Fire(Context, Behavior)

		if not Result then
			Logger:Warn(string_format(
				"Server: FireFromServer — Solver:Fire returned nil for castId %d",
				CastId
			))
			return 0
		end

		ContextToCastId[Context.Id] = CastId

		-- Replicate to all clients. No shooter echo (server has no local cosmetic).
		local AllPlayers = GetFiltered()
		local Timestamp  = workspace:GetServerTimeNow()

		local EncodedFire = BlinkSchema.EncodeFire(
			Context.Origin,
			Context.Direction,
			Context.Speed,
			BehaviorHash,
			CastId,
			Timestamp,
			0 -- LocalCastId = 0 for all clients (no cosmetic migration needed)
		)
		OutboundBatcherInstance:WriteFireForAll(AllPlayers, 0, EncodedFire)

		return CastId
	end

	-- ── PlayerAdded: register session + late-join sync ──────────────────────
	Connections[#Connections + 1] = Players.PlayerAdded:Connect(function(Player: Player)
		SessionInstance:Register(Player)
		-- Defer by one frame so the solver's _ActiveCasts are stable before
		-- we snapshot them. Spawning the sync on the same tick as PlayerAdded
		-- would capture zero bullets because the frame loop hasn't run yet.
		task.defer(function()
			LateJoinHandler.SyncPlayer(
				Player,
				Solver,
				Remotes.Net,
				StateBatcherInstance:GetNextFrameId()
			)
		end)
	end)

	-- Register any players already in the server when VetraNet initialises.
	-- Without this, players present before require() have no session entry and
	-- all fire requests from them are silently rejected by Session:CanFire.
	for _, Player in Players:GetPlayers() do
		SessionInstance:Register(Player)
	end

	-- ── PlayerRemoving: cleanup ─────────────────────────────────────────────
	Connections[#Connections + 1] = Players.PlayerRemoving:Connect(function(Player: Player)
		-- Terminate all bullets this player owns to prevent orphaned casts
		-- from continuing to be simulated with no owner to clean them up.
		-- Vetra exposes no GetCastById API — we build a fast lookup set from
		-- the ownership registry and scan _ActiveCasts once to find matches.
		local OwnedIds = {}
		for _, CastId in OwnershipInstance:GetCastsForPlayer(Player) do
			OwnedIds[CastId] = true
		end
		local ActiveCasts = Solver._ActiveCasts
		if ActiveCasts then
			for _, Cast in ActiveCasts do
				if Cast and Cast.Alive then
					-- __solverData lives on BulletContext, not on the raw Cast.
					local BulletCtx    = Solver._CastToBulletContext[Cast]
					local ServerCastId = BulletCtx and BulletCtx.__solverData and BulletCtx.__solverData.ServerCastId
					if ServerCastId and OwnedIds[ServerCastId] then
						Cast:Terminate()
					end
				end
			end
		end
		SessionInstance:Unregister(Player)
		RateLimiterInstance:Reset(Player)
		OutboundBatcherInstance:RemovePlayer(Player)
	end)

	-- ── FireChannel: incoming fire request ──────────────────────────────────
	-- Skipped entirely in ServerAuthority mode — clients are not permitted to
	-- initiate fire. Any client fire request is silently ignored.
	if not ClientCanFire then
		-- Bind a no-op receiver so the FireChannel listener is still registered
		-- (avoids "no handler" warnings from FireChannel) but drops all payloads.
		FireChannel.OnFireReceived(Remotes.Net, function(_Player: Player, _Payload: any)
			-- Silent drop — client fire not permitted in ServerAuthority mode.
		end)
	end

	if ClientCanFire then
		FireChannel.OnFireReceived(Remotes.Net, function(Player: Player, Payload: any)
			-- Validate the payload through the full authority chain.
			local Result = FireValidator.Validate(
				Player, Payload, SessionInstance, RateLimiterInstance, BehaviorRegistry_, ResolvedConfig
			)

			if not Result.Passed then
				OnFireRejected:Fire(Player, Result.Reason)
				-- No acknowledgement is sent to the client — see FireValidator.lua
				-- for the security rationale behind silent rejection.
				return
			end

			-- Resolve the behavior from the registry.
			local Behavior = BehaviorRegistry_:Get(Payload.BehaviorHash)
			if not Behavior then
				-- Should be caught by validator check 5, but guard defensively.
				OnFireRejected:Fire(Player, Enums.ValidationReason.UnknownBehavior)
				return
			end

			-- Assign a server-authoritative cast ID.
			local CastId = NextCastId()

			-- Fire the authoritative server bullet.
			local FireContext = BulletContext.new({
				Origin    = Payload.Origin,
				Direction = Payload.Direction,
				Speed     = Payload.Speed,
				SolverData = { OwnerId = Player.UserId, ServerCastId = CastId },
			})
			local Context = Solver:Fire(FireContext, Behavior)

			if not Context then
				Logger:Warn(string_format(
					"Server: Solver:Fire returned nil for player '%s' (UserId: %d)",
					Player.Name, Player.UserId
				))
				return
			end

			-- Register cast in authority tables BEFORE replicate — a race between
			-- replication and termination would leave an orphaned entry if we
			-- registered after sending.
			SessionInstance:AddCast(Player, CastId)
			OwnershipInstance:Register(CastId, Player)

			-- Register in ContextToCastId so OnHit and OnTerminated can resolve the
			-- ServerCastId without touching __solverData (which may be nil'd before
			-- deferred signal handlers run — see the table comment above).
			ContextToCastId[FireContext.Id] = CastId

			-- Replicate the validated fire event. Two encodes are needed:
			--
			--   1. Shooter echo — carries LocalCastId (Payload.CastId) so the client
			--      can migrate the shooter's CosmeticTracker entry from LocalCastId
			--      → ServerCastId. Without this, hit confirmations and state batches
			--      (which carry ServerCastId) can never find the shooter's own cosmetic.
			--
			--   2. All-others broadcast — LocalCastId = 0. Other clients have no local
			--      cosmetic to migrate; they spawn a fresh cosmetic on receipt.
			--
			-- Both are queued via OutboundBatcher and flushed at the next PreSimulation.
			local AllPlayers  = GetFiltered()
			local LocalCastId = Payload.CastId  -- client's local cosmetic ID

			local EncodedFireEcho = BlinkSchema.EncodeFire(
				Payload.Origin,
				Payload.Direction,
				Payload.Speed,
				Payload.BehaviorHash,
				CastId,
				Payload.Timestamp,
				LocalCastId
			)
			OutboundBatcherInstance:WriteFireForPlayer(Player, EncodedFireEcho)

			local EncodedFireBroadcast = BlinkSchema.EncodeFire(
				Payload.Origin,
				Payload.Direction,
				Payload.Speed,
				Payload.BehaviorHash,
				CastId,
				Payload.Timestamp,
				0
			)
			OutboundBatcherInstance:WriteFireForAll(AllPlayers, Player.UserId, EncodedFireBroadcast)
		end)
	end

	-- ── Solver.OnHit: validated hit → broadcast ─────────────────────────────
	Connections[#Connections + 1] = Solver.Signals.OnHit:Connect(function(Context: any, Result: RaycastResult?, Velocity: Vector3, ImpactForce: Vector3)
		local CastId = ContextToCastId[Context.Id]
		if not CastId then return end

		local Owner = OwnershipInstance:GetOwner(CastId)
		if not Owner and not ServerCanFire then
			-- Hit fired by an unregistered cast (e.g. server-spawned non-network bullet).
			-- In ServerAuthority mode we allow nil Owner — the server fired the bullet.
			return
		end

		local HitPosition = Result and Result.Position or Context.Position
		local HitNormal   = Result and Result.Normal   or Vector3.yAxis
		local Timestamp   = workspace:GetServerTimeNow()

		-- Signal game code (damage, effects, etc.).
		-- Owner is nil for server-authority bullets — game code should handle that.
		OnValidatedHit:Fire(Owner, Context, Result, Velocity, ImpactForce)

		-- Queue hit for all clients via OutboundBatcher — flushed at frame end.
		local AllPlayers = GetFiltered()
		local EncodedHit = BlinkSchema.EncodeHit(
			CastId, HitPosition, HitNormal, Velocity, Timestamp
		)
		OutboundBatcherInstance:WriteHitForAll(AllPlayers, EncodedHit)
	end)

	-- ── Solver.OnTerminated: release cast ───────────────────────────────────
	Connections[#Connections + 1] = Solver.Signals.OnTerminated:Connect(function(Context: any)
		local CastId = ContextToCastId[Context.Id]
		if not CastId then return end -- already cleaned up by _Terminate wrapper
		ContextToCastId[Context.Id] = nil

		CleanupCast(CastId)
	end)

	local FrameConnection = RunService.PreSimulation:Connect(function(DeltaTime: number)
		RateLimiterInstance:Refill(DeltaTime)
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

	Logger:Info("VetraNet Server initialised")
	return self_
end

-- ─── API ─────────────────────────────────────────────────────────────────────

--[[
    Fire a server-owned bullet and replicate it to all clients.
    Only valid when Mode = ServerAuthority or SharedAuthority.

    Parameters:
      Context      — BulletContext created by the caller. Origin, Direction, Speed,
                     UserData, and RaycastParams are all read from it. VetraNet stamps
                     its internal __solverData onto the context before firing.
      BehaviorHash — u16 key into the shared BehaviorRegistry.

    Returns the server-authoritative CastId on success, or 0 on failure.
]]
function Server:Fire(Context: BulletContext, BehaviorHash: number): number
	if self._Mode ~= Enums.NetworkMode.ServerAuthority and self._Mode ~= Enums.NetworkMode.SharedAuthority then
		error("VetraNet.Server:Fire() is only available in ServerAuthority or SharedAuthority mode", 2)
	end
	return self._FireFromServer(Context, BehaviorHash)
end

--[[
    Set a predicate that gates which players receive replicated fire, hit, and
    state messages. Called once per broadcast with each candidate Player; return
    true to include them, false to exclude.

    Pass nil to clear the filter and revert to all-player broadcast (default).

    Notes:
      • The shooter's own fire echo (WriteFireForPlayer) is never filtered —
        the shooter always receives confirmation of their own cast.
      • The filter is evaluated at broadcast time, so changes take effect on
        the next event without needing to reconnect anything.
]]
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
