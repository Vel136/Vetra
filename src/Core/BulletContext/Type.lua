-- BulletContextType.lua
--[[
	Type definitions for BulletContext.
	Provides complete typing for solver-agnostic bullet objects.
]]

-- ─── Types ───────────────────────────────────────────────────────────────────

export type BulletContext = {
	-- Identity
	Id         : number,

	-- Immutable initial state
	Origin        : Vector3,
	Direction     : Vector3,
	Speed         : number,
	StartTime     : number,
	RaycastParams : RaycastParams?,

	-- Runtime state (mutated by solver each frame via _UpdateState)
	Position       : Vector3?,
	Velocity       : Vector3,
	Alive          : boolean,
	Length         : number,
	SimulationTime : number,
	UserData : any,

	-- [6DOF] Angular state — nil when 6DOF is disabled.
	Orientation      : CFrame?,
	AngularVelocity  : Vector3?,
	AngleOfAttack    : number?,

	-- Internal solver data (do not access from weapon code)
	__solverData: any,

	-- Methods
	IsAlive             : (self: BulletContext) -> boolean,
	GetLifetime         : (self: BulletContext) -> number,
	GetDistanceTraveled : (self: BulletContext) -> number,
	GetSnapshot         : (self: BulletContext) -> BulletSnapshot,
	Terminate           : (self: BulletContext) -> (),
	_UpdateState        : (self: BulletContext, position: Vector3?, velocity: Vector3?, length: number?, simTime: number?, orientation: CFrame?, angularVelocity: Vector3?, angleOfAttack: number?) -> (),
}

export type BulletSnapshot = {
	Id               : number,
	Origin           : Vector3,
	Direction        : Vector3,
	Speed            : number,
	Position         : Vector3?,
	Velocity         : Vector3,
	Alive            : boolean,
	Lifetime         : number,
	PathLength       : number,
	DistanceTraveled : number,
	-- [6DOF] Angular state — nil when 6DOF is disabled.
	Orientation      : CFrame?,
	AngularVelocity  : Vector3?,
	AngleOfAttack    : number?,
}

export type HitData = {
	Instance : BasePart,
	Position : Vector3,
	Normal   : Vector3,
	Material : Enum.Material,
	Distance : number,
}

export type BulletContextConfig = {
	Origin        : Vector3,
	Direction     : Vector3,
	FireTravelEvents	  : boolean?,
	Speed         : number,
	Id            : number?,
	SolverData    : any?,
	RaycastParams : RaycastParams?,
}

-- ─── Module ──────────────────────────────────────────────────────────────────

return {
	BulletContext       = {} :: BulletContext,
	BulletSnapshot      = {} :: BulletSnapshot,
	HitData             = {} :: HitData,
	BulletContextConfig = {} :: BulletContextConfig,
}