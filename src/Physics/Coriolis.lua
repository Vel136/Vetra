--!strict
--!optimize 2
--!native

local Coriolis  = {}

local EARTH_OMEGA_RADS = 7.2921e-5

function Coriolis.ComputeOmega(latitude: number, scale: number): Vector3
	if scale == 0 then
		return Vector3.zero
	end

	local phi   = math.rad(latitude)
	local omega = EARTH_OMEGA_RADS * scale

	return Vector3.new(
		0,
		omega * math.sin(phi),
		omega * math.cos(phi)
	)
end

function Coriolis.ComputeAcceleration(omega: Vector3, velocity: Vector3): Vector3
	return -2 * omega:Cross(velocity)
end

return table.freeze(Coriolis)
