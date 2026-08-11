local event = require("event")
local serialization = require("serialization")

local rpc = {}

local function decode(encoded)
    local ok, response = pcall(serialization.unserialize, encoded)
    if not ok then return nil, "Invalid response" end
    return response
end

function rpc.tunnel(tunnel, protocol, timeout)
    local endpoint = {}

    function endpoint.request(requestType)
        tunnel.send(protocol, requestType)

        while true do
            local _, _, _, _, _, receivedProtocol, messageType, encoded = event.pull(timeout, "modem_message")
            if not receivedProtocol then return nil, "Request timed out" end

            if receivedProtocol == protocol and messageType == "response" then
                return decode(encoded)
            end
        end
    end

    function endpoint.serve(handler)
        while true do
            local _, _, _, _, _, receivedProtocol, requestType = event.pull("modem_message")
            if receivedProtocol == protocol then
                tunnel.send(protocol, "response", serialization.serialize(handler(requestType)))
            end
        end
    end

    return endpoint
end

function rpc.modem(modem, port, protocol, timeout)
    local endpoint = {}

    function endpoint.request(requestType)
        modem.broadcast(port, protocol, requestType)

        while true do
            local _, _, remoteAddress, receivedPort, _, receivedProtocol, messageType, encoded =
                event.pull(timeout, "modem_message")
            if not remoteAddress then return nil, "Request timed out" end

            if receivedPort == port and receivedProtocol == protocol and messageType == "response" then
                return decode(encoded)
            end
        end
    end

    function endpoint.serve(handler)
        while true do
            local _, _, remoteAddress, receivedPort, _, receivedProtocol, requestType = event.pull("modem_message")
            if receivedPort == port and receivedProtocol == protocol then
                modem.send(remoteAddress, port, protocol, "response", serialization.serialize(handler(requestType)))
            end
        end
    end

    return endpoint
end

return rpc
