--!native
--!optimize 2
--!strict

-- ─── Bounce ──────────────────────────────────────────────────────────────────
--[[
    Bounce physics — reflection, restitution, and corner-trap detection.
]]

local Identity = "Bounce"
local Bounce   = {}
Bounce.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local PureBounce = require(script.Parent.Pure.Bounce)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

-- Thin delegations — pure math lives in Physics/Pure/Bounce.
function Bounce.Reflect(IncomingVelocity: Vector3, SurfaceNormal: Vector3): Vector3
	return PureBounce.Reflect(IncomingVelocity, SurfaceNormal)
end

function Bounce.ApplyRestitution(
	ReflectedVelocity  : Vector3,
	SurfaceNormal      : Vector3,
	Restitution        : number,
	MaterialMultiplier : number,
	NormalPerturbation : number
): Vector3
	return PureBounce.ApplyRestitution(ReflectedVelocity, SurfaceNormal, Restitution, MaterialMultiplier, NormalPerturbation)
end

function Bounce.GetMaterialMultiplier(Cast: any, Material: Enum.Material): number
	return PureBounce.GetMaterialMultiplier(Cast.Behavior.MaterialRestitution, Material)
end

--[[
    Builds a plain CornerState from Cast.Runtime + Cast.Behavior and delegates
    to PureBounce.IsCornerTrap so both serial and parallel paths share the
    same four-pass trap detection algorithm.
]]
function Bounce.IsCornerTrap(Cast: any, SurfaceNormal: Vector3, ContactPosition: Vector3): boolean
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local State: PureBounce.CornerState = {
		TotalRuntime                = Runtime.TotalRuntime,
		LastBounceTime              = Runtime.LastBounceTime,
		BouncePositionHistory       = Runtime.BouncePositionHistory,
		BouncePositionHead          = Runtime.BouncePositionHead,
		CornerBounceCount           = Runtime.CornerBounceCount,
		VelocityDirectionEMA        = Runtime.VelocityDirectionEMA,
		FirstBouncePosition         = Runtime.FirstBouncePosition,
		CornerTimeThreshold         = Behavior.CornerTimeThreshold,
		CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold,
		CornerEMAAlpha              = Behavior.CornerEMAAlpha,
		CornerEMAThreshold          = Behavior.CornerEMAThreshold,
		CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = Behavior.CornerPositionHistorySize,
	}

	return PureBounce.IsCornerTrap(State, ContactPosition, Runtime.TotalRuntime)
end

--[[
    Delegates the functional RecordBounceState calculation to PureBounce, then
    applies the returned values back to Cast.Runtime.
    CornerBounceCount is incremented here (not via BounceCount) because
    BounceCount is incremented later by FireOnBounce.
]]
function Bounce.RecordBounceState(Cast: any, Normal: Vector3, Position: Vector3, PostBounceVelocity: Vector3)
	local Runtime  = Cast.Runtime
	local Behavior = Cast.Behavior

	local State: PureBounce.CornerState = {
		TotalRuntime                = Runtime.TotalRuntime,
		LastBounceTime              = Runtime.LastBounceTime,
		BouncePositionHistory       = Runtime.BouncePositionHistory,
		BouncePositionHead          = Runtime.BouncePositionHead,
		CornerBounceCount           = Runtime.CornerBounceCount,
		VelocityDirectionEMA        = Runtime.VelocityDirectionEMA,
		FirstBouncePosition         = Runtime.FirstBouncePosition,
		CornerTimeThreshold         = Behavior.CornerTimeThreshold,
		CornerDisplacementThreshold = Behavior.CornerDisplacementThreshold,
		CornerEMAAlpha              = Behavior.CornerEMAAlpha,
		CornerEMAThreshold          = Behavior.CornerEMAThreshold,
		CornerMinProgressPerBounce  = Behavior.CornerMinProgressPerBounce,
		CornerPositionHistorySize   = Behavior.CornerPositionHistorySize,
	}

	local NewLastBounceTime, NewHead, NewHistory, NewCornerBounceCount, NewEMA, NewFirstBounce =
		PureBounce.RecordBounceState(State, Position, PostBounceVelocity, Runtime.TotalRuntime)

	Runtime.LastBounceTime       = NewLastBounceTime
	Runtime.BouncePositionHead   = NewHead
	Runtime.BouncePositionHistory = NewHistory
	Runtime.CornerBounceCount    = NewCornerBounceCount
	Runtime.VelocityDirectionEMA = NewEMA
	Runtime.FirstBouncePosition  = NewFirstBounce
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local BounceMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Bounce: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Bounce: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Bounce, BounceMetatable)