--!native
--!optimize 2
--!strict

-- ─── References ──────────────────────────────────────────────────────────────

local Core = script.Parent.Core

-- ─── Module References ───────────────────────────────────────────────────────

local VeSignal      = require(Core.VeSignal)
local BulletContext = require(Core.BulletContext)
local Enums         = require(Core.Enums)

-- ─── Local Aliases ───────────────────────────────────────────────────────────

type Signal<T>          = VeSignal.Signal<T>
type BulletContextPublic = BulletContext.BulletContext

-- ─── Cast ────────────────────────────────────────────────────────────────────

export type Cast = {
	Alive     : boolean,
	Paused    : boolean,
	StartTime : number,
	Id        : number,
	UserData  : { [any]: any },

	GetPosition         : (self: Cast) -> Vector3,
	GetVelocity         : (self: Cast) -> Vector3,
	GetAcceleration     : (self: Cast) -> Vector3,
	Pause               : (self: Cast) -> (),
	Resume              : (self: Cast) -> (),
	IsPaused            : (self: Cast) -> boolean,
	Terminate           : (self: Cast) -> (),
	SetPosition         : (self: Cast, pos: Vector3) -> (),
	SetVelocity         : (self: Cast, vel: Vector3) -> (),
	SetAcceleration     : (self: Cast, acc: Vector3) -> (),
	AddPosition         : (self: Cast, delta: Vector3) -> (),
	AddVelocity         : (self: Cast, delta: Vector3) -> (),
	AddAcceleration     : (self: Cast, delta: Vector3) -> (),
	ResetBounceState    : (self: Cast) -> (),
	ResetPierceState    : (self: Cast) -> (),
	GetOrientation      : (self: Cast) -> CFrame,
	GetAngularVelocity  : (self: Cast) -> Vector3,
	GetAngleOfAttack    : (self: Cast) -> number,
	SetOrientation      : (self: Cast, cf: CFrame) -> (),
	SetAngularVelocity  : (self: Cast, av: Vector3) -> (),
}

-- ─── TerminateReason ─────────────────────────────────────────────────────────

export type TerminateReason = Enums.TerminateReason

-- ─── Signals ─────────────────────────────────────────────────────────────────

export type Signals = {
	OnFire                  : Signal<(context: BulletContextPublic, behavior: any) -> ()>,
	OnHit                   : Signal<(context: BulletContextPublic, result: RaycastResult?, velocity: Vector3, impactForce: Vector3) -> ()>,
	OnTravel                : Signal<(context: BulletContextPublic, position: Vector3, velocity: Vector3) -> ()>,
	OnTravelBatch           : Signal<(batch: { { Context: BulletContextPublic, Position: Vector3, Velocity: Vector3 } }) -> ()>,
	OnPierce                : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, pierceCount: number) -> ()>,
	OnBounce                : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, bounceCount: number, bounceForce: Vector3) -> ()>,
	OnTerminated            : Signal<(context: BulletContextPublic) -> ()>,
	OnPreBounce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (normal: Vector3?, incomingVelocity: Vector3?) -> ()) -> ()>,
	OnMidBounce             : Signal<(context: BulletContextPublic, result: RaycastResult, postVelocity: Vector3, mutate: (postVelocity: Vector3?, restitution: number?, perturbation: number?) -> ()) -> ()>,
	OnPrePierce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (normal: Vector3?, velocity: Vector3?) -> ()) -> ()>,
	OnMidPierce             : Signal<(context: BulletContextPublic, result: RaycastResult, velocity: Vector3, mutate: (velocity: Vector3?) -> ()) -> ()>,
	OnSpeedThresholdCrossed : Signal<(context: BulletContextPublic, threshold: number, ascending: boolean, speed: number) -> ()>,
	OnPreTermination        : Signal<(context: BulletContextPublic, reason: TerminateReason, mutate: (cancelled: boolean, newReason: TerminateReason?) -> ()) -> ()>,
	OnSegmentOpen           : Signal<(context: BulletContextPublic, segment: any) -> ()>,
	OnBranchSpawned         : Signal<(parent: BulletContextPublic, child: BulletContextPublic) -> ()>,
	OnHomingDisengaged      : Signal<(context: BulletContextPublic) -> ()>,
	OnTumbleBegin           : Signal<(context: BulletContextPublic, velocity: Vector3) -> ()>,
	OnTumbleEnd             : Signal<(context: BulletContextPublic, velocity: Vector3) -> ()>,
}

-- ─── Solver ──────────────────────────────────────────────────────────────────

export type Solver = {
	Signals : Signals,

	Fire              : (self: Solver, context: BulletContextPublic, behavior: any?) -> Cast,
	GetSignals        : (self: Solver) -> Signals,
	Destroy           : (self: Solver) -> (),
	SetWind           : (self: Solver, wind: Vector3) -> (),
	SetLODOrigin      : (self: Solver, origin: Vector3?) -> (),
	SetInterestPoints : (self: Solver, points: { Vector3 }) -> (),
	SetCoriolisConfig : (self: Solver, latitude: number, scale: number) -> (),
}

-- ─── Module Return ───────────────────────────────────────────────────────────

return {}
