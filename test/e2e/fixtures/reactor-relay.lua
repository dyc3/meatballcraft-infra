local serialization = require("serialization")

local PORT = 48723
local PROTOCOL = "nc-reactor-v1"
local COMPLETE = "reactor relay test complete"

local openedPort
local tunnelRequest
local networkResponse

local modem = {}
function modem.open(port)
    openedPort = port
    return true
end
function modem.send(address, port, protocol, messageType, encoded)
    networkResponse = {
        address = address,
        port = port,
        protocol = protocol,
        messageType = messageType,
        value = serialization.unserialize(encoded)
    }
    error(COMPLETE)
end

local tunnel = {}
function tunnel.send(protocol, requestType)
    tunnelRequest = { protocol = protocol, requestType = requestType }
end

package.loaded.component = {
    modem = modem,
    tunnel = tunnel,
    isAvailable = function(name) return name == "modem" or name == "tunnel" end
}

local pulls = 0
package.loaded.event = {
    pull = function(...)
        pulls = pulls + 1
        if pulls == 1 then
            return "modem_message", "relay-modem", "client-modem", PORT, 1, PROTOCOL, "getAll"
        elseif pulls == 2 then
            local response = serialization.serialize({ ok = true, reactor = { reactorOn = true } })
            return "modem_message", "relay-tunnel", "server-tunnel", 0, 1, PROTOCOL, "response", response
        end
        error("unexpected event pull")
    end
}
package.loaded["nuclearcraft.rpc"] = nil

local filesystem = require("filesystem")
local mount
for proxy, path in filesystem.mounts() do
    if proxy.getLabel() == "e2e" then
        mount = path
        break
    end
end
assert(mount, "e2e filesystem was not mounted")
assert(loadfile(mount .. "/repo/nuclearcraft/reactor-client.lua"))
assert(loadfile(mount .. "/repo/nuclearcraft/reactor-server.lua"))

local ok, failure = pcall(dofile, mount .. "/repo/nuclearcraft/reactor-relay.lua")
assert(not ok and tostring(failure):find(COMPLETE, 1, true), tostring(failure))
assert(openedPort == PORT, "relay did not open the reactor network port")
assert(tunnelRequest and tunnelRequest.protocol == PROTOCOL, "relay used the wrong linked-card protocol")
assert(tunnelRequest.requestType == "getAll", "relay did not forward the request type")
assert(networkResponse and networkResponse.address == "client-modem", "relay replied to the wrong network client")
assert(networkResponse.port == PORT and networkResponse.protocol == PROTOCOL, "relay replied on the wrong endpoint")
assert(networkResponse.messageType == "response", "relay did not send an RPC response")
assert(networkResponse.value.ok == true, "relay did not preserve the server response")
assert(networkResponse.value.reactor.reactorOn == true, "relay response lost reactor data")
