local realComponent = require("component")
local instanceId, displayName, rawLevel = ...
local level = assert(tonumber(rawLevel), "dashboard Geiger fixture requires a numeric radiation level")

local geiger = {
    getChunkRadiationLevel = function() return level end
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
server("--id=" .. tostring(instanceId), "--name=" .. tostring(displayName))
