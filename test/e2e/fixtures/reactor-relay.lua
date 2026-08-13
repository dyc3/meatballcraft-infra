local serialization = require("serialization")

local PORT = 48723
local PROTOCOL = "nc-reactor-v1"
local COMPLETE = "reactor relay test complete"

local openedPort
local tunnelRequest
local networkResponse
local advertised
local serviceConfig

local modem = {}
function modem.open(port)
    openedPort = port
    return true
end
function modem.send(address, port, protocol, messageType, requestId, encoded)
    networkResponse = {
        address = address,
        port = port,
        protocol = protocol,
        messageType = messageType,
        requestId = requestId,
        value = serialization.unserialize(encoded)
    }
    error(COMPLETE)
end

local tunnel = {}
function tunnel.send(protocol, messageType, requestId, requestType)
    tunnelRequest = { protocol = protocol, messageType = messageType, requestId = requestId, requestType = requestType }
end

package.loaded.component = {
    modem = modem,
    tunnel = tunnel,
    isAvailable = function(name) return name == "modem" or name == "tunnel" end
}
package.loaded["meatball.discovery"] = {
    PORT = 48700,
    advertise = function(receivedModem, spec)
        assert(receivedModem == modem)
        advertised = spec
        return { close = function() end }
    end
}
package.loaded["nuclearcraft.service"] = {
    configure = function(options)
        serviceConfig = options
        return { instanceId = options.instanceId, displayName = options.displayName }
    end,
    choose = function(services) return services[1] end
}

