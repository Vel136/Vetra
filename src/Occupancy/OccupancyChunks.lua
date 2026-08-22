--!optimize 2

local EncodingService = game:GetService("EncodingService")

local OccupancyChunks = {}

local CHUNK = 180000

local function base64Encode(data: string): string
	return buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(data)))
end

local function base64Decode(text: string): string
	return buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(text)))
end

local function chunkName(i: number): string
	return string.format("%06d", i)
end

function OccupancyChunks.Write(folder: Instance, blob: string, version: number?)
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			child:Destroy()
		end
	end

	local encoded = base64Encode(blob)
	local total   = #encoded
	local count   = math.max(1, math.ceil(total / CHUNK))
	for i = 1, count do
		local sv = Instance.new("StringValue")
		sv.Name   = chunkName(i)
		sv.Value  = string.sub(encoded, (i - 1) * CHUNK + 1, i * CHUNK)
		sv.Parent = folder
	end

	folder:SetAttribute("ChunkCount", count)
	folder:SetAttribute("Version", version or 1)
	folder:SetAttribute("ByteLength", #blob)
end

function OccupancyChunks.Read(folder: Instance?): string?
	if not folder then return nil end

	local chunks: { StringValue } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			chunks[#chunks + 1] = child
		end
	end
	if #chunks == 0 then return nil end

	table.sort(chunks, function(a, b) return a.Name < b.Name end)

	local parts: { string } = {}
	for i, sv in chunks do
		parts[i] = sv.Value
	end
	return base64Decode(table.concat(parts))
end

return OccupancyChunks
