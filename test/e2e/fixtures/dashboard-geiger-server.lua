local realComponent = require("component")

local geiger = {
    getChunkRadiationLevel = function() return 0.00042 end
}

package.loaded.component = setmetatable({
    modem = realComponent.modem,
    nc_geiger_counter = geiger,
    isAvailable = function(name)
        if name == "nc_geiger_counter" then return true end
        if name == "tunnel" then return false end
        return realComponent.isAvailable(name)
    end
}, { __index = realComponent })

local server = assert(loadfile("/repo/nuclearcraft/geiger-server.lua"))
server("--id=geiger-e2e", "--name=E2E Geiger Counter")
