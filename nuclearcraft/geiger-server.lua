local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local service = require("nuclearcraft.service")
local shell = require("shell")

local PORT = 48721
local PROTOCOL = "nc-geiger-v1"
local SERVICE_TYPE = "meatballcraft.nc.geiger"
local API_VERSION = 1
local CONFIG_PATH = "/etc/nuclearcraft/geiger-server.cfg"

local geiger = component.nc_geiger_counter

if not geiger then error("No nc_geiger_counter found") end

local args, options = shell.parse(...)
local endpoint
local instanceId
local displayName
local transport

if component.isAvailable("tunnel") then
    endpoint = rpc.tunnel(component.tunnel, PROTOCOL)
    transport = "Linked Card"
else
    if not component.isAvailable("modem") then
        error("No Linked Card or Network Card found (missing 'tunnel' and 'modem' components)")
    end
    local config = service.configure({
        configPath = CONFIG_PATH,
        instanceId = options.id or args[1],
        displayName = options.name or args[2],
        title = "Geiger counter service setup"
    })
    instanceId = config.instanceId
    displayName = config.displayName

    local modem = component.modem
    modem.open(PORT)
    endpoint = rpc.modem(modem, PORT, PROTOCOL)
    local advertisement, advertiseError = discovery.advertise(modem, {
        serviceType = SERVICE_TYPE,
        instanceId = instanceId,
        displayName = displayName,
        apiVersion = API_VERSION,
        servicePort = PORT
    })
    if not advertisement then error("Could not advertise Geiger counter: " .. tostring(advertiseError)) end
    transport = "Network Card on port " .. tostring(PORT)
end

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
if instanceId then
    print("Identity: " .. instanceId)
    print("Name: " .. displayName)
    print("Discovery port: " .. discovery.PORT)
end
print("Listening on " .. transport .. "...")
print()

endpoint.serve(buildResponse)
