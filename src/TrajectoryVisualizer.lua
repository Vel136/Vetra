-- Visualizer.lua
--[[
    Debug visualization for Vetra.

    Renders cast segments, impact points, velocity vectors, surface normals,
    and corner trap markers as temporary Handle adornments in the world.

    Why adornments instead of drawing parts or beams?
        HandleAdornments attach to an existing Adornee (workspace.Terrain here)
        and render without ever appearing in the Explorer hierarchy as independent
        BaseParts. This means they don't interfere with raycasts, don't show up
        in CollectionService queries, and don't affect physics — all of which
        would corrupt the very simulation you are trying to debug if parts were
        used instead.

    Why workspace.Terrain as the Adornee?
        Terrain is always present, never gets deleted, and is never a valid
        raycast hit for projectile bullets in typical setups. Using it as the
        shared Adornee means every adornment in the scene shares one Adornee
        reference, which is cheaper than each adornment holding its own Instance
        reference. Parenting the adornments to a child Folder of Terrain rather
        than directly to Terrain also keeps the hierarchy navigable.

    Why is this a separate module rather than inline in Vetra?
        Vetra is loaded in production. Any visualizer code that lives
        inside it — even behind an `if VisualizeCasts` guard — still occupies
        bytecode space and increases the module's memory footprint. Keeping
        the visualizer in its own module means it can be required conditionally
        or excluded from production bundles entirely without touching Vetra.

    ⚠️  Every method allocates a new Instance. In production, if VisualizeCasts
        is accidentally left true, this becomes an unbounded memory leak at the
        rate of one Instance per raycast per frame per active bullet. Always
        verify VisualizeCasts = false before shipping.
]]

-- ─── Services ────────────────────────────────────────────────────────────────

local Debris     = game:GetService("Debris")
local RunService = game:GetService("RunService")

-- ─── Constants ───────────────────────────────────────────────────────────────

local FOLDER_NAME = "VetraSolverVisualization"

--[[
    Server and client render different segment colors so you can immediately
    tell whether a mismatch between server-side hit detection and client-side
    cosmetics is a replication issue or a solver issue. If both sides show the
    same trajectory but the server fires OnHit at a different point, the problem
    is in replication. If the trajectories themselves diverge, the problem is
    in how the two sides are receiving frame deltas.
]]
local IS_SERVER = RunService:IsServer()

local COLOR_SEGMENT_CLIENT = Color3.new(1, 0, 0)
local COLOR_SEGMENT_SERVER = Color3.fromRGB(255, 145, 11)

--[[
    Three distinct hit colors prevent the most common debugging mistake:
    misreading a pierce as a terminal hit or vice versa. In a pierce chain,
    you should see N red spheres followed by exactly one green sphere.
    If you see green before the chain ends, the pierce callback returned
    false earlier than expected. If you see no green at all, the cast
    expired by distance or speed rather than hitting a surface.
]]
local COLOR_HIT_TERMINAL = Color3.new(0.2, 1, 0.5)
local COLOR_HIT_BOUNCE   = Color3.new(1, 0.85, 0.1)
local COLOR_HIT_PIERCE   = Color3.new(1, 0.2, 0.2)

-- ─── Cached Globals ──────────────────────────────────────────────────────────

--[[
    Instance.new and workspace.Terrain are called on every visualizer method
    invocation. Caching them as upvalue locals avoids a global table lookup
    on each call. For a module that is only active during debug sessions this
    is not a meaningful performance concern — the caching is done for
    consistency with Vetra's conventions rather than necessity.
]]
local InstanceNew      = Instance.new
local WorkspaceTerrain = workspace.Terrain

-- ─── Module ──────────────────────────────────────────────────────────────────

local Visualizer = {}

-- ─── Folder Management ───────────────────────────────────────────────────────

--[[
    The visualization folder is created lazily rather than at module load time.
    Vetra requires this module unconditionally, but in production all
    Visualizer calls are gated behind VisualizeCasts = false and never actually
    execute. Creating the folder at require() time would leave a permanent empty
    folder in every production server's workspace.Terrain, which is wasteful and
    potentially confusing to developers inspecting the hierarchy at runtime.
]]
local _folder: Folder? = nil

