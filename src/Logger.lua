--[=[
    @class Logger
    An improved logging utility with enhanced features, formatting, and performance.
]=]

--[=[
    @within Logger
    @type LogLevel "TRACE" | "DEBUG" | "INFO" | "WARN" | "ERROR" | "FATAL"
]=]
export type LogLevel = "TRACE" | "DEBUG" | "INFO" | "WARN" | "ERROR" | "FATAL"

--[=[
    @within Logger
    @interface LoggerConfig
    @field moduleName string -- Name of the module using this logger
    @field minLevel LogLevel? -- Minimum log level to display (default: "INFO")
    @field includeTimestamp boolean? -- Whether to include timestamps (default: true)
    @field includeStackTrace boolean? -- Whether to include stack traces for errors (default: true)
    @field prefix string? -- Custom prefix for log messages
    @field outputFunction ((message: string) -> ())? -- Custom output function
    @field isEnabled boolean? -- Whether logging is enabled (default: true)
]=]
export type LoggerConfig = {
	moduleName: string,
	minLevel: LogLevel?,
	includeTimestamp: boolean?,
	includeStackTrace: boolean?,
	prefix: string?,
	outputFunction: ((message: string) -> ())?,
	isEnabled: boolean?,
}

--[=[
    @within Logger
    @interface LoggerArguments
    @field _moduleName string
    @field _minLevel LogLevel
    @field _includeTimestamp boolean
    @field _includeStackTrace boolean
    @field _prefix string
    @field _outputFunction ((message: string) -> ())?
    @field _isEnabled boolean
    @field _isDestroyed boolean
]=]
export type LoggerArguments = {
	_moduleName: string,
	_minLevel: LogLevel,
	_includeTimestamp: boolean,
	_includeStackTrace: boolean,
	_prefix: string,
	_outputFunction: ((message: string) -> ())?,
	_isEnabled: boolean,
	_isDestroyed: boolean,
}

--[=[
    @within Logger
    @interface Object
    @field __index Object
    @field new (config: LoggerConfig | string) -> Logger
    @field Log (self: Logger, level: LogLevel, message: string, ...any) -> ()
    @field Trace (self: Logger, message: string, ...any) -> ()
    @field Debug (self: Logger, message: string, ...any) -> ()
    @field Info (self: Logger, message: string, ...any) -> ()
    @field Warn (self: Logger, message: string, ...any) -> ()
    @field Error (self: Logger, message: string, ...any) -> ()
    @field Fatal (self: Logger, message: string, ...any) -> ()
    @field SetLevel (self: Logger, level: LogLevel) -> ()
    @field GetLevel (self: Logger) -> LogLevel
    @field SetEnabled (self: Logger, enabled: boolean) -> ()
    @field GetEnabled (self: Logger) -> boolean
    @field IsEnabled (self: Logger, level: LogLevel) -> boolean
    @field Destroy (self: Logger) -> ()
]=]
type Object = {
	__index: Object,
	new: (config: LoggerConfig | string) -> Logger,
	Log: (self: Logger, level: LogLevel, message: string, ...any) -> (),
	Trace: (self: Logger, message: string, ...any) -> (),
	Debug: (self: Logger, message: string, ...any) -> (),
	Info: (self: Logger, message: string, ...any) -> (),
	Warn: (self: Logger, message: string, ...any) -> (),
	Error: (self: Logger, message: string, ...any) -> (),
	Fatal: (self: Logger, message: string, ...any) -> (),
	SetLevel: (self: Logger, level: LogLevel) -> (),
	GetLevel: (self: Logger) -> LogLevel,
	SetEnabled: (self: Logger, enabled: boolean) -> (),
	GetEnabled: (self: Logger) -> boolean,
	IsEnabled: (self: Logger, level: LogLevel) -> boolean,
	Destroy: (self: Logger) -> (),
}

--[=[
    @within Logger
    @type Logger () -> Logger
]=]
export type Logger = typeof(setmetatable({} :: LoggerArguments, {} :: Object))

