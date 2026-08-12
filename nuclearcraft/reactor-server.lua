local component = require("component")
local rpc = require("nuclearcraft.rpc")

local PROTOCOL = "nc-reactor-v1"

local tunnel = component.tunnel
local reactor = component.nc_salt_fission_reactor
local geiger = component.nc_geiger_counter

if not tunnel then error("No tunnel component found") end
if not reactor then error("No nc_salt_fission_reactor found") end
if not geiger then error("No nc_geiger_counter found") end

local endpoint = rpc.tunnel(tunnel, PROTOCOL)

local function safeCall(fn)
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
end

local function simplifyVessel(v)
    local pos = v[1] or {}
    local currentTime = v[3]
    local processTime = v[4]
    local progress = nil
    local progressPercent = nil

    if type(currentTime) == "number" and type(processTime) == "number" and processTime > 0 then
        progress = currentTime / processTime
        progressPercent = progress * 100
    end

    return {
        position = { x = pos[1], y = pos[2], z = pos[3] },
        processing = v[2],
        process = {
            currentTime = currentTime,
            totalTime = processTime,
            progress = progress,
            progressPercent = progressPercent
        },
        heat = v[5],
        efficiency = v[6],
        heatMultiplier = v[7]
    }
end

local function getVessels()
    local raw = safeCall(reactor.getVesselStats)
    local vessels = {}
    if type(raw) ~= "table" then return vessels end

    for _, vessel in ipairs(raw) do
        if type(vessel) == "table" then
            table.insert(vessels, simplifyVessel(vessel))
        end
    end

    return vessels
end

local function getReactorData()
    local heatStored = safeCall(reactor.getHeatStored)
    local heatCapacity = safeCall(reactor.getHeatCapacity)
    local heatPercent = nil

    if type(heatStored) == "number" and type(heatCapacity) == "number" and heatCapacity > 0 then
        heatPercent = heatStored / heatCapacity * 100
    end

    return {
        complete = safeCall(reactor.isComplete),
        reactorOn = safeCall(reactor.isReactorOn),
        size = {
            x = safeCall(reactor.getLengthX),
            y = safeCall(reactor.getLengthY),
            z = safeCall(reactor.getLengthZ)
        },
        heat = {
            stored = heatStored,
            capacity = heatCapacity,
            percent = heatPercent,
            multiplier = safeCall(reactor.getHeatMultiplier),
            rawHeatingRate = safeCall(reactor.getRawHeatingRate),
            netHeatingRate = safeCall(reactor.getNetHeatingRate),
            coolingRate = safeCall(reactor.getCoolingRate),
            coolingEfficiency = safeCall(reactor.getCoolingEfficiency)
        },
        efficiency = { raw = safeCall(reactor.getRawEfficiency) },
        counts = {
            vessels = safeCall(reactor.getNumberOfVessels),
            heaters = safeCall(reactor.getNumberOfHeaters),
            moderators = safeCall(reactor.getNumberOfModerators)
        },
        vessels = getVessels()
    }
end

local function getRadiationData()
    local ok, level = pcall(geiger.getChunkRadiationLevel)
    if not ok then return { level = nil, error = tostring(level) } end
    return { level = level }
end

local function buildResponse(requestType)
    if requestType == "getReactor" then
        return { ok = true, reactor = getReactorData() }
    elseif requestType == "getVessels" then
        return { ok = true, vessels = getVessels() }
    elseif requestType == "getRadiation" then
        return { ok = true, radiation = getRadiationData() }
    elseif requestType == "getAll" then
        return { ok = true, reactor = getReactorData(), radiation = getRadiationData() }
    else
        return { ok = false, error = "Unknown request: " .. tostring(requestType) }
    end
end

print("NC reactor server")
print("=================")
if not geiger then
    print("WARNING: No nc_geiger_counter found; radiation data will be unavailable.")
end
print("Listening for reactor relay on linked card...")
print()

endpoint.serve(buildResponse)
