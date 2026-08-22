--!strict
--!optimize 2

local SessionStatus = table.freeze({
	Ready    = "ok",
	AtLimit  = "cap",
	Inactive = "inactive",
})

return table.freeze({
	SessionStatus    = SessionStatus,
	ValidationReason = ValidationReason,
})
