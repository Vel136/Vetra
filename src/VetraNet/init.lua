local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return script.Server
else
	return script.Client
end
