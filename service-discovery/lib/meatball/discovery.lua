local computer = require("computer")
local event = require("event")
local serialization = require("serialization")

local discovery = {
    PORT = 48700,
    PROTOCOL = "mbc-sd-v1"
}

local MAX_REQUEST_ID = 128
local MAX_SERVICE_TYPE = 96
local MAX_INSTANCE_ID = 64
local MAX_DISPLAY_NAME = 96
local MAX_METADATA = 512
local MAX_DETAILS = 768
local requestCounter = 0
local portUsers = setmetatable({}, { __mode = "k" })

local function boundedString(value, name, maximum)
    if type(value) ~= "string" or value == "" then
        return nil, name .. " must be a non-empty string"
    end
    if #value > maximum then
        return nil, name .. " exceeds " .. tostring(maximum) .. " bytes"
    end
    return value
end

local function validInteger(value, name, minimum, maximum)
    if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
        return nil, name .. " must be an integer from " .. tostring(minimum) .. " to " .. tostring(maximum)
    end
    return value
end

local function acquirePort(modem)
    local state = portUsers[modem]
    if state then
        state.users = state.users + 1
        return true
    end

    local wasOpen = modem.isOpen(discovery.PORT)
    if not wasOpen then
        local opened, reason = modem.open(discovery.PORT)
        if not opened then return nil, reason or "could not open discovery port" end
    end

    portUsers[modem] = { users = 1, opened = not wasOpen }
    return true
end

local function releasePort(modem)
    local state = portUsers[modem]
    if not state then return end

    state.users = state.users - 1
    if state.users > 0 then return end

    portUsers[modem] = nil
    if state.opened then pcall(modem.close, discovery.PORT) end
end

local function nextRequestId(modem)
    requestCounter = requestCounter + 1
    return table.concat({ tostring(modem.address or "modem"), tostring(computer.uptime()), tostring(requestCounter) }, ":")
end

local function sameModem(modem, localAddress)
    return not modem.address or not localAddress or modem.address == localAddress
end

local function responseDelay(remoteAddress, requestId, maximum)
    if maximum <= 0 then return 0 end
    local value = 0
    local source = tostring(remoteAddress) .. tostring(requestId)
    for index = 1, #source do value = (value * 33 + source:byte(index)) % 1009 end
    return value / 1009 * maximum
end

local function validateSpec(spec)
    if type(spec) ~= "table" then return nil, "advertisement spec must be a table" end

    local serviceType, err = boundedString(spec.serviceType, "serviceType", MAX_SERVICE_TYPE)
    if not serviceType then return nil, err end
    local instanceId
    instanceId, err = boundedString(spec.instanceId, "instanceId", MAX_INSTANCE_ID)
    if not instanceId then return nil, err end
    local displayName
    displayName, err = boundedString(spec.displayName, "displayName", MAX_DISPLAY_NAME)
    if not displayName then return nil, err end
    local apiVersion
    apiVersion, err = validInteger(spec.apiVersion, "apiVersion", 1, 2147483647)
    if not apiVersion then return nil, err end
    local servicePort
    servicePort, err = validInteger(spec.servicePort, "servicePort", 1, 65535)
    if not servicePort then return nil, err end

    local metadata = spec.metadata or {}
    if type(metadata) ~= "table" then return nil, "metadata must be a table" end
    local metadataOk, encodedMetadata = pcall(serialization.serialize, metadata)
    if not metadataOk then return nil, "metadata could not be serialized" end
    if #encodedMetadata > MAX_METADATA then return nil, "metadata exceeds " .. tostring(MAX_METADATA) .. " bytes" end
    local details = serialization.serialize({ displayName = displayName, metadata = metadata })
    if #details > MAX_DETAILS then return nil, "offer details exceed " .. tostring(MAX_DETAILS) .. " bytes" end

    local jitter = spec.responseJitter
    if jitter == nil then jitter = 0.15 end
    if type(jitter) ~= "number" or jitter < 0 or jitter > 0.5 then
        return nil, "responseJitter must be a number from 0 to 0.5"
    end

    return {
        serviceType = serviceType,
        instanceId = instanceId,
        displayName = displayName,
        apiVersion = apiVersion,
        servicePort = servicePort,
        details = details,
        responseJitter = jitter
    }
end

