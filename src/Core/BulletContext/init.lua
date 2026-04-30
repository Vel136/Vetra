--!native
--!optimize 2
--!strict

-- ─── BulletContext ───────────────────────────────────────────────────────────

local LogService        = require(script.Parent.Logger)
local BulletContextType = require(script.Type)

local Logger = LogService.new("BulletContext", true)


export type BulletSnapshot      = BulletContextType.BulletSnapshot
export type BulletContextConfig = BulletContextType.BulletContextConfig

-- ─── Class ───────────────────────────────────────────────────────────────────

local BulletContext  = {}
local Metatable      = { __index = BulletContext }
BulletContext.__type = "BulletContext"

-- ─── Private State ───────────────────────────────────────────────────────────

local _NextId = 0

-- ─── State API ───────────────────────────────────────────────────────────────

function BulletContext:IsAlive(): boolean
	return self.Alive
end

function BulletContext:GetLifetime(): number
	return self.SimulationTime
end

function BulletContext:GetDistanceTraveled(): number
	return self.Length
end

function BulletContext:GetSnapshot(): BulletSnapshot
	return {
		Id               = self.Id,
		Origin           = self.Origin,
		Direction        = self.Direction,
		Speed            = self.Speed,
		Position         = self.Position,
		Velocity         = self.Velocity,
		Alive            = self.Alive,
		Lifetime         = self:GetLifetime(),
		PathLength       = self.Length,
		DistanceTraveled = self.Length,
		Orientation      = self.Orientation,
		AngularVelocity  = self.AngularVelocity,
		AngleOfAttack    = self.AngleOfAttack,
	}
end

function BulletContext:GetCast(): any
	return self.__solverData and self.__solverData.Cast
end

function BulletContext:Terminate()
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

function BulletContext:_UpdateState(
	currentPos:      Vector3?,
	velocity:        Vector3?,
	length:          number?,
	simTime:         number?,
	orientation:     CFrame?,
	angularVelocity: Vector3?,
	angleOfAttack:   number?
)
	if not self.Alive then return end
	if currentPos      then self.Position       = currentPos      end
	if velocity        then self.Velocity       = velocity        end
	if length          then self.Length         = length          end
	if simTime         then self.SimulationTime = simTime         end
	if orientation     then self.Orientation    = orientation     end
	if angularVelocity then self.AngularVelocity = angularVelocity end
	if angleOfAttack   then self.AngleOfAttack  = angleOfAttack   end
end

-- ─── Module ──────────────────────────────────────────────────────────────────

local module = {}

function module.new(config: BulletContextConfig): BulletContext
	assert(config.Origin,    "[BulletContext] Origin is required")
	assert(config.Direction, "[BulletContext] Direction is required")
	assert(config.Speed,     "[BulletContext] Speed is required")

	local self = setmetatable({}, Metatable)

	self.Id        = _NextId
	_NextId       += 1

	self.Origin        = config.Origin
	self.Direction     = config.Direction
	self.Speed         = config.Speed
	self.RaycastParams = config.RaycastParams or false

	self.StartTime      = os.clock()
	self.SimulationTime = os.clock()

	self.Position  = false
	self.Velocity  = self.Direction * self.Speed
	self.Alive     = true
	self.Length    = 0

	self.Orientation     = false :: any
	self.AngularVelocity = false :: any
	self.AngleOfAttack   = false :: any

	self.__solverData         = config.SolverData or {}
	self.UserData             = config.UserData or {}
	self.CosmeticBulletObject = false :: any

	return self :: BulletContext
end

export type BulletContext = typeof(setmetatable({}, Metatable)) & {
	Id                  : number,
	Origin              : Vector3,
	Direction           : Vector3,
	Speed               : number,
	RaycastParams       : RaycastParams | boolean,
	StartTime           : number,
	SimulationTime      : number,
	Position            : Vector3 | boolean,
	Velocity            : Vector3,
	Alive               : boolean,
	Length              : number,
	Orientation         : CFrame | boolean,
	AngularVelocity     : Vector3 | boolean,
	AngleOfAttack       : number | boolean,
	UserData            : { [string]: any },
	CosmeticBulletObject: any,
}

return table.freeze(module)