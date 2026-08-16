local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local service = require("nuclearcraft.service")
local shell = require("shell")

local PORT = 48722
local PROTOCOL = "nc-heat-exchanger-v1"
local SERVICE_TYPE = "meatballcraft.nc.heat-exchanger"
local API_VERSION = 1
local CONFIG_PATH = "/etc/nuclearcraft/heat-server.cfg"
local TUBE_PAGE_SIZE = 12

local args, options = shell.parse(...)

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("nc_heat_exchanger") then error("No nc_heat_exchanger found") end

local config = service.configure({
    configPath = CONFIG_PATH,
    instanceId = options.id or args[1],
    displayName = options.name or args[2],
    title = "Heat exchanger service setup"
})
local instanceId = config.instanceId
local displayName = config.displayName

local modem = component.modem
local exchanger = component.nc_heat_exchanger
modem.open(PORT)

local endpoint = rpc.modem(modem, PORT, PROTOCOL)
local advertisement, advertiseError = discovery.advertise(modem, {
    serviceType = SERVICE_TYPE,
    instanceId = instanceId,
    displayName = displayName,
    apiVersion = API_VERSION,
    servicePort = PORT
})
if not advertisement then error("Could not advertise heat exchanger: " .. tostring(advertiseError)) end

local function safeCall(fn)
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
end

local function position(raw)
    raw = raw or {}
    return { x = raw[1], y = raw[2], z = raw[3] }
end

local function progressInfo(currentRecipeTime, effectiveProcessTime, speedMultiplier)
    local baseProcessTime = nil
    local progress = nil
    local progressPercent = nil

    if type(effectiveProcessTime) == "number" and type(speedMultiplier) == "number" then
        baseProcessTime = effectiveProcessTime * speedMultiplier
    end

    if type(currentRecipeTime) == "number" and type(baseProcessTime) == "number" and baseProcessTime > 0 then
        progress = currentRecipeTime / baseProcessTime
        progressPercent = progress * 100
    end

    return {
        currentRecipeTime = currentRecipeTime,
        baseProcessTime = baseProcessTime,
        processTime = effectiveProcessTime,
        speedMultiplier = speedMultiplier,
        progress = progress,
        progressPercent = progressPercent
    }
end

local function simplifyExchangerTube(raw)
    local process = progressInfo(raw[4], raw[5], raw[6])
    local inputTemp = raw[7]
    local outputTemp = raw[8]
    local temperatureChange = nil

    if type(inputTemp) == "number" and type(outputTemp) == "number" then
        temperatureChange = outputTemp - inputTemp
    end

    return {
        position = position(raw[1]),
        conductivity = raw[2],
        processing = raw[3],
        process = process,
        temperature = { input = inputTemp, output = outputTemp, change = temperatureChange },
        flowDirection = raw[9]
    }
end

local function simplifyCondensationTube(raw)
    local process = progressInfo(raw[4], raw[5], raw[6])
    local adjacent = raw[8] or {}

    return {
        position = position(raw[1]),
        conductivity = raw[2],
        processing = raw[3],
        process = process,
        condensingTemperature = raw[7],
        adjacentTemperatures = {
            down = adjacent[1],
            up = adjacent[2],
            north = adjacent[3],
            south = adjacent[4],
            west = adjacent[5],
            east = adjacent[6]
        }
    }
end

local function getSummary()
    return {
        complete = safeCall(exchanger.isComplete),
        active = safeCall(exchanger.isHeatExchangerOn),
        size = {
            x = safeCall(exchanger.getLengthX),
            y = safeCall(exchanger.getLengthY),
            z = safeCall(exchanger.getLengthZ)
        },
        fractionActive = safeCall(exchanger.getFractionOfTubesActive),
        efficiency = safeCall(exchanger.getMeanEfficiency),
        counts = {
            exchanger = safeCall(exchanger.getNumberOfExchangerTubes),
            condensation = safeCall(exchanger.getNumberOfCondensationTubes)
        }
    }
end

local function page(values, offset, simplify)
    if type(values) ~= "table" then values = {} end
    offset = math.max(1, math.floor(tonumber(offset) or 1))
    local result = {}
    local last = math.min(#values, offset + TUBE_PAGE_SIZE - 1)
    for index = offset, last do result[#result + 1] = simplify(values[index]) end
    local nextOffset = last < #values and last + 1 or nil
    return {
        ok = true,
        tubes = result,
        offset = offset,
        nextOffset = nextOffset,
        total = #values
    }
end

local function buildResponse(requestType)
    local pagedType, offset = tostring(requestType):match("^(get[%a]+):(%d+)$")
    if requestType == "getSummary" then
        return { ok = true, exchanger = getSummary() }
    elseif requestType == "getExchangerTubes" or pagedType == "getExchangerTubes" then
        return page(safeCall(exchanger.getExchangerTubeStats), offset, simplifyExchangerTube)
    elseif requestType == "getCondensationTubes" or pagedType == "getCondensationTubes" then
        return page(safeCall(exchanger.getCondensationTubeStats), offset, simplifyCondensationTube)
    elseif requestType == "getAll" then
        -- Keep this legacy request bounded for older dashboards and clients.
        return { ok = true, exchanger = getSummary() }
    else
        return { ok = false, error = "Unknown request: " .. tostring(requestType) }
    end
end

print("NC Heat Exchanger Server")
print("========================")
print("Identity: " .. instanceId)
print("Name: " .. displayName)
print("Port: " .. PORT)
print("Discovery port: " .. discovery.PORT)
print("Listening...")

endpoint.serve(buildResponse)
