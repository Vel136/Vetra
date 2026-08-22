--!strict
--!optimize 2
--!native

local Debris     = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)

local IS_SERVER           = RunService:IsServer()
local VISUALIZER_HIT_TYPE = Constants.VISUALIZER_HIT_TYPE

local instance_new = Instance.new
local Terrain      = workspace.Terrain

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
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
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
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
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
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
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
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
	return a
end

function Visualizer.Origin(position: Vector3, lifetime: number?)
	local a        = instance_new("SphereHandleAdornment")
	a.Adornee      = Terrain
	a.CFrame       = CFrame.new(position)
	a.Radius       = 0.25
	a.Transparency = 0.1
	a.Name         = "Origin"
	a.Color3       = Color3.new(0.2, 0.9, 1)
	a.AlwaysOnTop  = true
	a.Parent       = GetFolder()
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
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
	Debris:AddItem(a, lifetime or Constants.VISUALIZER_LIFETIME)
	return a
end

function Visualizer.ClearAll()
	local folder = Terrain:FindFirstChild(Constants.VISUALIZER_FOLDER_NAME)
	if folder then
		folder:ClearAllChildren()
	end
end

return table.freeze(Visualizer)
