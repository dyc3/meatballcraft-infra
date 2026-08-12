local component = require("component")
local discovery = require("meatball.discovery")
local filesystem = require("filesystem")
local rpc = require("nuclearcraft.rpc")
local serialization = require("serialization")
local service = require("nuclearcraft.service")

assert(_OSVERSION == "OpenOS 1.8.9", "expected OpenOS 1.8.9")
assert(component.isAvailable("computer"), "computer component is missing")
assert(component.isAvailable("gpu"), "GPU component is missing")
assert(component.isAvailable("screen"), "screen component is missing")
assert(type(rpc.modem) == "function", "repository libraries are not on package.path")
assert(type(rpc.modemUnicast) == "function", "correlated RPC is not on package.path")
assert(type(discovery.find) == "function", "service discovery library is not on package.path")
assert(type(service.choose) == "function", "NuclearCraft service selector is not on package.path")

local mount
for proxy, path in filesystem.mounts() do
    if proxy.getLabel() == "e2e" then mount = path break end
end
assert(mount, "e2e filesystem was not mounted")
local manifestFile = assert(io.open(mount .. "/repo/programs.cfg", "r"))
local manifest = assert(serialization.unserialize(manifestFile:read("*a")))
manifestFile:close()
local discoverySource = "master/service-discovery/lib/meatball/discovery.lua"
for _, packageName in ipairs({
    "nc-geiger-client", "nc-geiger-server", "nc-heat-client", "nc-heat-server",
    "nc-reactor-client", "nc-reactor-relay"
}) do
    assert(manifest[packageName].files[discoverySource] == "/lib/meatball",
        packageName .. " updates do not install the discovery library")
end

local width, height = component.gpu.getResolution()
assert(width > 0 and height > 0, "GPU has no usable resolution")

print("OpenComputers end-to-end smoke test passed")
