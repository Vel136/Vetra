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
	Origin     : Vector3,
	Direction  : Vector3,
	Speed      : number,
	StartTime  : number,

	-- Runtime state (mutated by solver each frame via _UpdateState)
	Position       : Vector3?,
	Velocity       : Vector3,
	Alive          : boolean,
	Length         : number,
	SimulationTime : number,
	UserData : any,
	-- Internal solver data (do not access from weapon code)
	__solverData: any,

	-- Methods
	IsAlive             : (self: BulletContext) -> boolean,
	GetLifetime         : (self: BulletContext) -> number,
	GetDistanceTraveled : (self: BulletContext) -> number,
	GetSnapshot         : (self: BulletContext) -> BulletSnapshot,
	Terminate           : (self: BulletContext) -> (),
	_UpdateState        : (self: BulletContext, position: Vector3?, velocity: Vector3?, length: number?, simTime: number?) -> (),
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
}

export type HitData = {
	Instance : BasePart,
	Position : Vector3,
	Normal   : Vector3,
	Material : Enum.Material,
	Distance : number,
}

export type BulletContextConfig = {
	Origin     : Vector3,
	Direction  : Vector3,
	Speed      : number,
	Id         : number?,
	SolverData : any?,
}

-- ─── Module ──────────────────────────────────────────────────────────────────

return {
	BulletContext       = {} :: BulletContext,
	BulletSnapshot      = {} :: BulletSnapshot,
	HitData             = {} :: HitData,
	BulletContextConfig = {} :: BulletContextConfig,
}