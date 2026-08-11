local component = require("component")
local rpc = require("nuclearcraft.rpc")

local PROTOCOL = "nc-geiger-v1"

local tunnel = component.tunnel
local geiger = component.nc_geiger_counter

if not tunnel then error("No tunnel component found") end
if not geiger then error("No nc_geiger_counter found") end

local endpoint = rpc.tunnel(tunnel, PROTOCOL)

local function getRadiation()
    local ok, level = pcall(geiger.getChunkRadiationLevel)
    if not ok then return { level = nil, error = tostring(level) } end
    return { level = level }
end

local function buildResponse(requestType)
    if requestType == "getRadiation" then
        return { ok = true, radiation = getRadiation() }
    end
    return { ok = false, error = "Unknown request: " .. tostring(requestType) }
end

print("NC Geiger Counter Server")
print("========================")
print("Listening on linked card...")
print()

endpoint.serve(buildResponse)
