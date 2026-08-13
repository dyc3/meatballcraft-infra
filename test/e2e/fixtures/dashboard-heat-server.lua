local realComponent = require("component")

local values = {
    isComplete = true,
    isHeatExchangerOn = true,
    getLengthX = 3,
    getLengthY = 4,
    getLengthZ = 5,
    getFractionOfTubesActive = 0.5,
    getMeanEfficiency = 0.8,
    getNumberOfExchangerTubes = 1,
    getNumberOfCondensationTubes = 1,
    getExchangerTubeStats = {},
    getCondensationTubeStats = {}
}

local exchanger = setmetatable({}, {
    __index = function(_, method)
        local value = values[method]
        if value == nil then error("Unexpected nc_heat_exchanger method: " .. tostring(method)) end
        return function() return value end
    end
})

package.loaded.component = setmetatable({
    modem = realComponent.modem,
    nc_heat_exchanger = exchanger,
    isAvailable = function(name)
        if name == "nc_heat_exchanger" then return true end
        return realComponent.isAvailable(name)
    end
}, { __index = realComponent })

local server = assert(loadfile("/repo/nuclearcraft/heat-server.lua"))
server("--id=heat-e2e", "--name=E2E Heat Exchanger")
