local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local serviceSelector = require("nuclearcraft.service")
local shell = require("shell")
local uiModule = require("nuclearcraft.ui")

local PROTOCOL = "nc-turbine-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2
local SERVICE_TYPE = "meatballcraft.nc.turbine"
local API_VERSION = 1
local DISCOVERY_TIMEOUT = 1
local CONFIG_PATH = "/etc/nuclearcraft/turbine-client.cfg"

local _, options = shell.parse(...)

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("gpu") then error("No GPU found") end

local modem = component.modem
local services, findError = serviceSelector.discover(discovery, modem, {
    serviceType = SERVICE_TYPE,
    apiVersion = API_VERSION,
    timeout = DISCOVERY_TIMEOUT,
    label = "turbine"
})
if not services then
    io.stderr:write("ERROR: ", tostring(findError), "\n")
    return
end

local selectedService, selectionError = serviceSelector.choose(services, {
    requested = options.turbine,
    configPath = CONFIG_PATH,
    label = "turbine",
    title = "Turbines"
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
local ui = uiModule.new(component.gpu)
local n = uiModule.number
local pct = uiModule.percentage
local metric = uiModule.metric
local pos = uiModule.position

local function buildDetails(t)
    local lines = ui.newLines()
    ui.header(lines, "TURBINE")
    ui.add(lines, "--------------------------------", uiModule.MUTED)
    ui.add(lines, "State: " .. (t.active and "ONLINE" or "OFFLINE"), t.active and uiModule.GOOD or uiModule.WARN)
    ui.add(lines, "Processing: " .. (t.processing and "YES" or "NO"), t.processing and uiModule.GOOD or uiModule.MUTED)
    ui.add(lines, "Structure: " .. (t.complete and "COMPLETE" or "INVALID"),
        t.complete and uiModule.GOOD or uiModule.BAD)
    if t.size then ui.add(lines, "Size: " .. n(t.size.x) .. " x " .. n(t.size.y) .. " x " .. n(t.size.z)) end
    ui.blank(lines)
    ui.add(lines, "Power: " .. metric(t.power, "RF/t"))
    if t.energy then
        ui.add(lines, "Energy: " .. metric(t.energy.stored, "RF") .. " / " .. metric(t.energy.capacity, "RF") ..
            " (" .. pct(t.energy.percent) .. ")")
    end
    ui.add(lines, "Fluid input: " .. n(t.inputRate) .. " mB/t")
    ui.add(lines, "Flow: " .. tostring(t.flowDirection or "?"))
    ui.add(lines, "Coil conductivity: " .. n(t.coilConductivity))
    if t.expansion then
        ui.add(lines, "Expansion: " .. n(t.expansion.total) .. " / ideal " .. n(t.expansion.ideal))
    end
    if t.counts then
        ui.add(lines, "Coils: " .. n(t.counts.coils) .. " | Connectors: " .. n(t.counts.connectors))
    end

    ui.blank(lines)
    ui.header(lines, "BLADE STAGES")
    for index, stage in ipairs(t.stages or {}) do
        ui.add(lines, string.format("[%d] Expansion %s / %s | Efficiency %s", index, n(stage.expansion),
            n(stage.idealExpansion), pct(type(stage.bladeEfficiency) == "number" and stage.bladeEfficiency * 100 or nil)))
    end
    if #(t.stages or {}) == 0 then ui.add(lines, "No blade stage data.", uiModule.MUTED) end

    ui.blank(lines)
    ui.header(lines, "DYNAMO COILS")
    for index, coil in ipairs(t.coils or {}) do
        ui.add(lines, string.format("[%d] %s @ %s - %s", index, tostring(coil.type or "?"), pos(coil.position),
            coil.valid and "VALID" or "INVALID"), coil.valid and uiModule.GOOD or uiModule.BAD)
    end
    if #(t.coils or {}) == 0 then ui.add(lines, "No dynamo coil data.", uiModule.MUTED) end
    return lines
end

local function drawDashboard(response, err, status)
    local width, height = ui.clear()
    ui.draw(1, 1, "NC TURBINE DASHBOARD", uiModule.HEADER)
    if status == "requesting" then
        ui.draw(math.max(1, width - 11), 1, "REQUESTING", uiModule.WARN)
    elseif err then
        local text = "ERROR " .. tostring(err)
        ui.draw(math.max(1, width - #text + 1), 1, text, uiModule.BAD)
    else
        ui.draw(math.max(1, width - 8), 1, "CONNECTED", uiModule.GOOD)
    end

    if not response or not response.turbine then
        ui.draw(1, 3, status == "requesting" and "Request sent; waiting for turbine response..." or
            "No valid turbine data received.", uiModule.WARN)
        return
    end

    local t = response.turbine
    ui.draw(1, 3, "State: " .. (t.active and "ONLINE" or "OFFLINE"), t.active and uiModule.GOOD or uiModule.WARN)
    ui.draw(22, 3, "Structure: " .. (t.complete and "COMPLETE" or "INVALID"),
        t.complete and uiModule.GOOD or uiModule.BAD)
    ui.draw(1, 5, "Power: " .. metric(t.power, "RF/t"))
    if t.energy then ui.draw(28, 5, "Energy: " .. pct(t.energy.percent)) end
    ui.draw(1, 7, "Input: " .. n(t.inputRate) .. " mB/t")
    ui.draw(28, 7, "Flow: " .. tostring(t.flowDirection or "?"))
    ui.draw(1, 9, "Conductivity: " .. n(t.coilConductivity))
    if t.counts then
        ui.draw(28, 9, "Coils: " .. n(t.counts.coils) .. "   Connectors: " .. n(t.counts.connectors))
    end
    if t.expansion then
        ui.draw(1, 11, "Expansion: " .. n(t.expansion.total) .. " / ideal " .. n(t.expansion.ideal))
    end
    ui.draw(1, 13, "BLADE STAGES", uiModule.HEADER)
    local row = 14
    for index, stage in ipairs(t.stages or {}) do
        if row >= height then break end
        ui.draw(1, row, string.format("%d  expansion %s/%s   efficiency %s", index, n(stage.expansion),
            n(stage.idealExpansion),
            pct(type(stage.bladeEfficiency) == "number" and stage.bladeEfficiency * 100 or nil)))
        row = row + 1
    end
    ui.draw(1, height, "Refresh " .. REFRESH_INTERVAL .. "s   q=back   r=refresh", uiModule.MUTED)
end

local function loadAll() return request("getAll") end

ui.runMenu("NC Turbine - " .. selectedService.displayName .. string.format(" [%d discovered]", #services), {
    { key = "1", label = "Turbine details", action = function()
        ui.showResponse(request, "getAll", buildDetails, "turbine")
    end },
    { key = "2", label = "Live dashboard", action = function()
        ui.runDashboard(REFRESH_INTERVAL, loadAll, drawDashboard, "turbine")
    end }
})
