--!strict
--ServerHooks.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Hooks/ServerHooks.lua
    Wires every Vetra server signal to the VetraNet transport and authority
    pipeline.

    ServerHooks is the integration point between Vetra and VetraNet on the
    server. It never implements business logic — it routes events. Game code
    that needs to act on hits, piercings, or bounces should use the signals
    on the VetraNet handle (OnValidatedHit, OnFireRejected) rather than
    attaching to Vetra directly, so VetraNet's authority layer is always
    consulted before game effects run.

    Connections managed here:
      • FireChannel.OnFireReceived  → FireValidator → Session.AddCast → Solver.Fire
      • Solver.OnHit                → OwnershipRegistry check → OutboundBatcher.WriteHitForAll
      • Solver.OnTerminated         → Session.RemoveCast → OwnershipRegistry.Unregister
      • Players.PlayerRemoving      → Session.Unregister → RateLimiter.Reset
      • Players.PlayerAdded         → LateJoinHandler.SyncPlayer

    SERVER-ONLY. Errors at require() time if loaded on the client.
]]

local Identity    = "ServerHooks"

local ServerHooks = {}
ServerHooks.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local VetraNet = script.Parent.Parent
local Vetra    = VetraNet.Parent

local Players = game:GetService("Players")

-- ─── Module References ───────────────────────────────────────────────────────

local Authority       = require(VetraNet.Core.Authority)

Authority.AssertServer("ServerHooks")

local LogService      = require(VetraNet.Core.Logger)
local FireChannel     = require(VetraNet.Transport.FireChannel)
local FireValidator   = require(VetraNet.Authority.FireValidator)
local LateJoinHandler = require(VetraNet.Reconciliation.LateJoinHandler)
local BlinkSchema     = require(VetraNet.Transport.BlinkSchema)
local BulletContext   = require(Vetra.Core.BulletContext)
local NetworkTypes    = require(VetraNet.Types.NetworkTypes)
local Enums           = require(VetraNet.Types.Enums)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local string_format = string.format

-- ─── Factory ─────────────────────────────────────────────────────────────────

