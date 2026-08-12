local filesystem = require("filesystem")
local serialization = require("serialization")

local mount
for proxy, path in filesystem.mounts() do
    if proxy.getLabel() == "e2e" then mount = path break end
end
assert(mount, "e2e filesystem was not mounted")

local manifestFile = assert(io.open(mount .. "/repo/programs.cfg", "r"))
local manifest = assert(serialization.unserialize(manifestFile:read("*a")))
manifestFile:close()

local packageName = "nc-reactor-client"
local packageInfo = assert(manifest[packageName], "reactor client package is missing")
local installRoot = "/tmp/package-install"

for source, destination in pairs(packageInfo.files) do
    local relativeSource = assert(source:match("^master/(.+)$"), "package source is not on master: " .. source)
    local filename = assert(relativeSource:match("([^/]+)$"))
    local targetDirectory = filesystem.concat(installRoot, destination)
    assert(filesystem.makeDirectory(targetDirectory) or filesystem.isDirectory(targetDirectory))
    local copied, copyError = filesystem.copy(mount .. "/repo/" .. relativeSource,
        filesystem.concat(targetDirectory, filename))
    assert(copied, copyError)
end

local systemPath = "/lib/?.lua;/usr/lib/?.lua;/lib/?/init.lua;/usr/lib/?/init.lua"
package.path = installRoot .. "/lib/?.lua;" .. installRoot .. "/lib/?/init.lua;" .. systemPath

for _, moduleName in ipairs({ "meatball.discovery", "nuclearcraft.rpc", "nuclearcraft.service", "nuclearcraft.ui" }) do
    local path = assert(package.searchpath(moduleName, package.path), "installed package is missing " .. moduleName)
    assert(path:sub(1, #installRoot) == installRoot, moduleName .. " leaked in from the repository test environment")
end

package.loaded["nuclearcraft.rpc"] = nil
package.loaded["meatball.discovery"] = {
    find = function()
        return {
            {
                instanceId = "installed-reactor",
                displayName = "Installed Reactor",
                address = "installed-relay",
                servicePort = 48723
            }
        }
    end
}
package.loaded["nuclearcraft.service"] = {
    choose = function(services) return services[1] end
}
package.loaded["nuclearcraft.ui"] = {
    new = function() return { runMenu = function() error("installed package launched") end } end
}

local openedPort
package.loaded.component = {
    gpu = {},
    modem = {
        open = function(port) openedPort = port return true end,
        send = function() end
    },
    isAvailable = function(name) return name == "gpu" or name == "modem" end
}

local client = assert(loadfile(installRoot .. "/bin/reactor-client.lua"))
local ok, reason = pcall(client)
assert(not ok and tostring(reason):find("installed package launched", 1, true), tostring(reason))
assert(openedPort == 48723, "installed client did not open the discovered service port")

print("package-shaped installation test complete")
