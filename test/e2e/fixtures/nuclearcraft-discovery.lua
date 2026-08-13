local filesystem = require("filesystem")
local serialization = require("serialization")

local mount
for proxy, path in filesystem.mounts() do
    if proxy.getLabel() == "e2e" then
        mount = path
        break
    end
end
assert(mount, "e2e filesystem was not mounted")

local COMPLETE = "nuclearcraft discovery transport selected"
local serviceSelector = require("nuclearcraft.service")

local providerConfigPath = "/tmp/nuclearcraft-service-test.cfg"
filesystem.remove(providerConfigPath)
local originalRead = io.read
local originalWrite = io.write
local answers = { "first-service", "First Service" }
local prompts = 0
io.write = function() prompts = prompts + 1 end
io.read = function() return table.remove(answers, 1) end
local firstConfig = serviceSelector.configure({ configPath = providerConfigPath, title = "Test setup" })
assert(firstConfig.instanceId == "first-service" and firstConfig.displayName == "First Service",
    "first-launch setup did not use interactive answers")
assert(prompts == 2, "first-launch setup did not prompt for ID and display name")

io.read = function() error("saved configuration unexpectedly prompted") end
local savedConfig = serviceSelector.configure({ configPath = providerConfigPath })
assert(savedConfig.instanceId == "first-service" and savedConfig.displayName == "First Service",
    "saved provider configuration was not reused")

local overrideConfig = serviceSelector.configure({
    configPath = providerConfigPath,
    instanceId = "override-service",
    displayName = "Override Service"
})
assert(overrideConfig.instanceId == "override-service" and overrideConfig.displayName == "Override Service",
    "CLI-equivalent values did not override saved provider configuration")
io.read = originalRead
io.write = originalWrite

local configFile = assert(io.open(providerConfigPath, "r"))
local persistedConfig = serialization.unserialize(configFile:read("*a"))
configFile:close()
assert(persistedConfig.instanceId == "override-service" and persistedConfig.displayName == "Override Service",
    "overridden provider configuration was not saved")
filesystem.remove(providerConfigPath)

local selected = serviceSelector.choose({
    { instanceId = "only", displayName = "Only Service", address = "only-address", servicePort = 1 }
}, { label = "test service" })
assert(selected.instanceId == "only", "service selector did not automatically choose one result")

local noSelection, noSelectionError = serviceSelector.choose({}, { label = "test service" })
assert(not noSelection and noSelectionError == "No test services found on the modem network",
    "empty service selection threw or returned an unclear error")

local duplicateSelection, duplicateError = serviceSelector.choose({
    { instanceId = "duplicate", displayName = "First", address = "first", servicePort = 1 },
    { instanceId = "duplicate", displayName = "Second", address = "second", servicePort = 1 }
}, { requested = "duplicate", label = "test service" })
assert(not duplicateSelection and tostring(duplicateError):find("duplicated", 1, true),
    "service selector silently chose a duplicated requested identity")