local function GetFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end

	local existing = WorkspaceTerrain:FindFirstChild(FOLDER_NAME)
	if existing then
		_folder = existing :: Folder
		return _folder
	end

	local folder      = InstanceNew("Folder")
	folder.Name       = FOLDER_NAME
	--[[
	    Archivable = false prevents this folder and its children from being
	    included when the place is saved or when workspace is serialized for
	    replication. Adornments are ephemeral debug artifacts — there is no
	    reason for them to persist across sessions or travel to clients that
	    connect after they were created.
	]]
	folder.Archivable = false
	folder.Parent     = WorkspaceTerrain

	_folder = folder
	return folder
end

-- ─── Lifetime Management ─────────────────────────────────────────────────────

--[[
    Adornments are scheduled for automatic destruction via Debris rather than
    being cleaned up explicitly by the caller. The alternative — returning the
    adornment and requiring callers to destroy it — would mean every Visualizer
    call site in Vetra needs to track and clean up the returned handle.
    That would add bookkeeping to the hot simulation path and risk leaks whenever
    a new call site is added without remembering to clean up.

    Debris handles the destruction asynchronously and efficiently. The tradeoff
    is that adornments linger for DEFAULT_LIFETIME seconds even if the cast that
    created them terminates earlier, which is acceptable — lingering debug markers
    are helpful for reviewing what happened after a fast cast ends.
]]
local DEFAULT_LIFETIME = 3

local function ScheduleDestroy(instance: Instance, lifetime: number?)
	Debris:AddItem(instance, lifetime or DEFAULT_LIFETIME)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--[[
    Segment: renders one raycast step as a cone oriented along the travel direction.

    Why a cone rather than a cylinder or beam?
        The cone's point naturally indicates directionality — you can read the
        bullet's travel direction at a glance without needing a separate arrow.
        Cylinders are symmetric and give no directional cue. Beams require two
        Attachment points parented to BaseParts, which adds allocation overhead
        and requires a second Instance per segment.

    Why CFrame rather than two Vector3 endpoints?
        SimulateCast already computes the segment CFrame (origin + lookAt) for
        the cosmetic bullet orientation. Accepting that CFrame directly avoids
        recomputing it here and keeps the call site in SimulateCast minimal.
]]
function Visualizer.Segment(origin: CFrame, length: number, lifetime: number?)
	local a        = InstanceNew("ConeHandleAdornment")
	a.Adornee      = WorkspaceTerrain
	a.CFrame       = origin
	a.Height       = length
	a.Radius       = 0.15
	a.Transparency = 0.4
	a.Color3       = IS_SERVER and COLOR_SEGMENT_SERVER or COLOR_SEGMENT_CLIENT
	--[[
	    AlwaysOnTop = false intentionally. Segments that pass through geometry
	    should be occluded by that geometry — this immediately reveals tunnelling
	    issues where a segment visually exits through a wall that the raycast
	    should have detected but didn't.
	]]
	a.AlwaysOnTop  = false
	a.Parent       = GetFolder()

	ScheduleDestroy(a, lifetime)
	return a
end

--[[
    Hit: renders a sphere at an impact, bounce, or pierce contact point.

    The sphere is intentionally larger than the segment cone radius so it
    visually "caps" the end of the segment it corresponds to. Without the
    size difference, hit markers at the end of long segments are hard to
    distinguish from the segment geometry itself at typical camera distances.
]]
function Visualizer.Hit(cf: CFrame, hitType: "terminal" | "bounce" | "pierce", lifetime: number?)
	local color: Color3
	if hitType == "bounce" then
		color = COLOR_HIT_BOUNCE
	elseif hitType == "pierce" then
		color = COLOR_HIT_PIERCE
	else
		color = COLOR_HIT_TERMINAL
	end

	local a        = InstanceNew("SphereHandleAdornment")
	a.Adornee      = WorkspaceTerrain
	a.CFrame       = cf
	a.Radius       = 0.35
	a.Transparency = 0.2
	a.Color3       = color
	a.AlwaysOnTop  = false
	a.Parent       = GetFolder()

	ScheduleDestroy(a, lifetime)
	return a
