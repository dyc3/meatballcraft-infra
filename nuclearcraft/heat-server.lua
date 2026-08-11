local component = require("component")
local event = require("event")
local serialization = require("serialization")

local PORT = 48722
local PROTOCOL = "nc-heat-exchanger-v1"

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("nc_heat_exchanger") then error("No nc_heat_exchanger found") end

local modem = component.modem
local exchanger = component.nc_heat_exchanger
modem.open(PORT)

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

local function getExchangerTubes()
    local raw = safeCall(exchanger.getExchangerTubeStats)
    local result = {}
    if type(raw) ~= "table" then return result end
    for _, tube in ipairs(raw) do table.insert(result, simplifyExchangerTube(tube)) end
    return result
end

local function getCondensationTubes()
    local raw = safeCall(exchanger.getCondensationTubeStats)
    local result = {}
    if type(raw) ~= "table" then return result end
    for _, tube in ipairs(raw) do table.insert(result, simplifyCondensationTube(tube)) end
    return result
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
        },
        exchangerTubes = getExchangerTubes(),
        condensationTubes = getCondensationTubes()
    }
end

local function buildResponse(requestType)
    if requestType == "getSummary" then
        local summary = getSummary()
        summary.exchangerTubes = nil
        summary.condensationTubes = nil
        return { ok = true, exchanger = summary }
    elseif requestType == "getExchangerTubes" then
        return { ok = true, tubes = getExchangerTubes() }
    elseif requestType == "getCondensationTubes" then
        return { ok = true, tubes = getCondensationTubes() }
    elseif requestType == "getAll" then
        return { ok = true, exchanger = getSummary() }
    else
        return { ok = false, error = "Unknown request: " .. tostring(requestType) }
    end
end

print("NC Heat Exchanger Server")
print("========================")
print("Port: " .. PORT)
print("Listening...")

while true do
    local _, _, remoteAddress, port, _, protocol, requestType = event.pull("modem_message")
    if port == PORT and protocol == PROTOCOL then
        local response = buildResponse(requestType)
        modem.send(remoteAddress, PORT, PROTOCOL, "response", serialization.serialize(response))
    end
end
