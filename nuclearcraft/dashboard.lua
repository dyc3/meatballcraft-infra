local component = require("component")
local computer = require("computer")
local discovery = require("meatball.discovery")
local event = require("event")
local rpc = require("nuclearcraft.rpc")
local service = require("nuclearcraft.service")
local term = require("term")
local uiModule = require("nuclearcraft.ui")

local API_VERSION = 1
local DISCOVERY_TIMEOUT = 1
local REQUEST_TIMEOUT = 3
local REFRESH_INTERVAL = 2
local REDISCOVERY_INTERVAL = 30

local TYPES = {
    {
        key = "reactor",
        title = "REACTORS",
        singular = "reactor relay",
        serviceType = "meatballcraft.nc.reactor",
        protocol = "nc-reactor-v1",
        requestType = "getAll",
        responseField = "reactor"
    },
    {
        key = "heat",
        title = "HEAT EXCHANGERS",
        singular = "heat exchanger",
        serviceType = "meatballcraft.nc.heat-exchanger",
        protocol = "nc-heat-exchanger-v1",
        requestType = "getAll",
        responseField = "exchanger"
    },
    {
        key = "turbine",
        title = "TURBINES",
        singular = "turbine",
        serviceType = "meatballcraft.nc.turbine",
        protocol = "nc-turbine-v1",
        requestType = "getAll",
        responseField = "turbine"
    },
    {
        key = "geiger",
        title = "GEIGER COUNTERS",
        singular = "Geiger counter",
        serviceType = "meatballcraft.nc.geiger",
        protocol = "nc-geiger-v1",
        requestType = "getRadiation",
        responseField = "radiation"
    }
}

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("gpu") then error("No GPU found") end

local modem = component.modem
local ui = uiModule.new(component.gpu)
local records = {}
local discoveryState = {}
local discoveryProgress
local discoveryFinished
local pollProgress
local lastPoll

local function plural(label, count)
    if count == 1 then return label end
    return label .. "s"
end

local function elapsed(timestamp)
    if not timestamp then return "never" end
    return string.format("%.1fs ago", math.max(0, computer.uptime() - timestamp))
end

local function statusText(record)
    if record.status == "requesting" then return "REQUESTING", uiModule.WARN end
    if record.status == "connected" then return "CONNECTED", uiModule.GOOD end
    if record.status == "error" then return "ERROR", uiModule.BAD end
    return "WAITING", uiModule.MUTED
end

local function machineState(active, complete, activeLabel)
    local state = active and (activeLabel or "ONLINE") or "OFFLINE"
    local structure = complete and "COMPLETE" or "INVALID"
    return state .. " " .. structure
end

