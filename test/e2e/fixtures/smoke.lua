local component = require("component")
local rpc = require("nuclearcraft.rpc")

assert(_OSVERSION == "OpenOS 1.8.9", "expected OpenOS 1.8.9")
assert(component.isAvailable("computer"), "computer component is missing")
assert(component.isAvailable("gpu"), "GPU component is missing")
assert(component.isAvailable("screen"), "screen component is missing")
assert(type(rpc.modem) == "function", "repository libraries are not on package.path")

local width, height = component.gpu.getResolution()
assert(width > 0 and height > 0, "GPU has no usable resolution")

print("OpenComputers end-to-end smoke test passed")
