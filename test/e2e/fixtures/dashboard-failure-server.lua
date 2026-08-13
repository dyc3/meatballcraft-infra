local component = require("component")
local discovery = require("meatball.discovery")
local event = require("event")
local serialization = require("serialization")

local modem = component.modem

local function advertise(serviceType, instanceId, displayName, port)
    assert(discovery.advertise(modem, {
        serviceType = serviceType,
        instanceId = instanceId,
        displayName = displayName,
        apiVersion = 1,
        servicePort = port,
        responseJitter = 0
    }))
end

advertise("meatballcraft.nc.reactor", "timeout-reactor", "Timeout Reactor", 48723)
advertise("meatballcraft.nc.heat-exchanger", "failed-heat", "Failed Heat Exchanger", 48722)
advertise("meatballcraft.nc.geiger", "malformed-geiger", "Malformed Geiger", 48721)
assert(modem.open(48722))
assert(modem.open(48721))

while true do
    local _, _, sender, port, _, protocol, messageType, requestId = event.pull("modem_message")
    if messageType == "request" and port == 48722 and protocol == "nc-heat-exchanger-v1" then
        modem.send(sender, port, protocol, "response", requestId,
            serialization.serialize({ ok = false, error = "fixture handler failure" }))
    elseif messageType == "request" and port == 48721 and protocol == "nc-geiger-v1" then
        modem.send(sender, port, protocol, "response", requestId,
            serialization.serialize({ ok = true, radiation = "wrong shape" }))
    end
end
