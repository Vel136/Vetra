--!strict
--Config.lua
--!native
--!optimize 2

--[[
    MIT License
    Copyright (c) 2026 VeDevelopment

    VetraNet/Core/Config.lua
    Resolves the consumer-supplied NetworkConfig against Constants defaults.

    All validation runs at construction time rather than lazily during the frame
    loop. This means a misconfigured VetraNet instance errors loudly at startup
    rather than silently misbehaving mid-match when a bullet hits an edge case.
    After construction the resolved config is frozen — no module may mutate it.
]]

local Identity = "Config"

local Config   = {}
Config.__type  = Identity

local ConfigMetatable = table.freeze({
	__index = Config,
})

-- ─── References ──────────────────────────────────────────────────────────────

local Types = script.Parent.Parent.Types

-- ─── Module References ───────────────────────────────────────────────────────

local Constants  = require(Types.Constants)
local LogService = require(script.Parent.Logger)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, true)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local table_freeze  = table.freeze
local string_format = string.format

-- ─── Types ───────────────────────────────────────────────────────────────────

export type ResolvedConfig = {
	MaxOriginTolerance     : number,
	MaxConcurrentPerPlayer : number,
	TokensPerSecond        : number,
	BurstLimit             : number,
	DriftThreshold         : number,
	CorrectionRate         : number,
	LatencyBuffer          : number,
	ReplicateState         : boolean,
}

-- ─── Factory ─────────────────────────────────────────────────────────────────

-- Resolve a consumer-supplied config table against module defaults.
-- Every field in the returned table is a concrete number — no optionals leak
-- past this boundary. Downstream modules can read without nil-checks.
function Config.Resolve(RawConfig: any?): ResolvedConfig
	local Raw = RawConfig or {}

	-- Validate types for provided fields. Passing a string where a number is
	-- expected is caught here rather than producing a confusing arithmetic error
	-- somewhere inside the frame loop.
	local function ValidateNumber(Field: string, Value: any): boolean
		if Value ~= nil and type(Value) ~= "number" then
			Logger:Warn(string_format(
				"Config.Resolve: field '%s' must be a number, got %s — using default",
				Field, typeof(Value)
				))
			return false
		end
		return true
	end

	local MaxOriginTolerance     = ValidateNumber("MaxOriginTolerance",     Raw.MaxOriginTolerance)     and Raw.MaxOriginTolerance     or Constants.DEFAULT_MAX_ORIGIN_TOLERANCE
	local MaxConcurrentPerPlayer = ValidateNumber("MaxConcurrentPerPlayer", Raw.MaxConcurrentPerPlayer) and Raw.MaxConcurrentPerPlayer or Constants.DEFAULT_MAX_CONCURRENT_PER_PLAYER
	local TokensPerSecond        = ValidateNumber("TokensPerSecond",        Raw.TokensPerSecond)        and Raw.TokensPerSecond        or Constants.DEFAULT_TOKENS_PER_SECOND
	local BurstLimit             = ValidateNumber("BurstLimit",             Raw.BurstLimit)             and Raw.BurstLimit             or Constants.DEFAULT_BURST_LIMIT
	local DriftThreshold         = ValidateNumber("DriftThreshold",         Raw.DriftThreshold)         and Raw.DriftThreshold         or Constants.DEFAULT_DRIFT_THRESHOLD
	local CorrectionRate         = ValidateNumber("CorrectionRate",         Raw.CorrectionRate)         and Raw.CorrectionRate         or Constants.DEFAULT_CORRECTION_RATE
	local LatencyBuffer          = ValidateNumber("LatencyBuffer",          Raw.LatencyBuffer)          and Raw.LatencyBuffer          or 0

	-- ReplicateState is boolean — validate separately from numbers.
	local ReplicateState = Constants.DEFAULT_REPLICATE_STATE
	if Raw.ReplicateState ~= nil then
		if type(Raw.ReplicateState) ~= "boolean" then
			Logger:Warn("Config.Resolve: field 'ReplicateState' must be a boolean — using default")
		else
			ReplicateState = Raw.ReplicateState
		end
	end

	-- Range checks on resolved values. These fire after the type check so the
	-- error message always describes a numeric boundary violation, not a type error.
	if MaxOriginTolerance <= 0 then
		Logger:Warn("Config: MaxOriginTolerance must be > 0 — clamping to default")
		MaxOriginTolerance = Constants.DEFAULT_MAX_ORIGIN_TOLERANCE
	end
	if MaxConcurrentPerPlayer < 1 then
		Logger:Warn("Config: MaxConcurrentPerPlayer must be >= 1 — clamping to default")
		MaxConcurrentPerPlayer = Constants.DEFAULT_MAX_CONCURRENT_PER_PLAYER
	end
	if TokensPerSecond <= 0 then
		Logger:Warn("Config: TokensPerSecond must be > 0 — clamping to default")
		TokensPerSecond = Constants.DEFAULT_TOKENS_PER_SECOND
	end
	if BurstLimit < TokensPerSecond then
		-- A burst limit below the per-second rate makes the token bucket
		-- permanently starved — every refill immediately saturates the cap.
		Logger:Warn("Config: BurstLimit should be >= TokensPerSecond — clamping")
		BurstLimit = TokensPerSecond
	end
	if DriftThreshold < 0 then
		Logger:Warn("Config: DriftThreshold must be >= 0 — clamping to 0")
		DriftThreshold = 0
	end
	if CorrectionRate <= 0 then
		Logger:Warn("Config: CorrectionRate must be > 0 — clamping to default")
		CorrectionRate = Constants.DEFAULT_CORRECTION_RATE
	end
	if LatencyBuffer < 0 then
		Logger:Warn("Config: LatencyBuffer must be >= 0 — clamping to 0")
		LatencyBuffer = 0
	end

	return table_freeze({
		MaxOriginTolerance     = MaxOriginTolerance,
		MaxConcurrentPerPlayer = MaxConcurrentPerPlayer,
		TokensPerSecond        = TokensPerSecond,
		BurstLimit             = BurstLimit,
		DriftThreshold         = DriftThreshold,
		CorrectionRate         = CorrectionRate,
		LatencyBuffer          = LatencyBuffer,
		ReplicateState         = ReplicateState,
	})
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze(setmetatable(Config, {
	__index = function(_, Key)
		Logger:Warn(string_format("Config: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, _Value)
		Logger:Error(string_format("Config: write to protected key '%s'", tostring(Key)))
	end,
}))