local Logger: Object = {} :: Object
Logger.__index = Logger

-- Constants
local LOG_LEVELS = {
	TRACE = 1,
	DEBUG = 2,
	INFO = 3,
	WARN = 4,
	ERROR = 5,
	FATAL = 6,
}

local RunService = game:GetService("RunService")
local IsStudio = RunService:IsStudio()
local IsServer = RunService:IsServer()

--[=[
    Formats a timestamp for log messages.
    @private
    @return string
]=]
local function formatTimestamp(): string
	local now = DateTime.now()
	return now:FormatLocalTime("HH:mm:ss.SSS", "en-us")
end

--[=[
    Formats additional arguments for logging.
    @private
    @param ... any
    @return string
]=]
local function formatArgs(...: any): string
	local args = {...}
	if #args == 0 then
		return ""
	end

	local formatted = {}
	for i, arg in ipairs(args) do
		local argType = typeof(arg)
		if argType == "table" then
			formatted[i] = game:GetService("HttpService"):JSONEncode(arg)
		elseif argType == "Instance" then
			formatted[i] = arg:GetFullName()
		else
			formatted[i] = tostring(arg)
		end
	end

	return " | " .. table.concat(formatted, ", ")
end

--[=[
    Gets the stack trace for error logging.
    @private
    @return string
]=]
local function getStackTrace(): string
	local trace = debug.traceback("", 4)
	return "\nStack trace:\n" .. trace
end

--[=[
    @param config LoggerConfig | string
    @return Logger
    
    Constructs a new Logger with the given configuration.
    If a string is passed, it will be used as the module name with default settings.
    
    ```lua
    -- Simple usage
    local logger = Logger.new("MyModule")
    
    -- Advanced usage
    local logger = Logger.new({
        moduleName = "MyModule",
        minLevel = "DEBUG",
        includeTimestamp = true,
        includeStackTrace = true,
        prefix = "[GAME]"
    })
    ```
]=]
function Logger.new(config: LoggerConfig | string, IsEnabled: boolean?)
	local self = {} :: LoggerArguments

	-- Handle string or config table
	if typeof(config) == "string" then
		self._moduleName = config
		self._minLevel = IsStudio and "DEBUG" or "INFO"
		self._includeTimestamp = false
		self._includeStackTrace = false
		self._prefix = ""
		self._outputFunction = nil
		self._isEnabled = if IsEnabled ~= nil then IsEnabled else true  -- Default to true
	else
		self._moduleName = config.moduleName
		self._minLevel = config.minLevel or (IsStudio and "DEBUG" or "INFO")
		self._includeTimestamp = if config.includeTimestamp ~= nil then config.includeTimestamp else true
		self._includeStackTrace = if config.includeStackTrace ~= nil then config.includeStackTrace else true
		self._prefix = config.prefix or ""
		self._outputFunction = config.outputFunction
		self._isEnabled = if config.isEnabled ~= nil then config.isEnabled else true  -- Default to true
	end

	self._isDestroyed = false
	return setmetatable(self, Logger) :: Logger
end

--[=[
    @param level LogLevel
    @param message string
    @param ... any
    @return nil
    
    Logs a message at the specified level with optional additional arguments.
    Additional arguments will be formatted and appended to the message.
]=]
function Logger:Log(level: LogLevel, message: string, ...: any)
	-- Check if logger is destroyed
	if self._isDestroyed then
		warn("[Logger] Attempted to use destroyed logger")
		return
	end

	-- Check if logging is enabled
	if not self._isEnabled then
		return
	end

	-- Check if this level should be logged
	if not self:IsEnabled(level) then
		return
	end

	-- Build the log message
	local parts = {}

	-- Add timestamp
	if self._includeTimestamp then
		table.insert(parts, string.format("[%s]", formatTimestamp()))
	end

	-- Add prefix if exists
	if self._prefix ~= "" then
		table.insert(parts, self._prefix)
	end

	-- Add level
	table.insert(parts, string.format("[%s]", level))

	-- Add module name
	table.insert(parts, string.format("[%s]", self._moduleName))

	-- Add server/client indicator
	table.insert(parts, IsServer and "[SERVER]" or "[CLIENT]")

	-- Build final message
	local logMessage = table.concat(parts, " ") .. " " .. message

	-- Add formatted arguments
	local args = formatArgs(...)
	if args ~= "" then
		logMessage = logMessage .. args
	end

	-- Add stack trace for errors and fatal
	if self._includeStackTrace and (level == "ERROR" or level == "FATAL") then
		logMessage = logMessage .. getStackTrace()
	end

	-- Output the message
	if self._outputFunction then
		self._outputFunction(logMessage)
	else
		if level == "WARN" then
			warn(logMessage)
		elseif level == "ERROR" or level == "FATAL" then
			error(logMessage, 0)
		else
			print(logMessage)
		end
	end
