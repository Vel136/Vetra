--!native
--!optimize 2
--!strict

-- ─── HookHelpers ─────────────────────────────────────────────────────────────
--[[
    Mutable-data hook helpers for pre/mid bounce and penetration events.
]]

local Identity    = "HookHelpers"
local HookHelpers = {}
HookHelpers.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── References (TypeCheck needed for write-time validation) ─────────────────

local t = require(Core.TypeCheck)

-- ─── Private ─────────────────────────────────────────────────────────────────

local STALE_MUTATE_WARNING =
	"MutateData called after the hook window closed. "
	.. "Connect to hook signals synchronously — async listeners cannot mutate data."

-- ─── Module ──────────────────────────────────────────────────────────────────

function HookHelpers.FireOnPreBounce(
	Solver    : any,
	Cast      : any,
	HitResult : RaycastResult,
	Velocity  : Vector3
): (Vector3, Vector3)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return HitResult.Normal, Velocity end

	local Normal           = HitResult.Normal
	local IncomingVelocity = Velocity

	local live = true
	local function MutateData(NewNormal: Vector3?, NewIncomingVelocity: Vector3?)
		if not live then Logger:Warn(STALE_MUTATE_WARNING) return end
		if NewNormal ~= nil then
			if t.Vector3(NewNormal) then
				Normal = NewNormal
			else
				Logger:Warn("FireOnPreBounce MutateData: Normal must be Vector3")
			end
		end
		if NewIncomingVelocity ~= nil then
			if t.Vector3(NewIncomingVelocity) then
				IncomingVelocity = NewIncomingVelocity
			else
				Logger:Warn("FireOnPreBounce MutateData: IncomingVelocity must be Vector3")
			end
		end
	end

	Solver.Signals.OnPreBounce:FireSafe(Context, HitResult, Velocity, MutateData)
	live = false
	return Normal, IncomingVelocity
end

function HookHelpers.FireOnMidBounce(
	Solver      : any,
	Cast        : any,
	HitResult   : RaycastResult,
	PostVelocity: Vector3
): (Vector3, number, number)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then
		return PostVelocity, Cast.Behavior.Restitution, Cast.Behavior.NormalPerturbation
	end

	local PostBounceVelocity = PostVelocity
	local Restitution        = Cast.Behavior.Restitution
	local NormalPerturbation = Cast.Behavior.NormalPerturbation

	local live = true
	local function MutateData(NewPostBounceVelocity: Vector3?, NewRestitution: number?, NewNormalPerturbation: number?)
		if not live then Logger:Warn(STALE_MUTATE_WARNING) return end
		if NewPostBounceVelocity ~= nil then
			if t.Vector3(NewPostBounceVelocity) then
				PostBounceVelocity = NewPostBounceVelocity
			else
				Logger:Warn("FireOnMidBounce MutateData: PostBounceVelocity must be Vector3")
			end
		end
		if NewRestitution ~= nil then
			if t.number(NewRestitution) and NewRestitution >= 0 and NewRestitution <= 1 then
				Restitution = NewRestitution
			else
				Logger:Warn("FireOnMidBounce MutateData: Restitution must be number in [0, 1]")
			end
		end
		if NewNormalPerturbation ~= nil then
			if t.number(NewNormalPerturbation) and NewNormalPerturbation >= 0 then
				NormalPerturbation = NewNormalPerturbation
			else
				Logger:Warn("FireOnMidBounce MutateData: NormalPerturbation must be number >= 0")
			end
		end
	end

	Solver.Signals.OnMidBounce:FireSafe(Context, HitResult, PostVelocity, MutateData)
	live = false
	return PostBounceVelocity, Restitution, NormalPerturbation
end

function HookHelpers.FireOnPrePenetration(
	Solver    : any,
	Cast      : any,
	HitResult : RaycastResult,
	Velocity  : Vector3
): (Vector3?, number?)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return nil, nil end

	local EntryVelocity     = nil :: Vector3?
	local MaxPierceOverride = nil :: number?

	local live = true
	local function MutateData(NewEntryVelocity: Vector3?, NewMaxPierceOverride: number?)
		if not live then Logger:Warn(STALE_MUTATE_WARNING) return end
		if NewEntryVelocity ~= nil then
			if t.Vector3(NewEntryVelocity) then
				EntryVelocity = NewEntryVelocity
			else
				Logger:Warn("FireOnPrePenetration MutateData: EntryVelocity must be Vector3")
			end
		end
		if NewMaxPierceOverride ~= nil then
			if t.number(NewMaxPierceOverride) and NewMaxPierceOverride >= 1 and NewMaxPierceOverride <= Cast.Behavior.MaxPierceCount then
				MaxPierceOverride = math.floor(NewMaxPierceOverride)
			else
				Logger:Warn("FireOnPrePenetration MutateData: MaxPierceOverride must be number in [1, MaxPierceCount]")
			end
		end
	end

	Solver.Signals.OnPrePenetration:FireSafe(Context, HitResult, Velocity, MutateData)
	live = false
	return EntryVelocity, MaxPierceOverride
end

function HookHelpers.FireOnMidPenetration(
	Solver    : any,
	Cast      : any,
	HitResult : RaycastResult,
	Velocity  : Vector3
): (number, Vector3?)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return Cast.Behavior.PenetrationSpeedRetention, nil end

	local SpeedRetention = Cast.Behavior.PenetrationSpeedRetention
	local ExitVelocity   = nil :: Vector3?

	local live = true
	local function MutateData(NewSpeedRetention: number?, NewExitVelocity: Vector3?)
		if not live then Logger:Warn(STALE_MUTATE_WARNING) return end
		if NewSpeedRetention ~= nil then
			if t.number(NewSpeedRetention) and NewSpeedRetention >= 0 and NewSpeedRetention <= 1 then
				SpeedRetention = NewSpeedRetention
			else
				Logger:Warn("FireOnMidPenetration MutateData: SpeedRetention must be number in [0, 1]")
			end
		end
		if NewExitVelocity ~= nil then
			if t.Vector3(NewExitVelocity) then
				ExitVelocity = NewExitVelocity
			else
				Logger:Warn("FireOnMidPenetration MutateData: ExitVelocity must be Vector3")
			end
		end
	end

	Solver.Signals.OnMidPenetration:FireSafe(Context, HitResult, Velocity, MutateData)
	live = false
	return SpeedRetention, ExitVelocity
end

function HookHelpers.FireOnPreTermination(
	Solver : any,
	Cast   : any,
	Reason : string
): (boolean, string)
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return false, Reason end

	local Cancelled    = false
	local MutatedReason = Reason

	local live = true
	local function MutateData(NewCancelled: boolean?, NewReason: string?)
		if not live then Logger:Warn(STALE_MUTATE_WARNING) return end
		if NewCancelled ~= nil then
			if t.boolean(NewCancelled) then
				Cancelled = NewCancelled
			else
				Logger:Warn("FireOnPreTermination MutateData: Cancelled must be boolean")
			end
		end
		if NewReason ~= nil then
			if t.string(NewReason) then
				MutatedReason = NewReason
			else
				Logger:Warn("FireOnPreTermination MutateData: Reason must be string")
			end
		end
	end

	Solver.Signals.OnPreTermination:FireSafe(Context, Reason, MutateData)
	live = false
	return Cancelled, MutatedReason
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local HookHelpersMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("HookHelpers: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"HookHelpers: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(HookHelpers, HookHelpersMetatable)