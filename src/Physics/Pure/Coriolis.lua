--!strict
--!optimize 2
--!native

local PureCoriolis   = {}

function PureCoriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	return -2 * omega:Cross(velocity)
end

return table.freeze(PureCoriolis)