end

--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs a trace message (lowest priority, most verbose).
    Only shown in Studio by default.
]=]
function Logger:Trace(message: string, ...: any)
	self:Log("TRACE", message, ...)
end

--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs a debug message.
    Only shown in Studio by default.
]=]
function Logger:Debug(message: string, ...: any)
	self:Log("DEBUG", message, ...)
end

--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs an info message (normal priority).
]=]
function Logger:Info(message: string, ...: any)
	self:Log("INFO", message, ...)
end

function Logger:Print(message: string, ...: any)
	self:Log("INFO", message, ...)
end
--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs a warning message.
]=]
function Logger:Warn(message: string, ...: any)
	self:Log("WARN", message, ...)
end

--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs an error message with stack trace.
]=]
function Logger:Error(message: string, ...: any)
	self:Log("ERROR", message, ...)
end

--[=[
    @param message string
    @param ... any
    @return nil
    
    Logs a fatal error message (highest priority).
    Use for critical errors that require immediate attention.
]=]
function Logger:Fatal(message: string, ...: any)
	self:Log("FATAL", message, ...)
end

--[=[
    @param level LogLevel
    @return nil
    
    Sets the minimum log level for this logger.
    Messages below this level will not be displayed.
]=]
function Logger:SetLevel(level: LogLevel)
	assert(LOG_LEVELS[level], "Invalid log level: " .. tostring(level))
	self._minLevel = level
end

--[=[
    @return LogLevel
    
    Gets the current minimum log level.
]=]
function Logger:GetLevel(): LogLevel
	return self._minLevel
end

--[=[
    @param level LogLevel
    @return boolean
    
    Checks if a given log level is enabled for this logger.
]=]
function Logger:IsEnabled(level: LogLevel): boolean
	return LOG_LEVELS[level] >= LOG_LEVELS[self._minLevel]
end

--[=[
    @param enabled boolean
    @return nil
    
    Enables or disables all logging output.
    When disabled, all log calls are silently ignored.
]=]
function Logger:SetEnabled(enabled: boolean)
	self._isEnabled = enabled
end

--[=[
    @return boolean
    
    Returns whether logging is currently enabled.
]=]
function Logger:GetEnabled(): boolean
	return self._isEnabled
end

--[=[
    @return nil
    
    Destroys the logger and prevents further use.
    Attempting to log after destruction will produce a warning.
]=]
function Logger:Destroy()
	self._isDestroyed = true
	setmetatable(self, nil)
end

-- Export with backwards compatibility methods
return table.freeze({
	new = Logger.new,
	Log = Logger.Log,
	Trace = Logger.Trace,
	Debug = Logger.Debug,
	Info = Logger.Info,
	Warn = Logger.Warn,
	Error = Logger.Error,
	Fatal = Logger.Fatal,
	SetLevel = Logger.SetLevel,
	GetLevel = Logger.GetLevel,
	SetEnabled = Logger.SetEnabled,
	GetEnabled = Logger.GetEnabled,
	IsEnabled = Logger.IsEnabled,
	Destroy = Logger.Destroy,

	-- Backwards compatibility (deprecated)
	Print = Logger.Info,
})