local pulls = 0
package.loaded.event = {
    pull = function(...)
        pulls = pulls + 1
        if pulls == 1 then
            return "modem_message", "relay-modem", "client-modem", PORT, 1, PROTOCOL, "request",
                "client-request-1", "getAll"
        elseif pulls == 2 then
            local response = serialization.serialize({ ok = true, reactor = { reactorOn = true } })
            return "modem_message", "relay-tunnel", "server-tunnel", 0, 1, PROTOCOL, "response",
                tunnelRequest.requestId, response
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

local relayChunk = assert(loadfile(mount .. "/repo/nuclearcraft/reactor-relay.lua"))
local ok, failure = pcall(relayChunk, "--id=reactor-test", "--name=Test Reactor")
assert(not ok and tostring(failure):find(COMPLETE, 1, true), tostring(failure))
assert(openedPort == PORT, "relay did not open the reactor network port")
assert(serviceConfig and serviceConfig.configPath and serviceConfig.instanceId == "reactor-test",
    "relay did not resolve its persisted service configuration")
assert(advertised and advertised.instanceId == "reactor-test" and advertised.displayName == "Test Reactor",
    "relay did not advertise its configured identity")
assert(advertised.serviceType == "meatballcraft.nc.reactor" and advertised.servicePort == PORT,
    "relay advertised the wrong service endpoint")
assert(tunnelRequest and tunnelRequest.protocol == PROTOCOL, "relay used the wrong linked-card protocol")
assert(tunnelRequest.messageType == "request" and tunnelRequest.requestId, "relay did not correlate its tunnel request")
assert(tunnelRequest.requestType == "getAll", "relay did not forward the request type")
assert(networkResponse and networkResponse.address == "client-modem", "relay replied to the wrong network client")
assert(networkResponse.port == PORT and networkResponse.protocol == PROTOCOL, "relay replied on the wrong endpoint")
assert(networkResponse.messageType == "response", "relay did not send an RPC response")
assert(networkResponse.requestId == "client-request-1", "relay did not preserve the client request ID")
assert(networkResponse.value.ok == true, "relay did not preserve the server response")
assert(networkResponse.value.reactor.reactorOn == true, "relay response lost reactor data")

local rpc = require("nuclearcraft.rpc")
local rpcSent
local rpcPulls = 0
local rpcModem = {
    send = function(address, port, protocol, messageType, requestId, requestType)
        rpcSent = {
            address = address,
            port = port,
            protocol = protocol,
            messageType = messageType,
            requestId = requestId,
            requestType = requestType
        }
    end
}
package.loaded.event.pull = function()
    rpcPulls = rpcPulls + 1
    local encoded = serialization.serialize({ ok = true, source = "selected-relay" })
    if rpcPulls == 1 then
        return "modem_message", "client", "other-relay", PORT, 1, PROTOCOL, "response", rpcSent.requestId, encoded
    end
    return "modem_message", "client", "selected-relay", PORT, 1, PROTOCOL, "response", rpcSent.requestId, encoded
end
local unicastResponse = assert(rpc.modemUnicast(rpcModem, "selected-relay", PORT, PROTOCOL, 5).request("getAll"))
assert(rpcSent.address == "selected-relay" and rpcSent.messageType == "request", "unicast RPC sent to the wrong relay")
assert(rpcSent.requestId and rpcSent.requestType == "getAll", "unicast RPC request was not correlated")
assert(rpcPulls == 2 and unicastResponse.source == "selected-relay", "unicast RPC accepted another relay's response")

local legacyRequest
local legacyTunnel = {
    send = function(protocol, messageType, requestId, requestType)
        legacyRequest = { protocol = protocol, messageType = messageType, requestId = requestId, requestType = requestType }
    end
}
package.loaded.event.pull = function()
    return "modem_message", "relay", "legacy-server", 0, 1, PROTOCOL, "response",
        serialization.serialize({ ok = true })
end
local legacyResponse, legacyError = rpc.tunnel(legacyTunnel, PROTOCOL, 5).request("getAll")
assert(not legacyResponse and legacyError and legacyError:find("Incompatible RPC peer", 1, true),
    "new relay did not identify a legacy reactor server response")
assert(legacyRequest.messageType == "request" and legacyRequest.requestType == "getAll",
    "compatibility test did not send a current RPC request")

package.loaded.event.pull = function() return nil end
local timedOutResponse, timedOutError = rpc.tunnel(legacyTunnel, PROTOCOL, 5).request("getAll")
assert(not timedOutResponse and timedOutError:find("Request sent", 1, true) and
    timedOutError:find("no response received", 1, true), "RPC timeout did not distinguish a missing response")

package.loaded.event.pull = function()
    return "modem_message", "relay", "server", 0, 1, PROTOCOL, "response", legacyRequest.requestId, "not serialized"
end
local malformedResponse, malformedError = rpc.tunnel(legacyTunnel, PROTOCOL, 5).request("getAll")
assert(not malformedResponse and malformedError:find("Response received", 1, true) and
    malformedError:find("wrong shape", 1, true), "RPC did not distinguish a malformed response: " .. tostring(malformedError))

local CLIENT_COMPLETE = "reactor client transport selected"

local function testClientTransport(hasTunnel)
    local selected
    local clientPort
    local discoveryCalls = 0
    local clientModem = {
        open = function(port)
            clientPort = port
            return true
        end
    }

    package.loaded.component = {
        gpu = {},
        modem = clientModem,
        tunnel = hasTunnel and {} or nil,
        isAvailable = function(name)
            return name == "gpu" or name == "modem" or (name == "tunnel" and hasTunnel)
        end
    }
    package.loaded["nuclearcraft.rpc"] = {
        tunnel = function(_, protocol, timeout)
            selected = { kind = "tunnel", protocol = protocol, timeout = timeout }
            return { request = function() end }
        end,
        modemUnicast = function(_, address, port, protocol, timeout)
            selected = { kind = "modem", address = address, port = port, protocol = protocol, timeout = timeout }
            return { request = function() end }
        end
    }
    package.loaded["meatball.discovery"] = {
        find = function(receivedModem, query)
            discoveryCalls = discoveryCalls + 1
            assert(receivedModem == clientModem, "client discovered on the wrong modem")
            assert(query.serviceType == "meatballcraft.nc.reactor" and query.apiVersion == 1,
                "client queried the wrong service")
            return {
                {
                    instanceId = "reactor-test",
                    displayName = "Test Reactor",
                    address = "relay-address",
                    servicePort = PORT
                }
            }
        end
    }
    package.loaded["nuclearcraft.service"] = {
        discover = function(discoveryModule, receivedModem, options)
            return discoveryModule.find(receivedModem, options)
        end,
        choose = function(services) return services[1] end
    }
    package.loaded["nuclearcraft.ui"] = {
        new = function()
            return { runMenu = function() error(CLIENT_COMPLETE) end }
        end
    }

    local ran, clientFailure = pcall(dofile, mount .. "/repo/nuclearcraft/reactor-client.lua")
    assert(not ran and tostring(clientFailure):find(CLIENT_COMPLETE, 1, true), tostring(clientFailure))
    assert(selected and selected.protocol == PROTOCOL and selected.timeout == 5, "client used the wrong RPC endpoint")

    if hasTunnel then
        assert(selected.kind == "tunnel", "client did not prefer its Linked Card")
        assert(discoveryCalls == 0, "client used service discovery despite having a Linked Card")
        assert(clientPort == nil, "client opened the modem while using its Linked Card")
    else
        assert(selected.kind == "modem", "client did not fall back to the reactor relay")
        assert(discoveryCalls == 1, "client did not discover a reactor relay")
        assert(selected.address == "relay-address", "client did not unicast to the discovered relay")
        assert(selected.port == PORT and clientPort == PORT, "client used the wrong reactor relay port")
    end
end

testClientTransport(true)
testClientTransport(false)
