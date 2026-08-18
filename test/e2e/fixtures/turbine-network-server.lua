local realComponent = require("component")

local values = {
    isComplete = true,
    isTurbineOn = true,
    isProcessing = true,
    getEnergyStored = 750000,
    getEnergyCapacity = 1000000,
    getPower = 12345,
    getCoilConductivity = 0.9,
    getFlowDirection = "EAST",
    getTotalExpansionLevel = 3.6,
    getIdealTotalExpansionLevel = 4.0,
    getExpansionLevels = { 1.8, 2.0 },
    getIdealExpansionLevels = { 2.0, 2.0 },
    getBladeEfficiencies = { 0.8, 0.9 },
    getInputRate = 400,
    getLengthX = 5,
    getLengthY = 7,
    getLengthZ = 9,
    getNumberOfDynamoCoils = 2,
    getNumberOfCoilConnectors = 1,
    getDynamoCoilStats = {
        { { 10, 20, 30 }, "magnesium", true },
        { { 11, 20, 30 }, "beryllium", false }
    }
}

local turbine = setmetatable({}, {
    __index = function(_, method)
        local value = values[method]
        if value == nil then error("Unexpected nc_turbine method: " .. tostring(method)) end
        return function()
            if type(value) == "table" and method ~= "getDynamoCoilStats" then return table.unpack(value) end
            return value
        end
    end
})

package.loaded.component = setmetatable({
    modem = realComponent.modem,
    nc_turbine = turbine,
    isAvailable = function(name)
        if name == "nc_turbine" then return true end
        return realComponent.isAvailable(name)
    end
}, { __index = realComponent })

local server = assert(loadfile("/repo/nuclearcraft/turbine-server.lua"))
server("--id=turbine-e2e", "--name=E2E Turbine")
