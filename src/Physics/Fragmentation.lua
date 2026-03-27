--!native
--!optimize 2
--!strict

-- ─── Fragmentation ───────────────────────────────────────────────────────────
--[[
    Fragment spawning on pierce — cone-distributed child casts.
]]

-- ─── References ──────────────────────────────────────────────────────────────
local Vetra 	 = script.Parent.Parent
local Core       = Vetra.Core
local Registry   = Vetra.Registry
local Signals    = Vetra.Signals

-- ─── Module References ───────────────────────────────────────────────────────

local LogService      = require(Core.Logger)
local BulletContext   = require(Core.BulletContext)
local t               = require(Core.TypeCheck)
local Constants		  = require(Core.Constants)
local ParamsPooler    = require(Core.RaycastParamsPooler)
local FireHelpers     = require(Signals.FireHelpers)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("Fragmentation", true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_rad   = math.rad
local math_cos   = math.cos
local math_sqrt  = math.sqrt
local math_abs   = math.abs
local math_sin   = math.sin

-- ─── Constants ─────────────────────────────────────────────────────────


local ZERO_VECTOR                = Constants.ZERO_VECTOR
local LOOK_AT_FALLBACK           = Constants.LOOK_AT_FALLBACK
local UP_VECTOR                  = Constants.UP_VECTOR
local RIGHT_VECTOR               = Constants.RIGHT_VECTOR
local MIN_VELOCITY_SQ            = Constants.MIN_VELOCITY_SQ
local PERPENDICULAR_AXIS_THRESHOLD = Constants.PERPENDICULAR_AXIS_THRESHOLD

-- ─── Private Helpers ─────────────────────────────────────────────────────────

local Random = Random.new()

local function RandomConeDirection(BaseDirection: Vector3, HalfAngleDeg: number): Vector3
	local HalfAngleRad = math_rad(HalfAngleDeg)
	local Phi          = Random:NextNumber(0, math.pi * 2)
	local CosTheta     = Random:NextNumber(math_cos(HalfAngleRad), 1)
	local SinTheta     = math_sqrt(1 - CosTheta * CosTheta)

	local PerpendicularA = BaseDirection:Cross(math_abs(BaseDirection.X) < PERPENDICULAR_AXIS_THRESHOLD and RIGHT_VECTOR or UP_VECTOR).Unit
	local PerpendicularB = BaseDirection:Cross(PerpendicularA).Unit

	return (BaseDirection * CosTheta + PerpendicularA * (SinTheta * math_cos(Phi)) + PerpendicularB * (SinTheta * math_sin(Phi))).Unit
end

-- ─── Module ──────────────────────────────────────────────────────────────────

local Fragmentation = {}

function Fragmentation.SpawnFragments(
	Solver          : any,
	ParentCast      : any,
	PiercePosition  : Vector3,
	CurrentVelocity : Vector3
)
	local Behavior        = ParentCast.Behavior
	local FragmentCount   = Behavior.FragmentCount
	local FragmentDeviation = Behavior.FragmentDeviation
	local Speed           = CurrentVelocity.Magnitude
	local BaseDirection   = Speed * Speed > MIN_VELOCITY_SQ and CurrentVelocity.Unit or LOOK_AT_FALLBACK
	local ParentBulletContext = Solver._CastToBulletContext[ParentCast]
	
	for Index = 1, FragmentCount do
		local FragmentDirection = RandomConeDirection(BaseDirection, FragmentDeviation)
		
		local FragmentContext = BulletContext.new({
			Origin     = PiercePosition,
			Direction  = FragmentDirection,
			Speed      = Speed,
			Callbacks  = nil,
			SolverData = {},
		})

		local ChildBehavior: { [string]: any } = {}
		for BehaviorKey, BehaviorValue in pairs(Behavior :: any) do
			ChildBehavior[BehaviorKey] = BehaviorValue
		end
		-- Deep-copy mutable table fields so parent and siblings do not share
		-- references. A bounce hook mutating MaterialRestitution on any one
		-- cast would otherwise corrupt the map for every fragment and the
		-- parent. SpeedThresholds is similarly user-supplied and mutable.
		if t.table(Behavior.MaterialRestitution) then
			ChildBehavior.MaterialRestitution = table.clone(Behavior.MaterialRestitution)
		end
		if t.table(Behavior.SpeedThresholds) then
			ChildBehavior.SpeedThresholds = table.clone(Behavior.SpeedThresholds)
		end
		ChildBehavior.FragmentOnPierce = false
		ChildBehavior.HomingPositionProvider = nil

		-- Behavior.Acceleration is the fully-baked effective acceleration
		-- (gravity + user accel + wind + drag). Fire() will re-add all of those,
		-- so we must pass only the original user-supplied component.
		-- _BaseAccelerationCache[ParentCast] = gravity + user_accel (no wind/drag),
		-- so user_accel = BaseAccel - Behavior.Gravity.
		local CachedBaseAcceleration = Solver._BaseAccelerationCache and Solver._BaseAccelerationCache[ParentCast]
		ChildBehavior.Acceleration = CachedBaseAcceleration and (CachedBaseAcceleration - Behavior.Gravity) or ZERO_VECTOR

		-- Each fragment must own its own RaycastParams clone.
		-- Sharing the parent's pooled object causes mutual filter corruption
		-- and double-release on Terminate().
		local FreshRaycastParams = RaycastParams.new()
		FreshRaycastParams.FilterType = Behavior.RaycastParams.FilterType
		FreshRaycastParams.FilterDescendantsInstances = table.clone(Behavior.OriginalFilter)

		ChildBehavior.RaycastParams = FreshRaycastParams
		local ChildCast = Solver:Fire(FragmentContext, ChildBehavior)

		if ChildCast then
			ChildCast.Runtime.ParentCastId = ParentCast.Id
			FireHelpers.FireOnBranchSpawned(Solver, ParentBulletContext, Solver._CastToBulletContext[ChildCast])
		end
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(Fragmentation, {
	__index = function(_, Key)
		Logger:Warn(string.format("Vetra: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Vetra: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})