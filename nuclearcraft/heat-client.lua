local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local serviceSelector = require("nuclearcraft.service")
local shell = require("shell")
local uiModule = require("nuclearcraft.ui")

local PROTOCOL = "nc-heat-exchanger-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2
local SERVICE_TYPE = "meatballcraft.nc.heat-exchanger"
local API_VERSION = 1
local DISCOVERY_TIMEOUT = 1

local _, options = shell.parse(...)

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("gpu") then error("No GPU found") end

local modem = component.modem
local gpu = component.gpu
local services, findError = serviceSelector.discover(discovery, modem, {
    serviceType = SERVICE_TYPE,
    apiVersion = API_VERSION,
    timeout = DISCOVERY_TIMEOUT,
    label = "heat exchanger"
})
if not services then
    io.stderr:write("ERROR: ", tostring(findError), "\n")
    return
end

local selectedService, selectionError = serviceSelector.choose(services, {
    requested = options.exchanger,
    label = "heat exchanger",
    title = "Heat exchangers"
})
if not selectedService then
    io.stderr:write("ERROR: ", tostring(selectionError), "\n")
    return
end
local opened, openError = serviceSelector.openPort(modem, selectedService.servicePort)
if not opened then
    io.stderr:write("ERROR: Discovered ", selectedService.displayName, ", but could not open application port ",
        tostring(selectedService.servicePort), ": ", tostring(openError), "\n")
    return
end

local endpoint = rpc.modemUnicast(modem, selectedService.address, selectedService.servicePort, PROTOCOL, TIMEOUT)
local request = endpoint.request
local ui = uiModule.new(gpu)

local MUTED = uiModule.MUTED
local HEADER = uiModule.HEADER
local GOOD = uiModule.GOOD
local WARN = uiModule.WARN
local BAD = uiModule.BAD

local n = uiModule.number
local pct = uiModule.percentage
local pos = uiModule.position
local newLines = ui.newLines
local add = ui.add
local blank = ui.blank
local header = ui.header