function discovery.advertise(modem, spec)
    if type(modem) ~= "table" and type(modem) ~= "userdata" then return nil, "modem is required" end

    local advertisement, err = validateSpec(spec)
    if not advertisement then return nil, err end

    local acquired
    acquired, err = acquirePort(modem)
    if not acquired then return nil, err end

    local active = true
    local function listener(_, localAddress, remoteAddress, port, _, protocol, kind, requestId, serviceType,
                            apiVersion)
        if not active or not sameModem(modem, localAddress) then return end
        if port ~= discovery.PORT or protocol ~= discovery.PROTOCOL or kind ~= "discover" then return end
        if not boundedString(requestId, "requestId", MAX_REQUEST_ID) then return end
        if serviceType ~= advertisement.serviceType or apiVersion ~= advertisement.apiVersion then return end
        if type(remoteAddress) ~= "string" or remoteAddress == "" then return end

        local function offer()
            if not active then return end
            modem.send(remoteAddress, discovery.PORT, discovery.PROTOCOL, "offer", requestId,
                advertisement.serviceType, advertisement.instanceId, advertisement.apiVersion,
                advertisement.servicePort, advertisement.details)
        end

        local delay = responseDelay(remoteAddress, requestId, advertisement.responseJitter)
        if delay == 0 then offer() else event.timer(delay, offer, 1) end
    end

    local registered = event.listen("modem_message", listener)
    if not registered then
        releasePort(modem)
        return nil, "could not register discovery listener"
    end

    local handle = {}
    function handle.close()
        if not active then return false end
        active = false
        event.ignore("modem_message", listener)
        releasePort(modem)
        return true
    end

    return handle
end

local function validateQuery(query)
    if type(query) ~= "table" then return nil, "discovery query must be a table" end

    local serviceType, err = boundedString(query.serviceType, "serviceType", MAX_SERVICE_TYPE)
    if not serviceType then return nil, err end
    local apiVersion
    apiVersion, err = validInteger(query.apiVersion, "apiVersion", 1, 2147483647)
    if not apiVersion then return nil, err end

    local timeout = query.timeout
    if timeout == nil then timeout = 1 end
    if type(timeout) ~= "number" or timeout < 0 or timeout > 60 then
        return nil, "timeout must be a number from 0 to 60"
    end

    return { serviceType = serviceType, apiVersion = apiVersion, timeout = timeout }
end

local function decodeDetails(encoded)
    if type(encoded) ~= "string" or #encoded > MAX_DETAILS then return nil end
    local ok, value = pcall(serialization.unserialize, encoded)
    if not ok or type(value) ~= "table" then return nil end
    if not boundedString(value.displayName, "displayName", MAX_DISPLAY_NAME) then return nil end
    if type(value.metadata) ~= "table" then return nil end
    local metadataOk, encodedMetadata = pcall(serialization.serialize, value.metadata)
    if not metadataOk or #encodedMetadata > MAX_METADATA then return nil end
    return value
end

function discovery.find(modem, query)
    if type(modem) ~= "table" and type(modem) ~= "userdata" then return nil, "modem is required" end

    local validated, err = validateQuery(query)
    if not validated then return nil, err end

    local acquired
    acquired, err = acquirePort(modem)
    if not acquired then return nil, err end

    local requestId = nextRequestId(modem)
    local found = {}
    local function listener(_, localAddress, remoteAddress, port, _, protocol, kind, receivedRequestId,
                            serviceType, instanceId, apiVersion, servicePort, encodedDetails)
        if not sameModem(modem, localAddress) then return end
        if port ~= discovery.PORT or protocol ~= discovery.PROTOCOL or kind ~= "offer" then return end
        if receivedRequestId ~= requestId or serviceType ~= validated.serviceType or apiVersion ~= validated.apiVersion then
            return
        end
        if type(remoteAddress) ~= "string" or remoteAddress == "" then return end
        if not boundedString(instanceId, "instanceId", MAX_INSTANCE_ID) then return end
        if not validInteger(servicePort, "servicePort", 1, 65535) then return end

        local details = decodeDetails(encodedDetails)
        if not details then return end

        local key = instanceId .. "\0" .. remoteAddress
        found[key] = {
            serviceType = serviceType,
            instanceId = instanceId,
            displayName = details.displayName,
            apiVersion = apiVersion,
            servicePort = servicePort,
            address = remoteAddress,
            metadata = details.metadata,
            lastSeen = computer.uptime(),
            conflict = false
        }
    end

    local registered = event.listen("modem_message", listener)
    if not registered then
        releasePort(modem)
        return nil, "could not register discovery listener"
    end

    local ok, reason = pcall(modem.broadcast, discovery.PORT, discovery.PROTOCOL, "discover", requestId,
        validated.serviceType, validated.apiVersion)
    if ok then
        local deadline = computer.uptime() + validated.timeout
        while computer.uptime() < deadline do
            event.pull(math.max(0, deadline - computer.uptime()))
        end
    end

    event.ignore("modem_message", listener)
    releasePort(modem)
    if not ok then return nil, tostring(reason) end

    local services = {}
    local identities = {}
    for _, service in pairs(found) do
        services[#services + 1] = service
        identities[service.instanceId] = (identities[service.instanceId] or 0) + 1
    end
    for _, service in ipairs(services) do
        service.conflict = identities[service.instanceId] > 1
    end
    table.sort(services, function(left, right)
        if left.displayName ~= right.displayName then return left.displayName < right.displayName end
        if left.instanceId ~= right.instanceId then return left.instanceId < right.instanceId end
        return left.address < right.address
    end)

    return services
end

return discovery