end

--[[
    Velocity: renders the post-event velocity vector as a small directional cone.

    Why scale the length by velocity magnitude?
        A fixed-length arrow conveys direction but hides how much speed was lost
        in a bounce or pierce. Scaling by magnitude lets you visually compare
        pre- and post-event speeds — a noticeably shorter arrow after a bounce
        confirms that Restitution is being applied, while equal lengths would
        indicate the energy loss is not working.

    Why AlwaysOnTop = true here but false for segments?
        Velocity vectors are short (fraction of a stud at typical scale values)
        and originate at surface contact points. Without AlwaysOnTop they would
        be immediately occluded by the surface they are attached to, making them
        invisible in the common case. Segments are long enough to be visible
        even when partially occluded.
]]
function Visualizer.Velocity(origin: Vector3, velocity: Vector3, scale: number?, lifetime: number?)
	local s      = scale or 0.1
	local length = velocity.Magnitude * s
	-- A near-zero velocity produces a degenerate CFrame.new(pos, pos + nearZero)
	-- which can NaN the resulting CFrame. Skipping here is safer than clamping,
	-- since a near-zero velocity vector is not meaningful to visualize anyway.
	if length < 0.01 then return end

	local cf = CFrame.new(origin, origin + velocity.Unit)

	local a        = InstanceNew("ConeHandleAdornment")
	a.Adornee      = WorkspaceTerrain
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

--[[
    Normal: renders the surface normal at a bounce contact point.

    Why is this separate from Hit rather than combined into one call?
        Combining them would require Hit to accept an optional normal parameter
        and conditionally create a second adornment. That conflates two concerns —
        marking an event location and showing a geometric property of the surface —
        and makes the call sites in SimulateCast harder to read. Keeping them
        separate means each call site declares its intent explicitly.

    The normal cone is rendered with AlwaysOnTop = true for the same reason as
    Velocity: it originates on a surface and would otherwise be buried in geometry.
]]
function Visualizer.Normal(position: Vector3, normal: Vector3, length: number?, lifetime: number?)
	local l  = length or 1
	local cf = CFrame.new(position, position + normal)

	local a        = InstanceNew("ConeHandleAdornment")
	a.Adornee      = WorkspaceTerrain
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

--[[
    CornerTrap: renders a large magenta sphere at the point where a corner trap
    was detected and the cast was terminated.

    Why larger and fully opaque compared to regular hit markers?
        Corner traps are almost always unexpected — they indicate either a genuine
        degenerate geometry problem or thresholds that are too aggressive for the
        level's geometry. Making the marker visually louder than a normal hit
        ensures it is immediately noticed during a playtest without needing to
        know in advance that a corner trap occurred.

    Why magenta?
        Magenta does not appear in any other marker color in this module, so it
        cannot be confused with a terminal hit (green), bounce (yellow), or pierce
        (red) even at a glance or under unusual lighting conditions.
]]
function Visualizer.CornerTrap(position: Vector3, lifetime: number?)
	local a        = InstanceNew("SphereHandleAdornment")
	a.Adornee      = WorkspaceTerrain
	a.CFrame       = CFrame.new(position)
	a.Radius       = 0.6
	a.Transparency = 0.0
	a.Color3       = Color3.new(1, 0, 1)
	a.AlwaysOnTop  = true
	a.Parent       = GetFolder()

	ScheduleDestroy(a, lifetime)
	return a
end

--[[
    ClearAll: immediately destroys every adornment in the visualization folder.

    This exists because Debris-scheduled destruction happens asynchronously on
    Roblox's internal timer — you cannot force it to run early. When starting
    a new debug run it is useful to clear the previous run's markers immediately
    rather than waiting up to DEFAULT_LIFETIME seconds for them to expire
    naturally. ClearAllChildren is used rather than destroying and recreating the
    folder because the folder reference cached in _folder would become stale,
    requiring GetFolder() to search for or recreate it on the next call.
]]
function Visualizer.ClearAll()
	local folder = WorkspaceTerrain:FindFirstChild(FOLDER_NAME)
	if folder then
		folder:ClearAllChildren()
	end
end

return Visualizer