local function requestTubePages(requestType)
    local tubes = {}
    local offset = 1

    while offset do
        local response, err = request(requestType .. ":" .. tostring(offset))
        if not response then return nil, err end
        if not response.ok or type(response.tubes) ~= "table" then return response end
        for _, tube in ipairs(response.tubes) do tubes[#tubes + 1] = tube end

        local nextOffset = response.nextOffset
        if nextOffset == nil then
            offset = nil
        elseif type(nextOffset) ~= "number" or nextOffset <= offset then
            return nil, "Server returned invalid tube pagination metadata"
        else
            offset = nextOffset
        end
    end

    return { ok = true, tubes = tubes }
end

local function buildSummary(e)
    local lines = newLines()
    header(lines, "HEAT EXCHANGER")
    add(lines, "--------------------------------", MUTED)
    add(lines, "State: " .. (e.active and "ONLINE" or "OFFLINE"), e.active and GOOD or WARN)
    add(lines, "Structure: " .. (e.complete and "COMPLETE" or "INVALID"), e.complete and GOOD or BAD)
    if e.size then add(lines, "Size: " .. n(e.size.x) .. " x " .. n(e.size.y) .. " x " .. n(e.size.z)) end
    blank(lines)
    add(lines, "Mean efficiency: " .. n(e.efficiency))
    if e.fractionActive ~= nil then add(lines, "Tubes active: " .. pct(e.fractionActive * 100)) end
    if e.counts then
        add(lines, "Exchanger tubes: " .. n(e.counts.exchanger))
        add(lines, "Condensation tubes: " .. n(e.counts.condensation))
    end
    return lines
end

local function buildExchangerTubes(tubes)
    local lines = newLines()
    header(lines, "EXCHANGER TUBES")
    add(lines, "--------------------------------", MUTED)

    for i, t in ipairs(tubes or {}) do
        blank(lines)
        add(lines, string.format("[%d] %s @ %s", i, t.processing and "RUNNING" or "IDLE", pos(t.position)),
            t.processing and GOOD or MUTED)
        add(lines,
            string.format(" Conductivity %s | Speed x%s | %s", n(t.conductivity),
                n(t.process and t.process.speedMultiplier), tostring(t.flowDirection or "?")))
        if t.process then add(lines,
                " Progress " .. pct(t.process.progressPercent) .. " | " .. n(t.process.processTime) .. " ticks/op") end
        if t.temperature then
            local change = t.temperature.change
            local sign = type(change) == "number" and change > 0 and "+" or ""
            add(lines,
                " Temp " ..
                n(t.temperature.input) .. " K -> " .. n(t.temperature.output) .. " K (" .. sign .. n(change) .. " K)")
        end
    end

    if #(tubes or {}) == 0 then add(lines, "No exchanger tubes.") end
    return lines
end

local function buildCondensationTubes(tubes)
    local lines = newLines()
    header(lines, "CONDENSATION TUBES")
    add(lines, "--------------------------------", MUTED)

    for i, t in ipairs(tubes or {}) do
        blank(lines)
        add(lines, string.format("[%d] %s @ %s", i, t.processing and "RUNNING" or "IDLE", pos(t.position)),
            t.processing and GOOD or MUTED)
        add(lines, " Conductivity " .. n(t.conductivity) .. " | Speed x" .. n(t.process and t.process.speedMultiplier))
        if t.process then add(lines,
                " Progress " .. pct(t.process.progressPercent) .. " | " .. n(t.process.processTime) .. " ticks/op") end
        add(lines, " Condensing temp: " .. n(t.condensingTemperature) .. " K")
        local a = t.adjacentTemperatures
        if a then
            add(lines, " Adj D/U: " .. n(a.down) .. " / " .. n(a.up) .. " K")
            add(lines, " Adj N/S: " .. n(a.north) .. " / " .. n(a.south) .. " K")
            add(lines, " Adj W/E: " .. n(a.west) .. " / " .. n(a.east) .. " K")
        end
    end

    if #(tubes or {}) == 0 then add(lines, "No condensation tubes.") end
    return lines
end

local drawAt = ui.draw

local function drawDashboard(response, err, status)
    local width, height = ui.clear()

    drawAt(1, 1, "HEAT EXCHANGER DASHBOARD", HEADER)
    if status == "requesting" then
        drawAt(math.max(1, width - 11), 1, "REQUESTING", WARN)
    elseif err then
        local text = "ERROR " .. tostring(err)
        drawAt(math.max(1, width - #text + 1), 1, text, BAD)
    else
        drawAt(math.max(1, width - 8), 1, "CONNECTED", GOOD)
    end

    if not response or not response.exchanger then
        drawAt(1, 3, status == "requesting" and "Request sent; waiting for response..." or
            "No valid heat exchanger data received.", WARN)
        return
    end

    local e = response.exchanger
    drawAt(1, 3, "State: " .. (e.active and "ONLINE" or "OFFLINE"), e.active and GOOD or WARN)
    drawAt(22, 3, "Complete: " .. tostring(e.complete), e.complete and GOOD or BAD)
    if e.size then drawAt(45, 3, "Size " .. n(e.size.x) .. "x" .. n(e.size.y) .. "x" .. n(e.size.z), MUTED) end
    drawAt(1, 5, "Efficiency: " .. n(e.efficiency))
    drawAt(25, 5, "Active tubes: " .. pct((e.fractionActive or 0) * 100))
    if e.counts then drawAt(1, 6,
            "Exchanger tubes: " .. n(e.counts.exchanger) .. "   Condensers: " .. n(e.counts.condensation)) end

    drawAt(1, height, "Refresh " .. REFRESH_INTERVAL .. "s   q=back   r=refresh", MUTED)
end

local function dashboard()
    ui.runDashboard(REFRESH_INTERVAL, function() return request("getSummary") end, drawDashboard, "exchanger")
end

ui.runMenu("NC Heat Exchanger - " .. selectedService.displayName .. string.format(" [%d discovered]", #services), {
    { key = "1", label = "Summary", action = function()
        ui.showResponse(request, "getSummary", buildSummary, "exchanger")
    end },
    { key = "2", label = "Exchanger tubes", action = function()
        ui.showResponse(requestTubePages, "getExchangerTubes", buildExchangerTubes, "tubes")
    end },
    { key = "3", label = "Condensation tubes", action = function()
        ui.showResponse(requestTubePages, "getCondensationTubes", buildCondensationTubes, "tubes")
    end },
    { key = "4", label = "Live dashboard", action = dashboard }
})
