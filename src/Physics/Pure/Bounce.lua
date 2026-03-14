--!native
--!optimize 2
--!strict

-- ─── Physics/Pure/Bounce ─────────────────────────────────────────────────────
--[[
    Pure bounce math — no Cast references, no signal calls, no Instance writes.

    IsCornerTrap and RecordBounceState are fully functional: they accept a
    plain CornerState table and return new values rather than mutating any
    shared state. This makes them safe for the parallel Actor context, and
    lets the serial Bounce wrapper apply the returned values to Cast.Runtime.

    Note on material restitution keys:
        GetMaterialMultiplier uses Enum.Material keys, matching the format
        that consumers provide and that the serial path stores in
        Behavior.MaterialRestitution.

        In the parallel path, Coordinator.AddCast serializes those Enum keys
        to strings before crossing the Actor boundary (Enums cannot be packed
        into SendMessage). ParallelPhysics therefore keeps its own one-liner
        tostring() lookup rather than delegating here — both lookups are
        correct for their respective key formats.
]]

local PureBounce  = {}
PureBounce.__type = "PureBounce"

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local Constants = require(Core.Constants)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local math_random = math.random
local math_sqrt   = math.sqrt
local math_max    = math.max

local MIN_MAGNITUDE_SQ = Constants.MIN_MAGNITUDE_SQ
local MIN_DOT_SQ       = Constants.MIN_DOT_SQ

-- ─── Local Types ─────────────────────────────────────────────────────────────

-- Plain-data corner-trap state shared by both serial and parallel paths.
-- The serial Bounce wrapper builds one from Cast.Runtime + Cast.Behavior.
-- ParallelPhysics constructs one from the snapshot / its mutable BounceState.
export type CornerState = {
	TotalRuntime:                number,
	LastBounceTime:              number,
	BouncePositionHistory:       { Vector3 },
	BouncePositionHead:          number,
	CornerBounceCount:           number,
	VelocityDirectionEMA:        Vector3,
	FirstBouncePosition:         Vector3?,
	-- config fields (from Behavior)
	CornerTimeThreshold:         number,
	CornerDisplacementThreshold: number,
	CornerEMAAlpha:              number,
	CornerEMAThreshold:          number,
	CornerMinProgressPerBounce:  number,
	CornerPositionHistorySize:   number,
}

-- ─── Module ──────────────────────────────────────────────────────────────────

function PureBounce.Reflect(IncomingVelocity: Vector3, SurfaceNormal: Vector3): Vector3
	return IncomingVelocity - 2 * IncomingVelocity:Dot(SurfaceNormal) * SurfaceNormal
end

function PureBounce.ApplyRestitution(
	ReflectedVelocity  : Vector3,
	Restitution        : number,
	MaterialMultiplier : number,
	NormalPerturbation : number
): Vector3
	local FinalVelocity = ReflectedVelocity * (Restitution * MaterialMultiplier)

	if NormalPerturbation > 0 and FinalVelocity:Dot(FinalVelocity) > MIN_DOT_SQ then
		local Noise = Vector3.new(
			math_random() - 0.5,
			math_random() - 0.5,
			math_random() - 0.5
		).Unit * NormalPerturbation
		FinalVelocity = (FinalVelocity.Unit + Noise).Unit * FinalVelocity.Magnitude
	end

	return FinalVelocity
end

--[[
    Looks up the per-material restitution multiplier using an Enum.Material key.
    Returns 1.0 when the map is absent or the material has no entry.
    Used by the serial path where Behavior.MaterialRestitution stores Enum keys.
]]
function PureBounce.GetMaterialMultiplier(
	MaterialRestitutionMap : { [Enum.Material]: number }?,
	Material               : Enum.Material
): number
	if not MaterialRestitutionMap then return 1.0 end
	return MaterialRestitutionMap[Material] or 1.0
end

--[[
    Returns true if the contact qualifies as a corner trap.

    Runs four passes in order of ascending cost:
        Pass 1 — time gate (O(1))
        Pass 2 — position ring-buffer revisit (O(N))
        Pass 3 — velocity-direction EMA collapse (O(1))
        Pass 4 — net displacement from first bounce (O(1))

    All state is read from the provided CornerState; nothing is mutated.
]]
function PureBounce.IsCornerTrap(
	State           : CornerState,
	ContactPosition : Vector3,
	CurrentTime     : number
): boolean
	-- Pass 1: time gate
	if (CurrentTime - State.LastBounceTime) < State.CornerTimeThreshold then
		return true
	end

	-- Pass 2: position ring-buffer revisit
	local DisplacementThresholdSq = State.CornerDisplacementThreshold * State.CornerDisplacementThreshold
	for _, Position in State.BouncePositionHistory do
		local Delta = ContactPosition - Position
		if Delta:Dot(Delta) < DisplacementThresholdSq then
			return true
		end
	end

	-- Pass 3: velocity-direction EMA
	if State.CornerBounceCount >= 1 then
		local EMAMagnitudeSq = State.VelocityDirectionEMA:Dot(State.VelocityDirectionEMA)
		if EMAMagnitudeSq < State.CornerEMAThreshold * State.CornerEMAThreshold then
			return true
		end
	end

	-- Pass 4: net displacement guard
	local MinProgress = State.CornerMinProgressPerBounce
	if MinProgress > 0
		and State.FirstBouncePosition ~= nil
		and State.CornerBounceCount >= 3
	then
		local NetDisplacement = ContactPosition - State.FirstBouncePosition
		local NetDistanceSq   = NetDisplacement:Dot(NetDisplacement)
		local MinRequired     = State.CornerBounceCount * MinProgress
		if NetDistanceSq < MinRequired * MinRequired then
			return true
		end
	end

	return false
end

--[[
    Returns updated corner-trap tracking state after a bounce contact.
    Nothing is mutated — all changes are returned as new values.

    Return order:
        NewLastBounceTime, NewHead, NewHistory,
        NewCornerBounceCount, NewVelocityDirectionEMA, NewFirstBouncePosition
]]
function PureBounce.RecordBounceState(
	State              : CornerState,
	ContactPosition    : Vector3,
	PostBounceVelocity : Vector3,
	TotalRuntime       : number
): (number, number, { Vector3 }, number, Vector3, Vector3?)
	local HistorySize = math_max(State.CornerPositionHistorySize, 4)

	-- Advance ring-buffer head and write new contact
	local NewHead    = (State.BouncePositionHead % HistorySize) + 1
	local NewHistory : { Vector3 } = {}
	for Index, Value in State.BouncePositionHistory do
		NewHistory[Index] = Value
	end
	NewHistory[NewHead] = ContactPosition

	-- Update velocity-direction EMA
	local Alpha        = State.CornerEMAAlpha
	local NewEMA: Vector3
	local SpeedSq = PostBounceVelocity:Dot(PostBounceVelocity)
	if SpeedSq > MIN_MAGNITUDE_SQ then
		local Direction = PostBounceVelocity / math_sqrt(SpeedSq)
		NewEMA = State.VelocityDirectionEMA * (1 - Alpha) + Direction * Alpha
	else
		-- Speed died — decay toward zero so Pass 3 converges on a stalled bullet
		NewEMA = State.VelocityDirectionEMA * (1 - Alpha)
	end

	local NewFirstBounce        = State.FirstBouncePosition or ContactPosition
	local NewCornerBounceCount  = State.CornerBounceCount + 1

	return TotalRuntime, NewHead, NewHistory, NewCornerBounceCount, NewEMA, NewFirstBounce
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(PureBounce)
