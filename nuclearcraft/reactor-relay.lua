local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local service = require("nuclearcraft.service")
local shell = require("shell")

local PORT = 48723
local PROTOCOL = "nc-reactor-v1"
local TIMEOUT = 5
local SERVICE_TYPE = "meatballcraft.nc.reactor"
local API_VERSION = 1
local CONFIG_PATH = "/etc/nuclearcraft/reactor-relay.cfg"

local args, options = shell.parse(...)

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("tunnel") then error("No Linked Card found (missing 'tunnel' component)") end

local config = service.configure({
    configPath = CONFIG_PATH,
    instanceId = options.id or args[1],
    displayName = options.name or args[2],
    title = "Reactor relay setup"
})
local instanceId = config.instanceId
local displayName = config.displayName

local modem = component.modem
local tunnel = component.tunnel
modem.open(PORT)

local networkEndpoint = rpc.modem(modem, PORT, PROTOCOL)
local reactorEndpoint = rpc.tunnel(tunnel, PROTOCOL, TIMEOUT)
local advertisement, advertiseError = discovery.advertise(modem, {
    serviceType = SERVICE_TYPE,
    instanceId = instanceId,
    displayName = displayName,
    apiVersion = API_VERSION,
    servicePort = PORT
})
if not advertisement then error("Could not advertise reactor relay: " .. tostring(advertiseError)) end

local function forward(requestType)
    local response, err = reactorEndpoint.request(requestType)
    if not response then return { ok = false, error = err or "Reactor server unavailable" } end
    return response
end

print("NC reactor relay")
print("================")
print("Identity: " .. instanceId)
print("Name: " .. displayName)
print("Network port: " .. PORT)
print("Discovery port: " .. discovery.PORT)
print("Forwarding requests over linked card...")
print()

networkEndpoint.serve(forward)
