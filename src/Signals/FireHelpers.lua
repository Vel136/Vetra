--!strict
--!optimize 2
--!native

local FireHelpers = {}

function FireHelpers.FireOnHit(Solver: any, Cast: any, HitResult: RaycastResult?, HitVelocity: Vector3)
	if not Solver.Signals.OnHit:HasListeners() then return end

	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end

	local BulletMass   = Cast.Behavior.BulletMass
	local ImpactForce  = (BulletMass and BulletMass > 0)
		and (HitVelocity * BulletMass)
		or Vector3.zero

	Solver.Signals.OnHit:Fire(Context, HitResult, HitVelocity, ImpactForce)
end

function FireHelpers.FireOnTravel(Solver: any, Cast: any, Position: Vector3, Velocity: Vector3)
	if not Cast.Behavior.FireTravelEvents then
		return
	end

	local Batching = Cast.Behavior.BatchTravel
	local Target   = if Batching then Solver.Signals.OnTravelBatch else Solver.Signals.OnTravel
	if not Target:HasListeners() then
		return
	end

	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end

	if Batching then
		local Batch = Solver._TravelBatch
		Batch[#Batch + 1] = {
			Context  = Context,
			Position = Position,
			Velocity = Velocity,
		}
	else
		Solver.Signals.OnTravel:Fire(Context, Position, Velocity)
	end
end

function FireHelpers.FlushTravelBatch(Solver: any)
	local Batch = Solver._TravelBatch
	if #Batch == 0 then return end
	Solver.Signals.OnTravelBatch:Fire(Batch)
	table.clear(Batch)
end

function FireHelpers.FireOnPierce(Solver: any, Cast: any, Result: RaycastResult, Velocity: Vector3)
	if not Solver.Signals.OnPierce:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnPierce:Fire(Context, Result, Velocity, Cast.Runtime.PierceCount)
end

function FireHelpers.FireOnBounce(Solver: any, Cast: any, Result: RaycastResult, PostVelocity: Vector3, PreVelocity: Vector3)
	if not Solver.Signals.OnBounce:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end

	local BulletMass   = Cast.Behavior.BulletMass
	local BounceForce  = (BulletMass and BulletMass > 0)
		and ((PreVelocity - PostVelocity) * BulletMass)
		or Vector3.zero

	Solver.Signals.OnBounce:Fire(Context, Result, PostVelocity, Cast.Runtime.BounceCount, BounceForce)
end

function FireHelpers.FireOnTerminated(Solver: any, Cast: any, Reason: string?)
	if not Solver.Signals.OnTerminated:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTerminated:Fire(Context, Reason)
end

function FireHelpers.FireOnSegmentOpen(Solver: any, Cast: any, Segment: any)
	if not Solver.Signals.OnSegmentOpen:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnSegmentOpen:Fire(Context, Segment)
end

function FireHelpers.FireOnSpeedThresholdCrossed(Solver: any, Cast: any, Threshold: number, IsAscending: boolean, Speed: number)
	if not Solver.Signals.OnSpeedThresholdCrossed:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnSpeedThresholdCrossed:Fire(Context, Threshold, IsAscending, Speed)
end

function FireHelpers.FireOnBranchSpawned(Solver: any, ParentContext: any, ChildContext: any)
	if not ParentContext then return end
	if not Solver.Signals.OnBranchSpawned:HasListeners() then return end
	Solver.Signals.OnBranchSpawned:Fire(ParentContext, ChildContext)
end

function FireHelpers.FireOnHomingDisengaged(Solver: any, Cast: any)
	if not Solver.Signals.OnHomingDisengaged:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnHomingDisengaged:Fire(Context)
end

function FireHelpers.FireOnTumbleBegin(Solver: any, Cast: any, Velocity: Vector3)
	if not Solver.Signals.OnTumbleBegin:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTumbleBegin:Fire(Context, Velocity)
end

function FireHelpers.FireOnTumbleEnd(Solver: any, Cast: any, Velocity: Vector3)
	if not Solver.Signals.OnTumbleEnd:HasListeners() then return end
	local Context = Solver._CastToBulletContext[Cast]
	if not Context then return end
	Solver.Signals.OnTumbleEnd:Fire(Context, Velocity)
end

return table.freeze(FireHelpers)
