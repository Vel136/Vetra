--!strict
--!optimize 2
--!native

local Config  = {}
Config.__index = Config

local Types = script.Parent.Parent.Types

local Constants = require(Types.Constants)

local table_freeze  = table.freeze
local string_format = string.format

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

function Config.Resolve(RawConfig: any?): ResolvedConfig
	local Raw = RawConfig or {}

	local function ValidateNumber(Field: string, Value: any): boolean
		if Value ~= nil and type(Value) ~= "number" then
			warn(string_format("Config.Resolve: '%s' must be number, got %s — using default", Field, typeof(Value)))
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

	local ReplicateState = Constants.DEFAULT_REPLICATE_STATE
	if Raw.ReplicateState ~= nil then
		if type(Raw.ReplicateState) ~= "boolean" then
			warn("Config.Resolve: 'ReplicateState' must be boolean — using default")
		else
			ReplicateState = Raw.ReplicateState
		end
	end

	if MaxOriginTolerance <= 0 then
		warn("Config: MaxOriginTolerance must be > 0 — clamping to default")
		MaxOriginTolerance = Constants.DEFAULT_MAX_ORIGIN_TOLERANCE
	end
	if MaxConcurrentPerPlayer < 1 then
		warn("Config: MaxConcurrentPerPlayer must be >= 1 — clamping to default")
		MaxConcurrentPerPlayer = Constants.DEFAULT_MAX_CONCURRENT_PER_PLAYER
	end
	if TokensPerSecond <= 0 then
		warn("Config: TokensPerSecond must be > 0 — clamping to default")
		TokensPerSecond = Constants.DEFAULT_TOKENS_PER_SECOND
	end
	if BurstLimit < TokensPerSecond then
		warn("Config: BurstLimit should be >= TokensPerSecond — clamping")
		BurstLimit = TokensPerSecond
	end
	if DriftThreshold < 0 then
		warn("Config: DriftThreshold must be >= 0 — clamping to 0")
		DriftThreshold = 0
	end
	if CorrectionRate <= 0 then
		warn("Config: CorrectionRate must be > 0 — clamping to default")
		CorrectionRate = Constants.DEFAULT_CORRECTION_RATE
	end
	if LatencyBuffer < 0 then
		warn("Config: LatencyBuffer must be >= 0 — clamping to 0")
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

return table.freeze(Config)