local function reactorSummary(response)
    local reactor = response.reactor
    local heat = reactor.heat
    local radiation = response.radiation
    local heatText = heat and uiModule.percentage(heat.percent) or "-"
    local radiationText = uiModule.metric(radiation and radiation.level, "Rads/t")
    local vessels = reactor.counts and uiModule.number(reactor.counts.vessels) or
        (reactor.vessels and uiModule.number(#reactor.vessels) or "-")
    return machineState(reactor.reactorOn, reactor.complete) .. " | Heat " .. heatText ..
        " | Radiation " .. radiationText .. " | Vessels " .. vessels
end

local function heatSummary(response)
    local exchanger = response.exchanger
    local efficiency = type(exchanger.efficiency) == "number" and
        uiModule.percentage(exchanger.efficiency * 100) or "-"
    local counts = exchanger.counts or {}
    return machineState(exchanger.active, exchanger.complete) .. " | Efficiency " .. efficiency ..
        " | Tubes " .. uiModule.number(counts.exchanger) .. "/" .. uiModule.number(counts.condensation)
end

local function turbineSummary(response)
    local turbine = response.turbine
    local energy = turbine.energy or {}
    return machineState(turbine.active, turbine.complete) .. " | Power " ..
        uiModule.metric(turbine.power, "RF/t") .. " | Energy " .. uiModule.percentage(energy.percent) ..
        " | Input " .. uiModule.number(turbine.inputRate) .. " mB/t"
end

local function geigerSummary(response)
    local radiation = response.radiation
    if radiation.level == nil then return "UNAVAILABLE | " .. tostring(radiation.error or "No reading") end
    return "ONLINE | Radiation " .. uiModule.metric(radiation.level, "Rads/t")
end

local SUMMARIES = {
    reactor = reactorSummary,
    heat = heatSummary,
    turbine = turbineSummary,
    geiger = geigerSummary
}

local function countConnected()
    local connected = 0
    for _, record in ipairs(records) do
        if record.status == "connected" then connected = connected + 1 end
    end
    return connected
end

local function draw()
    local width, height = ui.clear()
    ui.draw(1, 1, "NC SERVICE DASHBOARD", uiModule.HEADER)
    local connected = countConnected()
    local fleetStatus = string.format("%d/%d RESPONDING", connected, #records)
    ui.draw(math.max(1, width - #fleetStatus + 1), 1, fleetStatus,
        #records > 0 and connected == #records and uiModule.GOOD or uiModule.WARN)

    local discoveryText
    if discoveryProgress then
        discoveryText = string.format("Discovering NuclearCraft services (%d/%d): %s...",
            discoveryProgress.index, #TYPES, plural(discoveryProgress.kind.singular, 2))
    else
        discoveryText = string.format("Discovery: %d services discovered; completed %s", #records,
            elapsed(discoveryFinished))
    end
    ui.draw(1, 3, discoveryText, discoveryProgress and uiModule.WARN or uiModule.TEXT)

    local counts = {}
    local offersReceived = 0
    local offersRejected = 0
    for _, kind in ipairs(TYPES) do
        local state = discoveryState[kind.key] or {}
        counts[#counts + 1] = string.format("%s %d", kind.key, state.count or 0)
        offersReceived = offersReceived + (state.offers or 0)
        offersRejected = offersRejected + (state.rejected or 0)
    end
    ui.draw(1, 4, table.concat(counts, " | ") .. string.format(" | offers %d received, %d rejected",
        offersReceived, offersRejected), uiModule.MUTED)

    local requestText = pollProgress and ("Requesting metrics from " .. pollProgress .. "...") or
        ("Metrics updated " .. elapsed(lastPoll))
    ui.draw(1, 5, requestText, pollProgress and uiModule.WARN or uiModule.MUTED)

    local y = 7
    if not discoveryProgress and #records == 0 then
        if offersRejected > 0 then
            ui.draw(1, 6, string.format("No valid services found; %d offers were invalid or incompatible.",
                offersRejected), uiModule.WARN)
        else
            ui.draw(1, 6, "No services responded. Check servers, wireless range, and discovery port 48700.",
                uiModule.WARN)
        end
        y = 8
    end
    for _, kind in ipairs(TYPES) do
        if y >= height then break end
        local kindRecords = {}
        for _, record in ipairs(records) do
            if record.kind == kind then kindRecords[#kindRecords + 1] = record end
        end
        ui.draw(1, y, kind.title .. " (" .. tostring(#kindRecords) .. ")", uiModule.HEADER)
        y = y + 1
        if #kindRecords == 0 then
            local state = discoveryState[kind.key] or {}
            ui.draw(1, y, "  None discovered" .. (state.error and (": " .. state.error) or ""), uiModule.MUTED)
            y = y + 1
        else
            for _, record in ipairs(kindRecords) do
                if y >= height then break end
                local status, color = statusText(record)
                local details = record.response and SUMMARIES[kind.key](record.response) or status
                local conflict = record.service.conflict and " [DUPLICATE ID]" or ""
                ui.draw(1, y, "  " .. record.service.displayName .. conflict .. " | " .. details, color)
                y = y + 1
                if record.error and y < height then
                    ui.draw(3, y, "ERROR: " .. record.error, uiModule.BAD)
                    y = y + 1
                end
            end
        end
        y = y + 1
    end

    ui.draw(1, height, "Refresh " .. REFRESH_INTERVAL .. "s   Rediscover " .. REDISCOVERY_INTERVAL ..
        "s   r=refresh   d=discover   q=quit", uiModule.MUTED)
end

local function recordKey(kind, offered)
    return kind.key .. "\0" .. offered.instanceId .. "\0" .. offered.address
end

local function discoverAll()
    local previous = {}
    for _, record in ipairs(records) do previous[record.key] = record end
    local discovered = {}
    discoveryState = {}

    for index, kind in ipairs(TYPES) do
        discoveryProgress = { index = index, kind = kind }
        draw()
        local offered, reason, diagnostics = discovery.find(modem, {
            serviceType = kind.serviceType,
            apiVersion = API_VERSION,
            timeout = DISCOVERY_TIMEOUT
        })
        local state = {
            count = offered and #offered or 0,
            offers = diagnostics and diagnostics.offersReceived or 0,
            rejected = diagnostics and diagnostics.offersRejected or 0,
            error = reason
        }
        discoveryState[kind.key] = state

        for _, candidate in ipairs(offered or {}) do
            local key = recordKey(kind, candidate)
            local old = previous[key]
            discovered[#discovered + 1] = {
                key = key,
                kind = kind,
                service = candidate,
                response = old and old.response or nil,
                status = "waiting"
            }
        end
    end

    records = discovered
    discoveryProgress = nil
    discoveryFinished = computer.uptime()
    draw()
end

local function requestRecord(record)
    record.status = "requesting"
    record.error = nil
    pollProgress = record.service.displayName
    draw()

    local opened, openError = service.openPort(modem, record.service.servicePort)
    if not opened then
        record.status = "error"
        record.error = "Could not open port " .. tostring(record.service.servicePort) .. ": " .. tostring(openError)
        return
    end

    local endpoint = rpc.modemUnicast(modem, record.service.address, record.service.servicePort,
        record.kind.protocol, REQUEST_TIMEOUT)
    local response, requestError = endpoint.request(record.kind.requestType)
    if not response then
        record.status = "error"
        record.error = tostring(requestError)
    elseif type(response.ok) ~= "boolean" then
        record.status = "error"
        record.error = "Response received, but it is missing the boolean 'ok' field"
    elseif not response.ok then
        record.status = "error"
        record.error = "Server error: " .. tostring(response.error or "unknown error")
    elseif type(response[record.kind.responseField]) ~= "table" then
        record.status = "error"
        record.error = "Response received, but '" .. record.kind.responseField .. "' data is missing or invalid"
    else
        local validMetrics = pcall(SUMMARIES[record.kind.key], response)
        if not validMetrics then
            record.status = "error"
            record.error = "Response received, but its metric data has the wrong shape"
        else
            record.response = response
            record.status = "connected"
            record.error = nil
        end
    end
end

local function pollAll()
    for _, record in ipairs(records) do requestRecord(record) end
    pollProgress = nil
    lastPoll = computer.uptime()
    draw()
end

discoverAll()
local nextDiscovery = computer.uptime() + REDISCOVERY_INTERVAL
local refresh = true

while true do
    if refresh then
        pollAll()
        refresh = false
    end
    if computer.uptime() >= nextDiscovery then
        discoverAll()
        nextDiscovery = computer.uptime() + REDISCOVERY_INTERVAL
        refresh = true
    end

    local pulled = table.pack(event.pull(REFRESH_INTERVAL, "key_down"))
    if not pulled[1] then
        refresh = true
    else
        local char = pulled[3]
        if char == string.byte("q") or char == string.byte("Q") then
            term.clear()
            return
        elseif char == string.byte("r") or char == string.byte("R") then
            refresh = true
        elseif char == string.byte("d") or char == string.byte("D") then
            discoverAll()
            nextDiscovery = computer.uptime() + REDISCOVERY_INTERVAL
            refresh = true
        end
    end
end
