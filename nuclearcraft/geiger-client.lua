local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local serviceSelector = require("nuclearcraft.service")
local shell = require("shell")
local uiModule = require("nuclearcraft.ui")

local PROTOCOL = "nc-geiger-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2
local SERVICE_TYPE = "meatballcraft.nc.geiger"
local API_VERSION = 1
local DISCOVERY_TIMEOUT = 1
local CONFIG_PATH = "/etc/nuclearcraft/geiger-client.cfg"

local _, options = shell.parse(...)

if not component.isAvailable("gpu") then error("No GPU found") end

local gpu = component.gpu
local endpoint
local selectedService

if component.isAvailable("tunnel") then
    endpoint = rpc.tunnel(component.tunnel, PROTOCOL, TIMEOUT)
else
    if not component.isAvailable("modem") then
        error("No Linked Card or Network Card found (missing 'tunnel' and 'modem' components)")
    end
    local modem = component.modem
    local services, findError = discovery.find(modem, {
        serviceType = SERVICE_TYPE,
        apiVersion = API_VERSION,
        timeout = DISCOVERY_TIMEOUT
    })
    if not services then error("Could not discover Geiger counters: " .. tostring(findError)) end

    selectedService = serviceSelector.choose(services, {
        requested = options.geiger,
        configPath = CONFIG_PATH,
        label = "Geiger counter",
        title = "Geiger counters"
    })
    modem.open(selectedService.servicePort)
    endpoint = rpc.modemUnicast(modem, selectedService.address, selectedService.servicePort, PROTOCOL, TIMEOUT)
end

local request = endpoint.request
local ui = uiModule.new(gpu)

local MUTED = uiModule.MUTED
local HEADER = uiModule.HEADER
local GOOD = uiModule.GOOD
local WARN = uiModule.WARN
local BAD = uiModule.BAD

local function formatRadiation(value)
    return uiModule.metric(value, "Rads/t")
end

local function buildRadiation(radiation)
    local lines = ui.newLines()
    ui.header(lines, "RADIATION")
    ui.add(lines, "--------------------------------", MUTED)
    if radiation and radiation.level ~= nil then
        ui.add(lines, "Chunk radiation: " .. formatRadiation(radiation.level))
    else
        ui.add(lines, "Chunk radiation unavailable", WARN)
    end
    if radiation and radiation.error then ui.add(lines, tostring(radiation.error), BAD) end
    return lines
end

local function drawDashboard(response, err)
    local width, height = ui.clear()

    ui.draw(1, 1, "NC GEIGER COUNTER", HEADER)
    if err then
        local text = "ERROR " .. tostring(err)
        ui.draw(math.max(1, width - #text + 1), 1, text, BAD)
    else
        ui.draw(math.max(1, width - 8), 1, "CONNECTED", GOOD)
    end

    if response and response.radiation then
        local radiation = response.radiation
        if radiation.level ~= nil then
            ui.draw(1, 4, "Chunk radiation: " .. formatRadiation(radiation.level))
        else
            ui.draw(1, 4, "Chunk radiation unavailable", WARN)
        end
        if radiation.error then ui.draw(1, 6, tostring(radiation.error), BAD) end
    else
        ui.draw(1, 4, "Waiting for radiation data...", WARN)
    end

    ui.draw(1, height, "Refresh " .. REFRESH_INTERVAL .. "s   q=back   r=refresh", MUTED)
end

local function dashboard()
    ui.runDashboard(REFRESH_INTERVAL, function() return request("getRadiation") end, drawDashboard)
end

local menuTitle = "NC Geiger Counter"
if selectedService then menuTitle = menuTitle .. " - " .. selectedService.displayName end

ui.runMenu(menuTitle, {
    { key = "1", label = "Current radiation", action = function()
        ui.showResponse(request, "getRadiation", buildRadiation, "radiation")
    end },
    { key = "2", label = "Live dashboard", action = dashboard }
})
