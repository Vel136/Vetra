--!strict
--!optimize 2
--!native


local DragModel = table.freeze({
	Quadratic   = 1,
	Linear      = 2,
	G1          = 4,
	G2          = 5,
	G3          = 6,
	G4          = 7,
	G5          = 8,
	G6          = 9,
	G7          = 10,
	G8          = 11,
	GL          = 12,
	Custom      = 13,
})

export type DragModel = number

local TerminateReason = table.freeze({
	Hit          = "hit",
	Distance     = "distance",
	Displacement = "displacement",
	Speed        = "speed",
	Manual       = "manual",
	CornerTrap   = "corner_trap",
})

export type TerminateReason = "hit"|"distance"|"displacement"|"speed"|"manual"|"corner_trap"

return table.freeze({
	DragModel       = DragModel,
	TerminateReason = TerminateReason,
})
