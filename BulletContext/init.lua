-- BulletContext.lua
--[[
	Solver-agnostic bullet runtime object.
	- Tracks bullet state and lifecycle without exposing solver internals
	- Updated by solvers each frame via _UpdateState
]]

local Identity = "BulletContext"

-- ─── Types ───────────────────────────────────────────────────────────────────

local BulletContextType = require(script.Type)

export type BulletContext       = BulletContextType.BulletContext
export type BulletSnapshot      = BulletContextType.BulletSnapshot
export type BulletContextConfig = BulletContextType.BulletContextConfig

-- ─── Module ──────────────────────────────────────────────────────────────────

local BulletContext   = {}
BulletContext.__index = BulletContext
BulletContext.__type  = Identity

-- ─── Private state ───────────────────────────────────────────────────────────

local _NextId = 0

-- ─── Constructor ─────────────────────────────────────────────────────────────

--- Creates a new BulletContext.
function BulletContext.new(config: BulletContextConfig): BulletContext
	assert(config.Origin,    "[BulletContext] Origin is required")
	assert(config.Direction, "[BulletContext] Direction is required")
	assert(config.Speed,     "[BulletContext] Speed is required")

	local self = setmetatable({}, BulletContext)

	-- Identity
	self.Id        = _NextId
	_NextId       += 1

	-- Immutable initial state
	self.Origin     = config.Origin
	self.Direction  = config.Direction
	self.Speed      = config.Speed
	self.Callbacks  = config.Callbacks
	self.StartTime  = os.clock()
	self.Bullet     = nil

	-- Runtime state (mutated by solver)
	self.Position   = nil
	self.Velocity   = self.Direction * self.Speed
	self.Alive      = true
	self.Length     = 0
	self.Trajectory = {}
	self.LastPoint  = nil

	-- Internal solver data (do not access from weapon code)
	self.__solverData = config.SolverData

	return self
end

-- ─── State API ───────────────────────────────────────────────────────────────

--- Returns whether the bullet is still alive.
function BulletContext.IsAlive(self: BulletContext): boolean
	return self.Alive
end

--- Returns the bullet's age in seconds.
function BulletContext.GetLifetime(self: BulletContext): number
	return os.clock() - self.StartTime
end

--- Returns the distance traveled from the origin.
function BulletContext.GetDistanceTraveled(self: BulletContext): number
	if not self.Position then return 0 end
	return (self.Position - self.Origin).Magnitude
end

--- Returns a read-only snapshot of the current bullet state.
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
		DistanceTraveled = self:GetDistanceTraveled(),
	}
end

--- Terminates the bullet and notifies the solver to clean up.
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

--- Updates bullet position, velocity, and length. Called by solvers only.
function BulletContext._UpdateState(self: BulletContext, currentPos: Vector3?, velocity: Vector3?, length: number?)
	if not self.Alive then return end
	if currentPos then self.Position = currentPos end
	if velocity   then self.Velocity = velocity   end
	if length     then self.Length   = length     end
end

return BulletContext