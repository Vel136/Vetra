--!native
--!optimize 2
--!strict

-- ─── BulletContext ───────────────────────────────────────────────────────────
--[[
    Solver-agnostic bullet runtime object.

    Tracks bullet state and lifecycle without exposing solver internals.
    Updated by solvers each frame via _UpdateState.
]]

-- ─── Module References ───────────────────────────────────────────────────────

local LogService        = require(script.Parent.Logger)
local BulletContextType = require(script.Type)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("BulletContext", true)

-- ─── Type Exports ────────────────────────────────────────────────────────────

export type BulletContext       = BulletContextType.BulletContext
export type BulletSnapshot      = BulletContextType.BulletSnapshot
export type BulletContextConfig = BulletContextType.BulletContextConfig

-- ─── Module ──────────────────────────────────────────────────────────────────

local IDENTITY = "BulletContext"

local BulletContext   = {}
BulletContext.__index = BulletContext
BulletContext.__type  = IDENTITY

-- ─── Private State ───────────────────────────────────────────────────────────

local _NextId = 0

-- ─── Constructor ─────────────────────────────────────────────────────────────

function BulletContext.new(config: BulletContextConfig): BulletContext
	assert(config.Origin,    "[BulletContext] Origin is required")
	assert(config.Direction, "[BulletContext] Direction is required")
	assert(config.Speed,     "[BulletContext] Speed is required")

	local self = setmetatable({}, BulletContext)

	-- Identity
	self.Id   = _NextId
	_NextId  += 1

	-- Immutable initial state
	self.Origin     = config.Origin
	self.Direction  = config.Direction
	self.Speed      = config.Speed
	-- NOTE: Callbacks, Bullet, Trajectory, and LastPoint have been removed.
	-- They were initialized here but never read or written anywhere in the
	-- codebase. Keeping dead fields wastes memory and misleads consumers who
	-- might inspect them expecting live data.
	self.StartTime  = os.clock()

	-- Runtime state (mutated by solver)
	self.Position   = nil
	self.Velocity   = self.Direction * self.Speed
	self.Alive      = true
	self.SimulationTime = os.clock()
	-- Length tracks the true path distance (updated each frame by the solver).
	-- This diverges from straight-line Origin-to-Position distance for bullets
	-- that bounce or follow homing curves.
	self.Length     = 0

	-- [6DOF] Angular state — nil when 6DOF is disabled, populated by solver
	-- each frame when SixDOFEnabled = true.
	self.Orientation      = nil :: CFrame?
	self.AngularVelocity  = nil :: Vector3?
	self.AngleOfAttack    = nil :: number?

	-- Internal solver data (do not access from weapon code)
	self.__solverData = config.SolverData or {}
	self.UserData = {}
	-- Set by the solver after cosmetic bullet creation; readable from signal
	-- handlers (OnSegmentOpen, OnBounce, etc.) via the context argument.
	self.CosmeticBulletObject = nil

	return self
end

-- ─── State API ───────────────────────────────────────────────────────────────

function BulletContext.IsAlive(self: BulletContext): boolean
	return self.Alive
end

function BulletContext.GetLifetime(self: BulletContext): number
	return self.SimulationTime
end

function BulletContext.GetDistanceTraveled(self: BulletContext): number
	-- Return the true path length accumulated by the solver each frame.
	-- The previous implementation returned (Position - Origin).Magnitude which
	-- gives straight-line distance — correct only for non-bouncing, non-homing
	-- bullets. For anything that curves or bounces these diverge significantly.
	return self.Length
end

function BulletContext.GetSnapshot(self: BulletContext): BulletSnapshot
	return {
		Id               = self.Id,
		Origin           = self.Origin,
		Direction        = self.Direction,
		Speed            = self.Speed,
		Position         = self.Position,
		Velocity         = self.Velocity,
		Alive            = self.Alive,
		Lifetime         = self:GetLifetime(),
		-- PathLength is the true accumulated path distance (bounces included).
		PathLength       = self.Length,
		-- DistanceTraveled is kept as an alias for PathLength for API compatibility.
		DistanceTraveled = self.Length,
		-- [6DOF] Angular state — nil when 6DOF is disabled.
		Orientation      = self.Orientation,
		AngularVelocity  = self.AngularVelocity,
		AngleOfAttack    = self.AngleOfAttack,
	}
end

function BulletContext.Terminate(self: BulletContext)
	if not self.Alive then return end
	self.Alive = false

	if self.__solverData and type(self.__solverData) == "table" then
		if self.__solverData.Terminate then
			self.__solverData.Terminate()
		end
		self.__solverData = nil
	end
end

-- ─── Internal ────────────────────────────────────────────────────────────────

function BulletContext._UpdateState(self: BulletContext, currentPos: Vector3?, velocity: Vector3?, length: number?, simTime: number?, orientation: CFrame?, angularVelocity: Vector3?, angleOfAttack: number?)
	if not self.Alive then return end
	if currentPos       then self.Position        = currentPos       end
	if velocity         then self.Velocity        = velocity         end
	if length           then self.Length           = length           end
	if simTime          then self.SimulationTime  = simTime          end
	-- [6DOF] Angular state — only written when 6DOF is active.
	if orientation      then self.Orientation      = orientation      end
	if angularVelocity  then self.AngularVelocity  = angularVelocity  end
	if angleOfAttack    then self.AngleOfAttack    = angleOfAttack    end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(BulletContext, {
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