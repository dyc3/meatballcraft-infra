local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")

local modem = component.modem
local port = 48722
assert(modem.open(port))
assert(discovery.advertise(modem, {
    serviceType = "meatballcraft.nc.heat-exchanger",
    instanceId = "heat-e2e",
    displayName = "E2E Heat Exchanger",
    apiVersion = 1,
    servicePort = port,
    responseJitter = 0
}))

local exchanger = {
    active = true,
    complete = true,
    size = { x = 3, y = 4, z = 5 },
    fractionActive = 0.5,
    efficiency = 0.8,
    counts = { exchanger = 1, condensation = 1 },
    exchangerTubes = {
        {
            position = { x = 10, y = 20, z = 30 },
            conductivity = 1.1,
            processing = true,
            process = { progressPercent = 50, processTime = 20, speedMultiplier = 1.25 },
            temperature = { input = 300, output = 315, change = 15 },
            flowDirection = "EAST"
        }
    },
    condensationTubes = {
        {
            position = { x = 11, y = 20, z = 30 },
            conductivity = 0.9,
            processing = true,
            process = { progressPercent = 25, processTime = 40, speedMultiplier = 1.1 },
            condensingTemperature = 373,
            adjacentTemperatures = { down = 300, up = 301, north = 302, south = 303, west = 304, east = 305 }
        }
    }
}

rpc.modem(modem, port, "nc-heat-exchanger-v1").serve(function(requestType)
    if requestType == "getAll" then return { ok = true, exchanger = exchanger } end
    if requestType == "getSummary" then
        local summary = {}
        for key, value in pairs(exchanger) do
            if key ~= "tubes" and key ~= "networks" then summary[key] = value end
        end
        return { ok = true, exchanger = summary }
    end
    if requestType == "getExchangerTubes" then return { ok = true, tubes = exchanger.exchangerTubes } end
    if requestType == "getCondensationTubes" then return { ok = true, tubes = exchanger.condensationTubes } end
    return { ok = false, error = "Unknown request: " .. tostring(requestType) }
end)
