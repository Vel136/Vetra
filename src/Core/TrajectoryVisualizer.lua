--!native
--!optimize 2
--!strict

-- ─── TrajectoryVisualizer ────────────────────────────────────────────────────
--[[
    Debug visualization for Vetra.

    Renders cast segments, impact points, velocity vectors, surface normals,
    and corner trap markers as temporary HandleAdornments in the world.

    ⚠️  Every method allocates a new Instance. Always verify VisualizeCasts = false
        before shipping to production.
]]

-- ─── Services ────────────────────────────────────────────────────────────────

local Debris     = game:GetService("Debris")
local RunService = game:GetService("RunService")

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(script.Parent.Logger)
local Constants          = require(script.Parent.Constants)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new("TrajectoryVisualizer", true)

-- ─── Constants ───────────────────────────────────────────────────────────────

local IS_SERVER          = RunService:IsServer()
local VISUALIZER_HIT_TYPE = Constants.VISUALIZER_HIT_TYPE

-- ─── Cached Globals ──────────────────────────────────────────────────────────

local instance_new      = Instance.new
local Terrain = workspace.Terrain

-- ─── Folder Management ───────────────────────────────────────────────────────

local _folder: Folder? = nil

local function GetFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end

	local existing = Terrain:FindFirstChild(Constants.VISUALIZER_FOLDER_NAME)
	if existing then
		_folder = existing :: Folder
		return _folder
	end

	local folder      = instance_new("Folder")
	folder.Name       = Constants.VISUALIZER_FOLDER_NAME
	folder.Archivable = false
	folder.Parent     = Terrain

	_folder = folder
	return folder
end

-- ─── Lifetime Management ─────────────────────────────────────────────────────

local function ScheduleDestroy(instance: Instance, lifetime: number?)
	--Debris:AddItem(instance, lifetime or Constants.VISUALIZER_LIFETIME)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local Visualizer = {}

function Visualizer.Segment(origin: CFrame, length: number, lifetime: number?)
	local a        = instance_new("ConeHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = origin
	a.Height       = length
	a.Radius       = 0.15
	a.Transparency = 0.4
	a.Color3       = IS_SERVER and Constants.COLOR_SEGMENT_SERVER or Constants.COLOR_SEGMENT_CLIENT
	a.AlwaysOnTop  = false
	a.Parent       = GetFolder()
	ScheduleDestroy(a, lifetime)
	return a
end

function Visualizer.Hit(cf: CFrame, hitType: "terminal" | "bounce" | "pierce", lifetime: number?)
	local color: Color3
	if hitType == VISUALIZER_HIT_TYPE.Bounce then
		color = Constants.COLOR_HIT_BOUNCE
	elseif hitType == VISUALIZER_HIT_TYPE.Pierce then
		color = Constants.COLOR_HIT_PIERCE
	else
		color = Constants.COLOR_HIT_TERMINAL
	end

	local a        = instance_new("SphereHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = cf
	a.Radius       = 0.35
	a.Transparency = 0.2
	a.Color3       = color
	a.AlwaysOnTop  = false
	a.Parent       = GetFolder()
	ScheduleDestroy(a, lifetime)
	return a
end

function Visualizer.Velocity(origin: Vector3, velocity: Vector3, scale: number?, lifetime: number?)
	local s      = scale or 0.1
	local length = velocity.Magnitude * s
	if length < 0.01 then return end

	local cf = CFrame.new(origin, origin + velocity.Unit)

	local a        = instance_new("ConeHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = cf
	a.Height       = length
	a.Radius       = 0.08
	a.Transparency = 0.3
	a.Name         = "Velocity"
	a.Color3       = Color3.new(0.3, 0.6, 1)
	a.AlwaysOnTop  = true
	a.Parent       = GetFolder()
	ScheduleDestroy(a, lifetime)
	return a
end

function Visualizer.Normal(position: Vector3, normal: Vector3, length: number?, lifetime: number?)
	local l  = length or 1
	local cf = CFrame.new(position, position + normal)

	local a        = instance_new("ConeHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = cf
	a.Height       = l
	a.Radius       = 0.05
	a.Transparency = 0.1
	a.Color3       = Color3.new(0.8, 0.8, 0.8)
	a.AlwaysOnTop  = true
	a.Parent       = GetFolder()
	ScheduleDestroy(a, lifetime)
	return a
end

function Visualizer.CornerTrap(position: Vector3, lifetime: number?)
	local a        = instance_new("SphereHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = CFrame.new(position)
	a.Radius       = 0.6
	a.Transparency = 0.0
	a.Color3       = Color3.new(1, 0, 1)
	a.AlwaysOnTop  = true
	a.Parent       = GetFolder()
	ScheduleDestroy(a, lifetime)
	return a
end

function Visualizer.ClearAll()
	local folder = Terrain:FindFirstChild(Constants.VISUALIZER_FOLDER_NAME)
	if folder then
		folder:ClearAllChildren()
	end
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return setmetatable(Visualizer, {
	__index = function(_, Key)
		Logger:Warn(string.format("Vetra: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"Vetra: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})