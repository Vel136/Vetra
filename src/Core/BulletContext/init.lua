--!strict
--!optimize 2
--!native

local BulletContextType = require(script.Type)

export type BulletSnapshot      = BulletContextType.BulletSnapshot
export type BulletContextConfig = BulletContextType.BulletContextConfig

local BulletContext  = {}

local _NextId = 0

local _LIVE_FIELDS: { [string]: (cast: any) -> any } = {
	Position        = function(cast) return cast:GetPosition() end,
	Velocity        = function(cast) return cast:GetVelocity() end,
	Length          = function(cast) return cast.Runtime.DistanceCovered end,
	SimulationTime  = function(cast) return cast.Runtime.TotalRuntime end,
	Orientation     = function(cast) return cast.Runtime.Orientation end,
	AngularVelocity = function(cast) return cast.Runtime.AngularVelocity end,
	AngleOfAttack   = function(cast) return cast.Runtime.AngleOfAttack end,
}

function BulletContext:IsAlive(): boolean
	return self.Alive
end

function BulletContext:_Freeze()
	local solverData = rawget(self, "__solverData")
	local cast = solverData and solverData.Cast
	for Field, Getter in _LIVE_FIELDS do
		if rawget(self, Field) == nil then
			rawset(self, Field, cast and Getter(cast) or nil)
		end
	end
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

	self:_Freeze()

	if self.__solverData and type(self.__solverData) == "table" then
		if self.__solverData.Terminate then
			self.__solverData.Terminate()
		end
		self.__solverData = nil
	end
end

local module = {}

local function _index(self: any, key: string)
	local Getter = _LIVE_FIELDS[key]
	if Getter then
		local solverData = rawget(self, "__solverData")
		local cast = solverData and solverData.Cast
		if cast then
			return Getter(cast)
		end

		return nil
	end
	return BulletContext[key]
end

local Metatable = { __index = _index }
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
	self.Alive     = true

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
