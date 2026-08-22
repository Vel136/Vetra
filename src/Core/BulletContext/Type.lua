export type BulletContext = {
	Id         : number,

	Origin        : Vector3,
	Direction     : Vector3,
	Speed         : number,
	StartTime     : number,
	RaycastParams : RaycastParams?,

	Position       : Vector3?,
	Velocity       : Vector3,
	Alive          : boolean,
	Length         : number,
	SimulationTime : number,
	UserData : any,

	Orientation      : CFrame?,
	AngularVelocity  : Vector3?,
	AngleOfAttack    : number?,

	__solverData: any,

	IsAlive             : (self: BulletContext) -> boolean,
	GetLifetime         : (self: BulletContext) -> number,
	GetDistanceTraveled : (self: BulletContext) -> number,
	GetSnapshot         : (self: BulletContext) -> BulletSnapshot,
	Terminate           : (self: BulletContext) -> (),
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
	FireTravelEvents : boolean?,
	Speed         : number,
	Id            : number?,
	UserData      : any?,
	SolverData    : any?,
	RaycastParams : RaycastParams?,
}

return {
	BulletContext       = {} :: BulletContext,
	BulletSnapshot      = {} :: BulletSnapshot,
	HitData             = {} :: HitData,
	BulletContextConfig = {} :: BulletContextConfig,
}
