local component = require("component")
local rpc = require("nuclearcraft.rpc")

assert(component.isAvailable("tunnel"), "reactor fixture has no Linked Card")

rpc.tunnel(component.tunnel, "nc-reactor-v1").serve(function(requestType)
    if requestType == "getAll" then
        return {
            ok = true,
            reactor = {
                fixture = "real-three-computer-topology",
                reactorOn = true,
                complete = true,
                vessels = {}
            },
            radiation = { level = 0 }
        }
    end
    return { ok = false, error = "Unknown request: " .. tostring(requestType) }
end)