local discoveryOutput = {}
local savedPrint = print
print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
    discoveryOutput[#discoveryOutput + 1] = table.concat(parts, "\t")
end
local discovered, discoveryError = serviceSelector.discover({
    find = function()
        return {}, nil, { offersReceived = 2, offersAccepted = 0, offersRejected = 2 }
    end
}, {}, {
    serviceType = "meatballcraft.nc.reactor",
    apiVersion = 1,
    timeout = 1,
    label = "reactor relay"
})
print = savedPrint
assert(not discovered and discoveryError:find("2 invalid or incompatible offers", 1, true),
    "empty discovery did not explain rejected offers")
local renderedDiscovery = table.concat(discoveryOutput, "\n")
assert(renderedDiscovery:find("Discovering reactor relays", 1, true), "discovery did not show that it was running")
assert(renderedDiscovery:find("0 valid reactor relays discovered", 1, true),
    "discovery did not show its result count")

local function runServer(program, hasTunnel, serviceType, port)
    local advertised
    local configured
    local selectedTransport
    local modem = { open = function(openedPort) assert(openedPort == port) return true end }

    package.loaded.component = {
        modem = hasTunnel and nil or modem,
        tunnel = hasTunnel and {} or nil,
        nc_geiger_counter = program == "geiger-server.lua" and {} or nil,
        nc_heat_exchanger = program == "heat-server.lua" and {} or nil,
        isAvailable = function(name)
            return name == "nc_geiger_counter" or name == "nc_heat_exchanger" or
                (name == "tunnel" and hasTunnel) or (name == "modem" and not hasTunnel)
        end
    }
    package.loaded["meatball.discovery"] = {
        PORT = 48700,
        advertise = function(receivedModem, spec)
            assert(receivedModem == modem)
            advertised = spec
            return { close = function() end }
        end
    }
    package.loaded["nuclearcraft.service"] = {
        configure = function(options)
            configured = options
            return { instanceId = options.instanceId, displayName = options.displayName }
        end
    }
    package.loaded["nuclearcraft.rpc"] = {
        tunnel = function()
            selectedTransport = "tunnel"
            return { serve = function() error(COMPLETE) end }
        end,
        modem = function(receivedModem, receivedPort)
            assert(receivedModem == modem and receivedPort == port)
            selectedTransport = "modem"
            return { serve = function() error(COMPLETE) end }
        end
    }

    local chunk = assert(loadfile(mount .. "/repo/nuclearcraft/" .. program))
    local ok, reason = pcall(chunk, "--id=test-instance", "--name=Test Service")
    assert(not ok and tostring(reason):find(COMPLETE, 1, true), tostring(reason))

    if hasTunnel then
        assert(selectedTransport == "tunnel", program .. " did not use its Linked Card")
        assert(not advertised, program .. " advertised despite using a Linked Card")
        assert(not configured, program .. " configured discovery despite using a Linked Card")
    else
        assert(selectedTransport == "modem", program .. " did not serve over its Network Card")
        assert(configured and configured.configPath and configured.title, program .. " did not configure its identity")
        assert(advertised and advertised.serviceType == serviceType, program .. " advertised the wrong service type")
        assert(advertised.instanceId == "test-instance" and advertised.displayName == "Test Service",
            program .. " lost its configured identity")
        assert(advertised.servicePort == port, program .. " advertised the wrong service port")
    end
end

local function runClient(program, hasTunnel, serviceType, port)
    local discoveryCalls = 0
    local selectedTransport
    local selectedAddress
    local selectedPort
    local openedPort
    local modem = { open = function(value) openedPort = value return true end }

    package.loaded.component = {
        gpu = {},
        modem = hasTunnel and nil or modem,
        tunnel = hasTunnel and {} or nil,
        isAvailable = function(name)
            return name == "gpu" or (name == "tunnel" and hasTunnel) or (name == "modem" and not hasTunnel)
        end
    }
    package.loaded["meatball.discovery"] = {
        find = function(receivedModem, query)
            discoveryCalls = discoveryCalls + 1
            assert(receivedModem == modem and query.serviceType == serviceType and query.apiVersion == 1)
            return {
                {
                    instanceId = "test-instance",
                    displayName = "Test Service",
                    address = "test-server-address",
                    servicePort = port
                }
            }
        end
    }
    package.loaded["nuclearcraft.service"] = {
        discover = function(discoveryModule, receivedModem, options)
            return discoveryModule.find(receivedModem, options)
        end,
        choose = function(services, options)
            assert(#services == 1 and options.requested == nil)
            assert(options.configPath and options.label and options.title)
            return services[1]
        end
    }
    package.loaded["nuclearcraft.rpc"] = {
        tunnel = function()
            selectedTransport = "tunnel"
            return { request = function() end }
        end,
        modemUnicast = function(receivedModem, address, receivedPort)
            assert(receivedModem == modem)
            selectedTransport = "modem"
            selectedAddress = address
            selectedPort = receivedPort
            return { request = function() end }
        end
    }
    package.loaded["nuclearcraft.ui"] = {
        new = function() return { runMenu = function() error(COMPLETE) end } end
    }

    local chunk = assert(loadfile(mount .. "/repo/nuclearcraft/" .. program))
    local ok, reason = pcall(chunk)
    assert(not ok and tostring(reason):find(COMPLETE, 1, true), tostring(reason))

    if hasTunnel then
        assert(selectedTransport == "tunnel", program .. " did not prefer its Linked Card")
        assert(discoveryCalls == 0 and not openedPort, program .. " discovered despite using a Linked Card")
    else
        assert(selectedTransport == "modem" and discoveryCalls == 1, program .. " did not use discovery fallback")
        assert(selectedAddress == "test-server-address" and selectedPort == port and openedPort == port,
            program .. " did not unicast to the discovered endpoint")
    end
end

runServer("geiger-server.lua", true, "meatballcraft.nc.geiger", 48721)
runServer("heat-server.lua", false, "meatballcraft.nc.heat-exchanger", 48722)
runServer("geiger-server.lua", false, "meatballcraft.nc.geiger", 48721)
runClient("heat-client.lua", false, "meatballcraft.nc.heat-exchanger", 48722)
runClient("geiger-client.lua", true, "meatballcraft.nc.geiger", 48721)
runClient("geiger-client.lua", false, "meatballcraft.nc.geiger", 48721)

local function runClientWithNoServices(program)
    local modem = {}
    package.loaded.component = {
        gpu = {},
        modem = modem,
        isAvailable = function(name) return name == "gpu" or name == "modem" end
    }
    package.loaded["meatball.discovery"] = {
        find = function()
            return {}, nil, { offersReceived = 0, offersAccepted = 0, offersRejected = 0 }
        end
    }
    package.loaded["nuclearcraft.service"] = serviceSelector
    package.loaded["nuclearcraft.rpc"] = {
        modemUnicast = function() error("empty discovery unexpectedly constructed an RPC endpoint") end
    }
    package.loaded["nuclearcraft.ui"] = {
        new = function() error("empty discovery unexpectedly opened the UI") end
    }

    local output = {}
    local savedPrint = print
    print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
        output[#output + 1] = table.concat(parts, "\t")
    end
    local chunk = assert(loadfile(mount .. "/repo/nuclearcraft/" .. program))
    local ok, reason = pcall(chunk)
    print = savedPrint
    assert(ok, program .. " emitted a stack trace when discovery returned no services: " .. tostring(reason))
    assert(table.concat(output, "\n"):find("0 valid", 1, true),
        program .. " did not display the empty discovery count")
end

runClientWithNoServices("reactor-client.lua")
runClientWithNoServices("heat-client.lua")
runClientWithNoServices("geiger-client.lua")

print("NuclearCraft service discovery integration test complete")
