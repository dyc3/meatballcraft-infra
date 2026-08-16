local realComponent = require("component")

assert(realComponent.isAvailable("tunnel"), "reactor fixture has no Linked Card")

local reactorOn = true
local failedDeactivation = false
local failedActivation = false
local heatReads = 0
local reactor = setmetatable({
    activate = function()
        if not failedActivation then
            failedActivation = true
            error("fixture actuator failure")
        end
        reactorOn = true
    end,
    deactivate = function()
        if not failedDeactivation then
            failedDeactivation = true
            error("fixture actuator failure")
        end
        reactorOn = false
    end,
    isComplete = function() return true end,
    isReactorOn = function() return reactorOn end,
    getLengthX = function() return 3 end,
    getLengthY = function() return 3 end,
    getLengthZ = function() return 3 end,
    getHeatStored = function()
        heatReads = heatReads + 1
        return heatReads == 1 and 49 or 51
    end,
    getHeatCapacity = function() return 100 end,
    getHeatMultiplier = function() return 1 end,
    getRawHeatingRate = function() return 0 end,
    getNetHeatingRate = function() return 0 end,
    getCoolingRate = function() return 0 end,
    getCoolingEfficiency = function() return 1 end,
    getRawEfficiency = function() return 1 end,
    getNumberOfVessels = function() return 0 end,
    getNumberOfHeaters = function() return 0 end,
    getNumberOfModerators = function() return 0 end,
    getVesselStats = function() return {} end
}, {
    __index = function(_, method)
        error("Unexpected nc_salt_fission_reactor method: " .. tostring(method))
    end
})

package.loaded.component = {
    tunnel = realComponent.tunnel,
    nc_salt_fission_reactor = reactor,
    nc_geiger_counter = setmetatable({
        getChunkRadiationLevel = function() return 0 end
    }, {
        __index = function(_, method)
            error("Unexpected nc_geiger_counter method: " .. tostring(method))
        end
    })
}

assert(loadfile("/repo/nuclearcraft/reactor-server.lua"))()
