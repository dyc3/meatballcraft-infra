local event = require("event")
local computer = require("computer")
local serialization = require("serialization")

local rpc = {}
local requestCounter = 0

local function nextRequestId(protocol)
    requestCounter = requestCounter + 1
    return table.concat({ tostring(protocol), tostring(computer.uptime()), tostring(requestCounter) }, ":")
end

local function decode(encoded)
    local ok, response = pcall(serialization.unserialize, encoded)
    if not ok or response == nil then return nil, "Response received, but its payload is invalid" end
    if type(response) ~= "table" then return nil, "Response received, but its payload has the wrong shape (expected a table)" end
    return response
end

local function timeoutError(timeout)
    return string.format("Request sent; no response received within %.1f seconds", timeout or 5)
end

local function remaining(deadline)
    return math.max(0, deadline - computer.uptime())
end

function rpc.tunnel(tunnel, protocol, timeout)
    local endpoint = {}

    function endpoint.request(requestType)
        local requestId = nextRequestId(protocol)
        local deadline = computer.uptime() + (timeout or 5)
        tunnel.send(protocol, "request", requestId, requestType)

        while true do
            local _, _, _, _, _, receivedProtocol, messageType, receivedRequestId, encoded =
                event.pull(remaining(deadline), "modem_message")
            if not receivedProtocol then return nil, timeoutError(timeout) end

            if receivedProtocol == protocol and messageType == "response" then
                if receivedRequestId == requestId then return decode(encoded) end
                if encoded == nil and type(receivedRequestId) == "string" then
                    return nil, "Incompatible RPC peer; update and reboot both endpoints"
                end
            end
        end
    end

    function endpoint.serve(handler)
        while true do
            local _, _, _, _, _, receivedProtocol, messageType, requestId, requestType = event.pull("modem_message")
            if receivedProtocol == protocol then
                if messageType == "request" then
                    tunnel.send(protocol, "response", requestId, serialization.serialize(handler(requestType)))
                end
            end
        end
    end

    return endpoint
end

local function modemEndpoint(modem, remoteAddress, port, protocol, timeout)
    local endpoint = {}

    function endpoint.request(requestType)
        local requestId = nextRequestId(protocol)
        local deadline = computer.uptime() + (timeout or 5)
        if remoteAddress then
            modem.send(remoteAddress, port, protocol, "request", requestId, requestType)
        else
            modem.broadcast(port, protocol, "request", requestId, requestType)
        end

        while true do
            local _, _, senderAddress, receivedPort, _, receivedProtocol, messageType, receivedRequestId, encoded =
                event.pull(remaining(deadline), "modem_message")
            if not senderAddress then return nil, timeoutError(timeout) end

            if receivedPort == port and receivedProtocol == protocol and messageType == "response" and
                receivedRequestId == requestId and (not remoteAddress or senderAddress == remoteAddress) then
                return decode(encoded)
            end
        end
    end

    function endpoint.serve(handler)
        while true do
            local _, _, senderAddress, receivedPort, _, receivedProtocol, messageType, requestId, requestType =
                event.pull("modem_message")
            if receivedPort == port and receivedProtocol == protocol then
                if messageType == "request" then
                    modem.send(senderAddress, port, protocol, "response", requestId,
                        serialization.serialize(handler(requestType)))
                end
            end
        end
    end

    return endpoint
end

function rpc.modem(modem, port, protocol, timeout)
    return modemEndpoint(modem, nil, port, protocol, timeout)
end

function rpc.modemUnicast(modem, remoteAddress, port, protocol, timeout)
    if type(remoteAddress) ~= "string" or remoteAddress == "" then error("remote modem address is required") end
    return modemEndpoint(modem, remoteAddress, port, protocol, timeout)
end

return rpc
