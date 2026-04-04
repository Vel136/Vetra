--[=[
	@class BehaviorRegistry

	Pre-registered behavior hash table shared between server and client.

	The core insight is that full behavior tables are **never sent over the
	network**. Instead, both server and client register the same behaviors at
	startup with identical names and registration order. Fire payloads carry
	only a 2-byte u16 hash. The server resolves the full behavior by hash
	lookup, zero serialization cost, zero deserialization cost, and zero
	ability for the client to inject or modify a behavior by crafting a
	custom table.

	```lua
	-- SharedBehaviors.lua (required by both server and client)
	local Registry = Vetra.VetraNet.BehaviorRegistry.new()
	Registry:Register("Rifle",    RifleBehavior)
	Registry:Register("Shotgun",  ShotgunBehavior)
	Registry:Register("Grenade",  GrenadeBehavior)
	return Registry
	```

	:::danger Registration order
	Both server and client **must** register behaviors in the **same order**
	with the **same names**. If they diverge, hashes will not match and every
	fire request will be rejected as `RejectedUnknownBehavior`. Enforce this
	by requiring the same shared ModuleScript on both sides, never register
	behaviors conditionally or in a different order per environment.
	:::

	:::tip Set MaxSpeed on every behavior
	Always set `MaxSpeed` on every registered behavior via
	`BehaviorBuilder:Physics():MaxSpeed(n):Done()`. The registry logs a warning
	if `MaxSpeed` is missing, without it, `FireValidator` falls back to a
	global default cap rather than your per-weapon limit, which weakens
	server-side speed validation.
	:::
]=]
local BehaviorRegistry = {}

--[=[
	Creates a new empty registry.

	@return BehaviorRegistry
]=]
function BehaviorRegistry.new(): BehaviorRegistry end

--[=[
	Registers a named behavior and returns its assigned u16 hash.

	Registering the same name twice is **idempotent**, the existing hash is
	returned without creating a duplicate entry. Registering the same behavior
	table under a different name produces a separate hash (intentional, weapon
	variants may share physics but carry different cosmetic behaviors).

	```lua
	local RifleHash   = Registry:Register("Rifle",   RifleBehavior)
	local ShotgunHash = Registry:Register("Shotgun", ShotgunBehavior)
	-- RifleHash == 1, ShotgunHash == 2 (first registered = hash 1, etc.)
	```

	@param Name string -- Non-empty behavior name.
	@param Behavior VetraBehavior -- The built behavior table (from `BehaviorBuilder:Build()`).
	@return number -- Assigned u16 hash, or `0` if registration failed (e.g. empty name).
]=]
function BehaviorRegistry:Register(Name: string, Behavior: any): number end

--[=[
	Returns the full behavior table for a given u16 hash.

	Returns `nil` if the hash was never registered. The server treats an
	unrecognised hash as `RejectedUnknownBehavior` and rejects the fire request.

	@param Hash number
	@return VetraBehavior?
]=]
function BehaviorRegistry:Get(Hash: number): any? end

--[=[
	Returns the u16 hash for a given behavior name.

	Returns `0` (UNKNOWN_BEHAVIOR_HASH) if the name has not been registered.
	Called internally by `Client:Fire()` to fill the `BehaviorHash` field in
	fire payloads before sending.

	@param Name string
	@return number -- Registered hash, or `0` if not found.
]=]
function BehaviorRegistry:GetHash(Name: string): number end

--[=[
	Destroys this registry, clearing all name and hash mappings.

	Idempotent, safe to call more than once.
]=]
function BehaviorRegistry:Destroy() end

return BehaviorRegistry