--[[
    Bind all server-side hooks.

    Accepts a single ServerHooksContext table (see Types/NetworkTypes.lua).
    Using a named table means adding a new dependency in a future version is
    a field addition, not a signature change at every call site.

    Returns a Connections table of all RBXScriptConnections so the caller
    can disconnect them cleanly in Destroy().
]]
function ServerHooks.Bind(Ctx: NetworkTypes.ServerHooksContext): { RBXScriptConnection }
	local Solver            = Ctx.Solver
	local Remotes           = Ctx.Remotes
	local Session           = Ctx.Session
	local RateLimiter       = Ctx.RateLimiter
	local BehaviorRegistry  = Ctx.BehaviorRegistry
	local OwnershipRegistry = Ctx.OwnershipRegistry
	local StateBatcher      = Ctx.StateBatcher
	local OutboundBatcher   = Ctx.OutboundBatcher
	local ResolvedConfig    = Ctx.ResolvedConfig
	local OnValidatedHit    = Ctx.OnValidatedHit
	local OnFireRejected    = Ctx.OnFireRejected

	local Connections : { RBXScriptConnection } = {}

	-- Per-instance cast ID counter. Starts at 1; 0 is reserved as "invalid".
	local NextCastIdCounter = 1
	local function NextCastId(): number
		local CastId = NextCastIdCounter
		NextCastIdCounter += 1
		return CastId
	end

	-- ── ContextToCastId ────────────────────────────────────────────────────────
	-- Maps BulletContext → ServerCastId for the lifetime of each network cast.
	-- Populated in the FireChannel handler right after Solver:Fire succeeds.
	--
	-- Why this exists instead of reading Context.__solverData in signal handlers:
	--
	--   Bug A (deferred-fire race): VeSignal.FireSafe defers to task.defer when
	--   re-entrant (Firing > 0). If OnTerminated fires while another signal is
	--   already active (e.g. a bullet terminates inside OnHit), the handler runs
	--   one frame later — after Vetra's Terminate() has already called
	--   BulletContext:Terminate(), which nils __solverData. Reading __solverData
	--   at that point always returns nil → Session:RemoveCast is never called →
	--   _CastCount leaks → player permanently blocked from firing.
	--
	--   Bug B (direct-termination path): Cast:Terminate() calls Solver._Terminate
	--   directly, bypassing FireOnTerminated entirely. OnTerminated never fires at
	--   all, so neither __solverData nor this table would help on their own.
	--   See the _Terminate wrapper below for how Bug B is handled.
	--
	-- Weak keys: if a BulletContext becomes unreachable without going through
	-- normal cleanup (e.g. an unregistered non-network bullet) it is collected
	-- automatically without intervention.
	local ContextToCastId: { [any]: number } = setmetatable({}, { __mode = "k" })

	-- Internal cleanup: removes the cast from all authority tables.
	-- Called from both OnTerminated (normal path) and the _Terminate wrapper
	-- (direct Cast:Terminate() path). Idempotent — safe to call twice.
	local function CleanupCast(CastId: number)
		local Owner = OwnershipRegistry:GetOwner(CastId)
		if Owner then
			Session:RemoveCast(Owner, CastId)
		end
		OwnershipRegistry:Unregister(CastId)
	end

	-- ── _Terminate wrapper (Bug B fix) ─────────────────────────────────────────
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
			local CastId = ContextToCastId[BulletCtx]
			if CastId then
				-- OnTerminated did not run before us (direct termination path).
				-- Run cleanup now and clear the entry so OnTerminated, if it does
				-- fire later via a deferred signal, finds nothing and returns early.
				CleanupCast(CastId)
				ContextToCastId[BulletCtx] = nil
			end
		end
		_baseTerm(solver, cast, reason)
	end

	-- ── Pre-existing players ────────────────────────────────────────────────
	-- Register any players already in the server when VetraNet initialises.
	-- Without this, players present before require() have no session entry and
	-- all fire requests from them are silently rejected by Session:CanFire.
	for _, Player in Players:GetPlayers() do
		Session:Register(Player)
	end

	-- ── PlayerAdded: register session + late-join sync ──────────────────────
	Connections[#Connections + 1] = Players.PlayerAdded:Connect(function(Player: Player)
		Session:Register(Player)
		-- Defer by one frame so the solver's _ActiveCasts are stable before
		-- we snapshot them. Spawning the sync on the same tick as PlayerAdded
		-- would capture zero bullets because the frame loop hasn't run yet.
		task.defer(function()
			LateJoinHandler.SyncPlayer(
				Player,
				Solver,
				Remotes.Net,
				StateBatcher:GetNextFrameId()
			)
		end)
	end)

	-- ── PlayerRemoving: cleanup ─────────────────────────────────────────────
	Connections[#Connections + 1] = Players.PlayerRemoving:Connect(function(Player: Player)
		-- Terminate all bullets this player owns to prevent orphaned casts
		-- from continuing to be simulated with no owner to clean them up.
		-- Vetra exposes no GetCastById API — we build a fast lookup set from
		-- the ownership registry and scan _ActiveCasts once to find matches.
		local OwnedIds = {}
		for _, CastId in OwnershipRegistry:GetCastsForPlayer(Player) do
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
		Session:Unregister(Player)
		RateLimiter:Reset(Player)
		OutboundBatcher:RemovePlayer(Player)
	end)

	-- ── FireChannel: incoming fire request ──────────────────────────────────
	FireChannel.OnFireReceived(Remotes.Net, function(Player: Player, Payload: any)
		-- Validate the payload through the full authority chain.
		local Result = FireValidator.Validate(
			Player, Payload, Session, RateLimiter, BehaviorRegistry, ResolvedConfig
		)

		if not Result.Passed then
			OnFireRejected:Fire(Player, Result.Reason)
			-- No acknowledgement is sent to the client — see FireValidator.lua
			-- for the security rationale behind silent rejection.
			return
		end

		-- Resolve the behavior from the registry.
		local Behavior = BehaviorRegistry:Get(Payload.BehaviorHash)
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
				"ServerHooks: Solver:Fire returned nil for player '%s' (UserId: %d)",
				Player.Name, Player.UserId
				))
			return
		end

		-- Register cast in authority tables BEFORE replicate — a race between
		-- replication and termination would leave an orphaned entry if we
		-- registered after sending.
		Session:AddCast(Player, CastId)
		OwnershipRegistry:Register(CastId, Player)

		-- Register in ContextToCastId so OnHit and OnTerminated can resolve the
		-- ServerCastId without touching __solverData (which may be nil'd before
		-- deferred signal handlers run — see the table comment above).
		ContextToCastId[FireContext] = CastId

		-- Replicate the validated fire event. Two encodes are needed:
		--
		--   1. Shooter echo — carries LocalCastId (Payload.CastId) so ClientHooks
		--      can migrate the shooter's CosmeticTracker entry from LocalCastId
		--      → ServerCastId. Without this, hit confirmations and state batches
		--      (which carry ServerCastId) can never find the shooter's own cosmetic.
		--
		--   2. All-others broadcast — LocalCastId = 0. Other clients have no local
		--      cosmetic to migrate; they spawn a fresh cosmetic on receipt.
		--
		-- Both are queued via OutboundBatcher and flushed at the next Heartbeat.
		local AllPlayers  = Players:GetPlayers()
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
		OutboundBatcher:WriteFireForPlayer(Player, EncodedFireEcho)

		local EncodedFireBroadcast = BlinkSchema.EncodeFire(
			Payload.Origin,
			Payload.Direction,
			Payload.Speed,
			Payload.BehaviorHash,
			CastId,
			Payload.Timestamp,
			0
		)
		OutboundBatcher:WriteFireForAll(AllPlayers, Player.UserId, EncodedFireBroadcast)
	end)

	-- ── Solver.OnHit: validated hit → broadcast ─────────────────────────────
	Solver.Signals.OnHit:Connect(function(Context: any, Result: RaycastResult?, Velocity: Vector3, ImpactForce: Vector3)
		local CastId = ContextToCastId[Context]
		if not CastId then return end

		local Owner = OwnershipRegistry:GetOwner(CastId)
		if not Owner then
			-- Hit fired by an unregistered cast (e.g. server-spawned non-network bullet).
			return
		end

		local HitPosition = Result and Result.Position or Context.Position
		local HitNormal   = Result and Result.Normal   or Vector3.yAxis
		local Timestamp   = workspace:GetServerTimeNow()

		-- Signal game code (damage, effects, etc.).
		OnValidatedHit:Fire(Owner, Context, Result, Velocity, ImpactForce)

		-- Queue hit for all clients via OutboundBatcher — flushed at frame end.
		local AllPlayers = Players:GetPlayers()
		local EncodedHit = BlinkSchema.EncodeHit(
			CastId, HitPosition, HitNormal, Velocity, Timestamp
		)
		OutboundBatcher:WriteHitForAll(AllPlayers, EncodedHit)
	end)

	-- ── Solver.OnTerminated: release cast ───────────────────────────────────
	Solver.Signals.OnTerminated:Connect(function(Context: any)
		local CastId = ContextToCastId[Context]
		if not CastId then return end -- already cleaned up by _Terminate wrapper
		ContextToCastId[Context] = nil

		CleanupCast(CastId)
	end)

	return Connections
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(ServerHooks, {
	__index = function(_, Key)
		Logger:Warn(string_format("ServerHooks: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("ServerHooks: write to protected key '%s'", tostring(Key)))
	end,
}))