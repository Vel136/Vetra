--!strict
--!optimize 2
--!native

local string_format   = string.format
local buffer_create   = buffer.create
local buffer_readu16  = buffer.readu16
local buffer_writeu16 = buffer.writeu16
local buffer_len      = buffer.len

local _nameToHash : { [string]: number } = {}
local _hashToMod  : { [number]: any    } = {}
local _next = 1

local ModifierRegistry = {}

function ModifierRegistry.Register(name: string, mod: any): number
	local existing = _nameToHash[name]
	if existing then return existing end

	local hash = _next
	if hash > 65535 then
		error(string_format("ModifierRegistry: hash space exhausted (>65535), '%s' not registered", name), 2)
		return 0
	end
	_next += 1
	_nameToHash[name] = hash
	_hashToMod[hash]  = mod
	return hash
end

function ModifierRegistry.Get(hash: number): any?
	return _hashToMod[hash]
end

function ModifierRegistry.GetHash(name: string): number
	return _nameToHash[name] or 0
end

function ModifierRegistry.Pack(hashes: { number }): buffer
	local count = 0
	for _, hash in hashes do
		if hash and hash ~= 0 then count += 1 end
	end

	local buf    = buffer_create(count * 2)
	local offset = 0
	for _, hash in hashes do
		if hash and hash ~= 0 then
			buffer_writeu16(buf, offset, hash)
			offset += 2
		end
	end
	return buf
end

function ModifierRegistry.Unpack(buf: buffer): { number }
	local len    = buffer_len(buf)
	local count  = len / 2
	local hashes = table.create(count)
	for i = 1, count do
		hashes[i] = buffer_readu16(buf, (i - 1) * 2)
	end
	return hashes
end

local _EMPTY_BUFFER = buffer_create(0)

function ModifierRegistry.Empty(): buffer
	return _EMPTY_BUFFER
end

function ModifierRegistry.IsEmpty(buf: buffer?): boolean
	if not buf then return true end
	return buffer_len(buf) == 0
end

return table.freeze(ModifierRegistry)
