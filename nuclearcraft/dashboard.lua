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
        requestType = "getSummary",
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
local spinnerFrame = 1
local SPINNER = { "|", "/", "-", "\\" }

local function plural(label, count)
    if count == 1 then return label end
    return label .. "s"
end

local function elapsed(timestamp)
    if not timestamp then return "never" end
    return string.format("%.1fs ago", math.max(0, computer.uptime() - timestamp))
end

local function add(segments, text, color)
    segments[#segments + 1] = { text = tostring(text), color = color or uiModule.TEXT }
end

local function fitted(text, width)
    text = tostring(text)
    if #text > width then
        if width <= 1 then return text:sub(1, width) end
        return text:sub(1, width - 1) .. "~"
    end
    return text .. string.rep(" ", width - #text)
end

local function addField(segments, text, width, color)
    add(segments, fitted(text, width), color)
end

local function separator(segments)
    add(segments, " | ", uiModule.MUTED)
end

local function machineState(segments, active, complete)
    addField(segments, active and "ONLINE" or "OFFLINE", 8, active and uiModule.GOOD or uiModule.WARN)
    addField(segments, complete and "COMPLETE" or "INCOMPLETE", 10, complete and uiModule.GOOD or uiModule.WARN)
end

local function radiationColor(level)
    if type(level) ~= "number" then return uiModule.MUTED end
    local absolute = math.abs(level)
    if absolute >= 1 then return uiModule.BAD end
    if absolute >= 1e-3 then return uiModule.ORANGE end
    if absolute >= 1e-6 then return uiModule.WARN end
    return uiModule.TEXT
end

local function heatColor(percent)
    if type(percent) ~= "number" then return uiModule.MUTED end
    if percent >= 90 then return uiModule.BAD end
    if percent >= 70 then return uiModule.ORANGE end
    return uiModule.GOOD
end

local function efficiencyColor(efficiency)
    if type(efficiency) ~= "number" then return uiModule.MUTED end
    if efficiency >= 0.8 then return uiModule.GOOD end
    if efficiency >= 0.5 then return uiModule.WARN end
    return uiModule.ORANGE
end

local function reactorSummary(response)
    local segments = {}
    local reactor = response.reactor
    local heat = reactor.heat
    local radiation = response.radiation
    local vessels = reactor.counts and uiModule.number(reactor.counts.vessels) or
        (reactor.vessels and uiModule.number(#reactor.vessels) or "-")
    machineState(segments, reactor.reactorOn, reactor.complete)
    if reactor.failsafe and reactor.failsafe.triggered then
        separator(segments)
        add(segments, reactor.failsafe.deactivated == false and "FAILSAFE FAILED" or "FAILSAFE", uiModule.BAD)
    end
    separator(segments)
    add(segments, "Heat ", uiModule.MUTED)
    addField(segments, heat and uiModule.percentage(heat.percent) or "-", 7, heatColor(heat and heat.percent))
    separator(segments)
    add(segments, "Radiation ", uiModule.MUTED)
    addField(segments, uiModule.metric(radiation and radiation.level, "Rads/t"), 15,
        radiationColor(radiation and radiation.level))
    separator(segments)
    add(segments, "Vessels ", uiModule.MUTED)
    add(segments, vessels, uiModule.INFO)
    return segments
end

local function heatSummary(response)
    local segments = {}
    local exchanger = response.exchanger
    local efficiency = type(exchanger.efficiency) == "number" and
        uiModule.percentage(exchanger.efficiency * 100) or "-"
    local counts = exchanger.counts or {}
    machineState(segments, exchanger.active, exchanger.complete)
    separator(segments)
    add(segments, "Efficiency ", uiModule.MUTED)
    addField(segments, efficiency, 7, efficiencyColor(exchanger.efficiency))
    separator(segments)
    add(segments, "Tubes ", uiModule.MUTED)
    add(segments, uiModule.number(counts.exchanger), uiModule.INFO)
    add(segments, "/", uiModule.MUTED)
    add(segments, uiModule.number(counts.condensation), uiModule.INFO)
    return segments
end

local function turbineSummary(response)
    local segments = {}
    local turbine = response.turbine
    local energy = turbine.energy or {}
    machineState(segments, turbine.active, turbine.complete)
    separator(segments)
    add(segments, "Power ", uiModule.MUTED)
    addField(segments, uiModule.metric(turbine.power, "RF/t"), 12, uiModule.INFO)
    separator(segments)
    add(segments, "Energy ", uiModule.MUTED)
    addField(segments, uiModule.percentage(energy.percent), 7, uiModule.INFO)
    separator(segments)
    add(segments, "Input ", uiModule.MUTED)
    add(segments, uiModule.number(turbine.inputRate) .. " mB/t", uiModule.INFO)
    return segments
end

local function geigerSummary(response)
    local segments = {}
    local radiation = response.radiation
    if radiation.level == nil then
        add(segments, "UNAVAILABLE", uiModule.WARN)
        separator(segments)
        add(segments, tostring(radiation.error or "No reading"), uiModule.BAD)
        return segments
    end
    add(segments, "ONLINE", uiModule.GOOD)
    separator(segments)
    add(segments, "Radiation ", uiModule.MUTED)
    addField(segments, uiModule.metric(radiation.level, "Rads/t"), 15, radiationColor(radiation.level))
    return segments
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

local function drawSegments(x, y, segments)
    for _, segment in ipairs(segments) do
        ui.draw(x, y, segment.text, segment.color)
        x = x + #segment.text
    end
end

local function recordIndicator(record)
    if record.status == "requesting" then return "[" .. SPINNER[spinnerFrame] .. "]", uiModule.WARN end
    if record.status == "error" then return "[!]", uiModule.BAD end
    if record.status == "connected" then return "[+]", uiModule.GOOD end
    return "[ ]", uiModule.MUTED
end

local function draw()
    local width, height = ui.clear()
    local nameWidth = 12
    for _, record in ipairs(records) do nameWidth = math.max(nameWidth, #record.service.displayName) end
    nameWidth = math.min(nameWidth, 32, math.max(12, width - 80))
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

    ui.draw(1, 5, "Metrics updated " .. elapsed(lastPoll), uiModule.MUTED)

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
                local indicator, indicatorColor = recordIndicator(record)
                ui.draw(1, y, "  ", uiModule.TEXT)
                ui.draw(3, y, indicator, indicatorColor)
                local x = 7
                local displayedName = fitted(record.service.displayName, nameWidth)
                ui.draw(x, y, displayedName, uiModule.TEXT)
                x = x + nameWidth
                if record.service.conflict then
                    ui.draw(x, y, "[DUPLICATE] ", uiModule.BAD)
                    x = x + 12
                end
                if record.response then
                    ui.draw(x, y, " | ", uiModule.MUTED)
                    drawSegments(x + 3, y, SUMMARIES[kind.key](record.response))
                elseif record.status == "waiting" then
                    ui.draw(x, y, " | Waiting for first reading", uiModule.MUTED)
                end
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
    pollProgress = record
    spinnerFrame = 1
    draw()

    local spinnerTimer = event.timer(0.2, function()
        if pollProgress == record then
            spinnerFrame = spinnerFrame % #SPINNER + 1
            draw()
        end
    end, math.huge)

    local opened, openError = service.openPort(modem, record.service.servicePort)
    if not opened then
        event.cancel(spinnerTimer)
        record.status = "error"
        record.error = "Could not open port " .. tostring(record.service.servicePort) .. ": " .. tostring(openError)
        return
    end

    local endpoint = rpc.modemUnicast(modem, record.service.address, record.service.servicePort,
        record.kind.protocol, REQUEST_TIMEOUT)
    local response, requestError = endpoint.request(record.kind.requestType)
    event.cancel(spinnerTimer)
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
