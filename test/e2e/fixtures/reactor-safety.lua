local COMPLETE = "reactor safety test complete"

local filesystem = require("filesystem")
local mount
for proxy, path in filesystem.mounts() do
    if proxy.getLabel() == "e2e" then
        mount = path
        break
    end
end
assert(mount, "e2e filesystem was not mounted")

local function runScenario(name, samples, expectedDeactivations, deactivationError)
    local sample = 0
    local deactivations = 0
    local timerCallback
    local response

    local reactor = setmetatable({
        getHeatStored = function()
            sample = math.min(sample + 1, #samples)
            return samples[sample]
        end,
        getHeatCapacity = function() return 100 end,
        deactivate = function()
            deactivations = deactivations + 1
            if deactivationError then error(deactivationError) end
        end,
        isComplete = function() return true end,
        isReactorOn = function() return true end,
        getLengthX = function() return 1 end,
        getLengthY = function() return 1 end,
        getLengthZ = function() return 1 end,
        getHeatMultiplier = function() return 1 end,
        getRawHeatingRate = function() return 1 end,
        getNetHeatingRate = function() return 1 end,
        getCoolingRate = function() return 0 end,
        getCoolingEfficiency = function() return 0 end,
        getRawEfficiency = function() return 1 end,
        getNumberOfVessels = function() return 0 end,
        getNumberOfHeaters = function() return 0 end,
        getNumberOfModerators = function() return 0 end,
        getVesselStats = function() return {} end
    }, {
        __index = function(_, method)
            error("Unexpected nc_salt_fission_reactor method: " .. tostring(method))
        end
    })

    package.loaded.component = {
        tunnel = {},
        nc_salt_fission_reactor = reactor,
        nc_geiger_counter = {}
    }
    package.loaded.event = {
        timer = function(interval, callback, times)
            assert(interval == 1, "reactor monitor used the wrong interval")
            assert(times == math.huge, "reactor monitor was not persistent")
            timerCallback = callback
        end
    }
    package.loaded["nuclearcraft.rpc"] = {
        tunnel = function(receivedTunnel, protocol)
            assert(receivedTunnel == package.loaded.component.tunnel)
            assert(protocol == "nc-reactor-v1")
            return {
                serve = function(handler)
                    assert(timerCallback, "reactor monitor did not register a timer")
                    for _ = 2, #samples do timerCallback() end
                    response = handler("getReactor")
                    error(COMPLETE)
                end
            }
        end
    }

    local server = assert(loadfile(mount .. "/repo/nuclearcraft/reactor-server.lua"))
    local ok, reason = pcall(server)
    assert(not ok and tostring(reason):find(COMPLETE, 1, true), tostring(reason))
    assert(deactivations == expectedDeactivations,
        string.format("%s: expected %d deactivation(s), got %d", name, expectedDeactivations, deactivations))
    assert(response and response.ok and response.reactor and response.reactor.failsafe,
        name .. ": reactor response did not include failsafe status")
    local failsafe = response.reactor.failsafe
    assert(failsafe.triggered == (expectedDeactivations > 0), name .. ": failsafe trigger status was wrong")
    if expectedDeactivations > 0 then
        assert(failsafe.reason == "rising_heat" and failsafe.heatPercent == samples[#samples],
            name .. ": failsafe trigger details were wrong")
        assert(failsafe.deactivated == (deactivationError == nil), name .. ": deactivation result was wrong")
        if deactivationError then
            assert(failsafe.error and failsafe.error:find(deactivationError, 1, true),
                name .. ": deactivation error was not reported")
        end
    end
end

runScenario("increasing above threshold", { 49, 50, 51 }, 1)
runScenario("increasing but not over threshold", { 48, 49, 50 }, 0)
runScenario("decreasing above threshold", { 60, 59, 58 }, 0)
runScenario("deactivation failure", { 49, 51 }, 1, "actuator unavailable")

print("PASS: reactor server heat safety monitor")
