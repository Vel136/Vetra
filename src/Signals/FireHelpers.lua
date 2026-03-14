--!native
--!optimize 2
--!strict

-- ─── FireHelpers ─────────────────────────────────────────────────────────────
--[[
    Signal emission helpers — one call site per event type.
]]

local Identity    = "FireHelpers"
local FireHelpers = {}
FireHelpers.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

function FireHelpers.FireOnHit(Solver: any, Cast: any, HitResult: RaycastResult?, HitVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	if HitResult then
		Context:_UpdateState(HitResult.Position, HitVelocity, Cast.Runtime.DistanceCovered, Cast.Runtime.TotalRuntime)
	end

	-- ImpactForce = mass × Δvelocity (impulse approximation: bullet goes from
	-- HitVelocity to zero on terminal impact). Zero when BulletMass is 0.
	local BulletMass   = Cast.Behavior.BulletMass
	local ImpactForce  = (BulletMass and BulletMass > 0)
		and (HitVelocity * BulletMass)
		or Vector3.zero

	Solver.Signals.OnHit:FireSafe(Context, HitResult, HitVelocity, ImpactForce)
end

function FireHelpers.FireOnTravel(Solver: any, Cast: any, Position: Vector3, Velocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Context:_UpdateState(Position, Velocity, Cast.Runtime.DistanceCovered, Cast.Runtime.TotalRuntime)

	if Cast.Behavior.BatchTravel then
		local Batch = Solver._TravelBatch
		Batch[#Batch + 1] = {
			Context  = Context,
			Position = Position,
			Velocity = Velocity,
		}
	else
		Solver.Signals.OnTravel:Fire(Context, Position, Velocity)
	end
end

function FireHelpers.FlushTravelBatch(Solver: any)
	local Batch = Solver._TravelBatch
	if #Batch == 0 then return end
	Solver.Signals.OnTravelBatch:Fire(Batch)
	table.clear(Batch)
end

function FireHelpers.FireOnPierce(Solver: any, Cast: any, Result: RaycastResult, Velocity: Vector3)
	-- Increment PierceCount before the context nil-guard. If an OnMidPenetration
	-- handler calls BulletContext:Terminate() the context is unlinked, but the
	-- pierce still happened — the count must advance so ResolveChain's
	-- PierceCount >= EffectiveMaxPierce break condition can eventually fire.
	Cast.Runtime.PierceCount += 1
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Context:_UpdateState(Result.Position, Velocity, Cast.Runtime.DistanceCovered, Cast.Runtime.TotalRuntime)
	Solver.Signals.OnPierce:FireSafe(Context, Result, Velocity, Cast.Runtime.PierceCount)
end

function FireHelpers.FireOnBounce(Solver: any, Cast: any, Result: RaycastResult, PostVelocity: Vector3, PreVelocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Cast.Runtime.BounceCount += 1
	Context:_UpdateState(Result.Position, PostVelocity, Cast.Runtime.DistanceCovered, Cast.Runtime.TotalRuntime)

	-- BounceForce = force transferred to the surface on impact.
	-- The more inelastic the bounce (low Restitution × MaterialMultiplier),
	-- the more momentum is transferred to the surface.
	-- ΔV = PreVelocity - PostVelocity (change in bullet momentum direction).
	-- BounceForce = mass × ΔV (impulse transferred to surface).
	local BulletMass   = Cast.Behavior.BulletMass
	local BounceForce  = (BulletMass and BulletMass > 0)
		and ((PreVelocity - PostVelocity) * BulletMass)
		or Vector3.zero

	Solver.Signals.OnBounce:FireSafe(Context, Result, PostVelocity, Cast.Runtime.BounceCount, BounceForce)
end

function FireHelpers.FireOnTerminated(Solver: any, Cast: any)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTerminated:FireSafe(Context)
end

function FireHelpers.FireOnSegmentOpen(Solver: any, Cast: any, Segment: any)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnSegmentOpen:FireSafe(Context, Segment)
end

function FireHelpers.FireOnSpeedThresholdCrossed(Solver: any, Cast: any, Threshold: number, IsAscending: boolean, Speed: number)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnSpeedThresholdCrossed:FireSafe(Context, Threshold, IsAscending, Speed)
end

function FireHelpers.FireOnBranchSpawned(Solver: any, ParentContext: any, ChildContext: any)
	if not ParentContext then return end
	Solver.Signals.OnBranchSpawned:FireSafe(ParentContext, ChildContext)
end

function FireHelpers.FireOnHomingDisengaged(Solver: any, Cast: any)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnHomingDisengaged:FireSafe(Context)
end

function FireHelpers.FireOnTumbleBegin(Solver: any, Cast: any, Velocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTumbleBegin:FireSafe(Context, Velocity)
end

function FireHelpers.FireOnTumbleEnd(Solver: any, Cast: any, Velocity: Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTumbleEnd:FireSafe(Context, Velocity)
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local FireHelpersMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("FireHelpers: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"FireHelpers: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(FireHelpers, FireHelpersMetatable)