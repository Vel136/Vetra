-- BulletContextType.lua
--[[
	Type definitions for BulletContext.
	Provides complete typing for solver-agnostic bullet objects.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── References ──────────────────────────────────────────────────────────────

local Utilities = ReplicatedStorage.Shared.Modules.Utilities

-- ─── Modules ─────────────────────────────────────────────────────────────────

local FastCast = require(Utilities.FastCastRedux)

-- ─── Types ───────────────────────────────────────────────────────────────────

export type BulletContext = {
	-- Identity
	Id         : number,

	-- Immutable initial state
	Origin     : Vector3,
	Direction  : Vector3,
	Speed      : number,
	StartTime  : number,
	Callbacks  : BulletCallbacks?,

	-- Runtime state (mutated by solver)
	Position   : Vector3?,
	Velocity   : Vector3,
	Alive      : boolean,
	Length     : number,
	Trajectory : { Vector3 },
	LastPoint  : Vector3?,
	Bullet     : Instance?,

	-- Internal solver data (do not access from weapon code)
	__solverData: {
		Cast      : FastCast.ActiveCast?,
		Terminate : (() -> ())?,
	}?,

	-- Methods
	IsAlive             : (self: BulletContext) -> boolean,
	GetLifetime         : (self: BulletContext) -> number,
	GetDistanceTraveled : (self: BulletContext) -> number,
	GetSnapshot         : (self: BulletContext) -> BulletSnapshot,
	Terminate           : (self: BulletContext) -> (),
	_UpdateState        : (self: BulletContext, position: Vector3?, velocity: Vector3?, length: number?) -> (),
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
	DistanceTraveled : number,
}

export type BulletCallbacks = {
	OnHit           : ((ctx: BulletContext, hitData: HitData) -> ())?,
	OnLengthChanged : ((ctx: BulletContext, position: Vector3) -> ())?,
	OnTerminating   : ((ctx: BulletContext) -> ())?,
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
	Callbacks  : BulletCallbacks?,
	SolverData : any?,
}

-- ─── Module ──────────────────────────────────────────────────────────────────

return {
	BulletContext       = {} :: BulletContext,
	BulletSnapshot      = {} :: BulletSnapshot,
	BulletCallbacks     = {} :: BulletCallbacks,
	HitData             = {} :: HitData,
	BulletContextConfig = {} :: BulletContextConfig,
}