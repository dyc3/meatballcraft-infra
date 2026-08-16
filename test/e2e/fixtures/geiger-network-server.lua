local realComponent = require("component")

local levels = { 42e-9, 420e-6, 420e-3, 1.2 }
local reading = 0
local geiger = setmetatable({
    getChunkRadiationLevel = function()
        reading = reading % #levels + 1
        return levels[reading]
    end
}, {
    __index = function(_, method)
        error("Unexpected nc_geiger_counter method: " .. tostring(method))
    end
})

package.loaded.component = setmetatable({
    modem = realComponent.modem,
    nc_geiger_counter = geiger,
    isAvailable = function(name)
        if name == "nc_geiger_counter" or name == "modem" then return true end
        if name == "tunnel" then return false end
        return realComponent.isAvailable(name)
    end
}, { __index = realComponent })

local server = assert(loadfile("/repo/nuclearcraft/geiger-server.lua"))
server("--id=geiger-e2e", "--name=E2E Geiger Counter")
