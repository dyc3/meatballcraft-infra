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

local declaredOwners = {}
for name, info in pairs(manifest) do
    assert(type(info.files) == "table", name .. " package has no files table")
    for source, destination in pairs(info.files) do
        local relativeSource = assert(source:match("^master/(.+)$"), name .. " source is not on master: " .. source)
        assert(filesystem.exists(mount .. "/repo/" .. relativeSource), name .. " source does not exist: " .. source)
        local filename = assert(relativeSource:match("([^/]+)$"))
        local target = filesystem.concat(destination, filename)
        assert(not declaredOwners[target],
            name .. " and " .. tostring(declaredOwners[target]) .. " both own package target " .. target)
        declaredOwners[target] = name
    end
    for dependency in pairs(info.dependencies or {}) do
        assert(manifest[dependency], name .. " depends on missing package " .. dependency)
    end
end

local installRoot = "/tmp/package-install"
for packageName, packageInfo in pairs(manifest) do
    if packageName:match("^nc%-") and packageName ~= "nc-common" then
        assert(packageInfo.dependencies and packageInfo.dependencies["nc-common"],
            packageName .. " does not depend on nc-common")
        for _, destination in pairs(packageInfo.files) do
            assert(not destination:find("/lib", 1, true), packageName .. " directly owns a shared library")
        end
    end
end

assert(filesystem.makeDirectory(installRoot) or filesystem.isDirectory(installRoot))
local stateFile = assert(io.open("/etc/opdata.svd", "w"))
stateFile:write("{}")
stateFile:close()

local realComponent = require("component")
package.loaded.component = setmetatable({
    gpu = realComponent.gpu,
    isAvailable = function(name)
        if name == "internet" then return true end
        return realComponent.isAvailable(name)
    end
}, { __index = realComponent })

local function read(path)
    local file = assert(io.open(path, "r"), "fake internet source missing: " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

local function response(content)
    local yielded = false
    return function()
        if yielded then return nil end
        yielded = true
        return content
    end
end

package.loaded.internet = {
    request = function(url)
        if url == "https://raw.githubusercontent.com/OpenPrograms/openprograms.github.io/master/repos.cfg" then
            return response("{{repo='dyc3/meatballcraft-infra'}}")
        end
        local prefix = "https://raw.githubusercontent.com/dyc3/meatballcraft-infra/"
        local source = url:sub(1, #prefix) == prefix and url:sub(#prefix + 1) or nil
        assert(source, "unexpected OPPM request: " .. tostring(url))
        return response(read(mount .. "/repo/" .. source:gsub("^master/", "")))
    end
}

local oppmPath = mount .. "/repo/test/e2e/fixtures/oppm-under-test.lua"
local function oppmInstall(packageName)
    local oppm = assert(loadfile(oppmPath))
    local installedOk, installError = pcall(oppm, "install", packageName, installRoot, "--iKnowWhatIAmDoing")
    assert(installedOk, packageName .. " failed through real OPPM: " .. tostring(installError))
end

oppmInstall("nc-reactor-client")
oppmInstall("nc-dashboard")

stateFile = assert(io.open("/etc/opdata.svd", "r"))
local installedPackages = assert(serialization.unserialize(stateFile:read("*a")))
stateFile:close()
assert(installedPackages["nc-reactor-client"], "OPPM did not record nc-reactor-client")
assert(installedPackages["nc-dashboard"], "OPPM did not record nc-dashboard")
assert(installedPackages["nc-common"], "OPPM did not install nc-common dependency")
assert(installedPackages["meatball-discovery"], "OPPM did not install discovery dependency")
assert(installedPackages["nc-common"]["master/nuclearcraft/lib/nuclearcraft/rpc.lua"] ==
    installRoot .. "/lib/nuclearcraft/rpc.lua", "nc-common does not own rpc.lua")
assert(not installedPackages["nc-reactor-client"]["master/nuclearcraft/lib/nuclearcraft/rpc.lua"],
    "reactor client still owns rpc.lua")
assert(not installedPackages["nc-dashboard"]["master/nuclearcraft/lib/nuclearcraft/rpc.lua"],
    "dashboard still owns rpc.lua")

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
    discover = function(discoveryModule, modem, options) return discoveryModule.find(modem, options) end,
    openPort = function(modem, port) return modem.open(port) end,
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
