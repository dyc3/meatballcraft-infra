local component = require("component")
local discovery = require("meatball.discovery")
local rpc = require("nuclearcraft.rpc")
local service = require("nuclearcraft.service")
local shell = require("shell")

local PORT = 48724
local PROTOCOL = "nc-turbine-v1"
local SERVICE_TYPE = "meatballcraft.nc.turbine"
local API_VERSION = 1
local CONFIG_PATH = "/etc/nuclearcraft/turbine-server.cfg"

local args, options = shell.parse(...)

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("nc_turbine") then error("No nc_turbine found") end

local config = service.configure({
    configPath = CONFIG_PATH,
    instanceId = options.id or args[1],
    displayName = options.name or args[2],
    title = "Turbine service setup"
})

local modem = component.modem
local turbine = component.nc_turbine
modem.open(PORT)

local endpoint = rpc.modem(modem, PORT, PROTOCOL)
local advertisement, advertiseError = discovery.advertise(modem, {
    serviceType = SERVICE_TYPE,
    instanceId = config.instanceId,
    displayName = config.displayName,
    apiVersion = API_VERSION,
    servicePort = PORT
})
if not advertisement then error("Could not advertise turbine: " .. tostring(advertiseError)) end

local function safeCall(fn)
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
end

local function safeArray(fn)
    local values = table.pack(pcall(fn))
    if not values[1] then return {} end
    if values.n == 2 and type(values[2]) == "table" then return values[2] end
    local result = {}
    for index = 2, values.n do result[#result + 1] = values[index] end
    return result
end

local function position(raw)
    raw = raw or {}
    return { x = raw[1], y = raw[2], z = raw[3] }
end

local function getCoils()
    local raw = safeCall(turbine.getDynamoCoilStats)
    local result = {}
    if type(raw) ~= "table" then return result end
    for _, coil in ipairs(raw) do
        result[#result + 1] = {
            position = position(coil[1]),
            type = coil[2],
            valid = coil[3]
        }
    end
    return result
end

local function getStages()
    local expansion = safeArray(turbine.getExpansionLevels)
    local ideal = safeArray(turbine.getIdealExpansionLevels)
    local efficiency = safeArray(turbine.getBladeEfficiencies)
    local count = math.max(#expansion, #ideal, #efficiency)
    local result = {}
    for index = 1, count do
        result[index] = {
            expansion = expansion[index],
            idealExpansion = ideal[index],
            bladeEfficiency = efficiency[index]
        }
    end
    return result
end

local function getSummary()
    local energyStored = safeCall(turbine.getEnergyStored)
    local energyCapacity = safeCall(turbine.getEnergyCapacity)
    local energyPercent
    if type(energyStored) == "number" and type(energyCapacity) == "number" and energyCapacity > 0 then
        energyPercent = energyStored / energyCapacity * 100
    end

    return {
        complete = safeCall(turbine.isComplete),
        active = safeCall(turbine.isTurbineOn),
        processing = safeCall(turbine.isProcessing),
        size = {
            x = safeCall(turbine.getLengthX),
            y = safeCall(turbine.getLengthY),
            z = safeCall(turbine.getLengthZ)
        },
        energy = { stored = energyStored, capacity = energyCapacity, percent = energyPercent },
        power = safeCall(turbine.getRawPower),
        inputRate = safeCall(turbine.getInputRate),
        flowDirection = safeCall(turbine.getFlowDirection),
        coilConductivity = safeCall(turbine.getCoilConductivity),
        expansion = {
            total = safeCall(turbine.getTotalExpansionLevel),
            ideal = safeCall(turbine.getIdealTotalExpansionLevel)
        },
        counts = {
            coils = safeCall(turbine.getNumberOfDynamoCoils),
            connectors = safeCall(turbine.getNumberOfCoilConnectors)
        },
        stages = getStages(),
        coils = getCoils()
    }
end

local function buildResponse(requestType)
    if requestType == "getAll" then return { ok = true, turbine = getSummary() } end
    return { ok = false, error = "Unknown request: " .. tostring(requestType) }
end

print("NC Turbine Server")
print("=================")
print("Identity: " .. config.instanceId)
print("Name: " .. config.displayName)
print("Port: " .. PORT)
print("Discovery port: " .. discovery.PORT)
print("Listening...")

endpoint.serve(buildResponse)
