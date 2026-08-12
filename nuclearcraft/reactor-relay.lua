local component = require("component")
local rpc = require("nuclearcraft.rpc")

local PORT = 48723
local PROTOCOL = "nc-reactor-v1"
local TIMEOUT = 5

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("tunnel") then error("No Linked Card found (missing 'tunnel' component)") end

local modem = component.modem
local tunnel = component.tunnel
modem.open(PORT)

local networkEndpoint = rpc.modem(modem, PORT, PROTOCOL)
local reactorEndpoint = rpc.tunnel(tunnel, PROTOCOL, TIMEOUT)

local function forward(requestType)
    local response, err = reactorEndpoint.request(requestType)
    if not response then return { ok = false, error = err or "Reactor server unavailable" } end
    return response
end

print("NC reactor relay")
print("================")
print("Network port: " .. PORT)
print("Forwarding requests over linked card...")
print()

networkEndpoint.serve(forward)
