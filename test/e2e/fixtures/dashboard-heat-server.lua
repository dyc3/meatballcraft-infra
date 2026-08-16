local realComponent = require("component")

local exchangerTubes = {}
local condensationTubes = {}
for index = 1, 64 do
    exchangerTubes[index] = {
        { index, 2, 3 }, 1.1, true, 10, 20, 1.25, 300, 315, "EAST"
    }
    condensationTubes[index] = {
        { index, 2, 4 }, 0.9, true, 10, 40, 1.1, 373, { 300, 301, 302, 303, 304, 305 }
    }
end

local values = {
    isComplete = false,
    isHeatExchangerOn = false,
    getLengthX = 3,
    getLengthY = 4,
    getLengthZ = 5,
    getFractionOfTubesActive = 0.5,
    getMeanEfficiency = 0.8,
    getNumberOfExchangerTubes = #exchangerTubes,
    getNumberOfCondensationTubes = #condensationTubes,
    getExchangerTubeStats = exchangerTubes,
    getCondensationTubeStats = condensationTubes
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
