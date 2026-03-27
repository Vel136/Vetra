--!native
--!optimize 2
--!strict

-- ─── Magnus ──────────────────────────────────────────────────────────────────
--[[
    Magnus effect — lateral force on a spinning projectile.

    A spinning projectile moving through air experiences a force perpendicular
    to both its spin axis and velocity vector. This causes curveball-style
    deviation — right-hand barrel twist pushes the bullet right, backspin
    causes lift, topspin causes drop.

    Physics:
        F_magnus = Cm * (SpinVector × Velocity)

    Where:
        SpinVector        — axis of spin (direction) × angular velocity (magnitude, rad/s)
        Velocity          — current projectile velocity
        Cm (coefficient)  — scales force magnitude, tuned per projectile

    Integration:
        Magnus force is added as an acceleration component inside
        Drag.RecalcSegment, evaluated every DragSegmentInterval seconds.
        Spin decays each segment via SpinDecayRate if configured.

    Behavior fields required:
        SpinVector        : Vector3   — spin axis and rate (rad/s). Zero = disabled.
        MagnusCoefficient : number    — force scale factor. Typical range: 0.00005–0.001.
        SpinDecayRate     : number    — fraction of spin lost per second. 0 = no decay.

    Practical starting values (rifle, ~900 studs/s, right-hand twist):
        SpinVector        = Vector3.new(0, 0, 1) * 300   -- rightward spin
        MagnusCoefficient = 0.0001
        SpinDecayRate     = 0.05

    Note: MagnusCoefficient is highly sensitive. Start small and increase
    incrementally — at high speeds even 0.001 produces dramatic deviation.
]]

-- ─── Module ──────────────────────────────────────────────────────────────────

local Identity = "Magnus"
local Magnus   = {}
Magnus.__type  = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)
local PureMagnus = require(script.Parent.Pure.Magnus)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ

-- ─── Module ──────────────────────────────────────────────────────────────────

-- Thin delegations — pure math lives in Physics/Pure/Magnus.
function Magnus.ComputeForce(
	SpinVector        : Vector3,
	Velocity          : Vector3,
	MagnusCoefficient : number
): Vector3
	return PureMagnus.ComputeForce(SpinVector, Velocity, MagnusCoefficient)
end

--[[
    Applies spin decay for one segment. Calls PureMagnus.ApplySpinDecay
    (functional) then writes the result back to Behavior.SpinVector.
]]
function Magnus.StepSpinDecay(Behavior: any, Delta: number)
	local DecayRate = Behavior.SpinDecayRate
	if not DecayRate or DecayRate <= 0 then return end

	Behavior.SpinVector = PureMagnus.ApplySpinDecay(Behavior.SpinVector, DecayRate, Delta)
end

function Magnus.IsActive(Behavior: any): boolean
	return Behavior.MagnusCoefficient ~= nil
		and Behavior.MagnusCoefficient > 0
		and Behavior.SpinVector ~= nil
		and Behavior.SpinVector:Dot(Behavior.SpinVector) > MIN_MAGNITUDE_SQ
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local MagnusMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("Magnus: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Magnus: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(Magnus, MagnusMetatable)