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

local savedRead = io.read
local selectionPrompts = 0
io.read = function()
    selectionPrompts = selectionPrompts + 1
    return "2"
end
local multipleSelection = serviceSelector.choose({
    { instanceId = "first", displayName = "First", address = "first", servicePort = 1 },
    { instanceId = "second", displayName = "Second", address = "second", servicePort = 1 }
}, { label = "test service" })
io.read = savedRead
assert(multipleSelection.instanceId == "second" and selectionPrompts == 1,
    "service selector did not prompt when multiple services were discovered")

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

local portOpen = false
local openedPort, openPortError = serviceSelector.openPort({
    open = function(port)
        assert(port == 48722)
        portOpen = true
        return nil
    end,
    isOpen = function(port) return port == 48722 and portOpen end
}, 48722)
assert(openedPort and not openPortError, "nil modem.open result was treated as failure despite the port being open")

local openCalls = 0
local alreadyOpen, alreadyOpenError = serviceSelector.openPort({
    open = function() openCalls = openCalls + 1 return false end,
    isOpen = function(port) return port == 48722 end
}, 48722)
assert(alreadyOpen and not alreadyOpenError and openCalls == 0,
    "an already-open application port was treated as failure or reopened")

local function runServer(program, hasTunnel, serviceType, port)
    local advertised
    local configured
    local selectedTransport
    local modem = { open = function(openedPort) assert(openedPort == port) return true end }

    local heatTubes = {}
    local condensationTubes = {}
    for index = 1, 25 do
        heatTubes[index] = { { index, 2, 3 }, 1.1, true, 10, 20, 1.25, 300, 315, "EAST" }
        condensationTubes[index] = {
            { index, 2, 4 }, 0.9, true, 10, 40, 1.1, 373, { 300, 301, 302, 303, 304, 305 }
        }
    end
    local heatExchanger = {
        getExchangerTubeStats = function() return heatTubes end,
        getCondensationTubeStats = function() return condensationTubes end
    }

    package.loaded.component = {
        modem = hasTunnel and nil or modem,
        tunnel = hasTunnel and {} or nil,
        nc_geiger_counter = program == "geiger-server.lua" and {} or nil,
        nc_heat_exchanger = program == "heat-server.lua" and heatExchanger or nil,
        nc_turbine = program == "turbine-server.lua" and {} or nil,
        isAvailable = function(name)
            return name == "nc_geiger_counter" or name == "nc_heat_exchanger" or name == "nc_turbine" or
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
            return { serve = function(handler)
                if program == "heat-server.lua" then
                    local legacy = handler("getAll")
                    assert(legacy.ok and legacy.exchanger and not legacy.exchanger.exchangerTubes,
                        "legacy getAll response still included unbounded tube data")

                    local first = handler("getExchangerTubes:1")
                    local second = handler("getExchangerTubes:" .. tostring(first.nextOffset))
                    local third = handler("getExchangerTubes:" .. tostring(second.nextOffset))
                    local legacyTubes = handler("getExchangerTubes")
                    local condensation = handler("getCondensationTubes:1")
                    assert(#first.tubes == 12 and first.offset == 1 and first.nextOffset == 13 and first.total == 25,
                        "first exchanger tube page was not bounded correctly")
                    assert(#second.tubes == 12 and second.offset == 13 and second.nextOffset == 25,
                        "second exchanger tube page was not bounded correctly")
                    assert(#third.tubes == 1 and third.offset == 25 and third.nextOffset == nil,
                        "final exchanger tube page was not bounded correctly")
                    assert(#legacyTubes.tubes == 12 and legacyTubes.nextOffset == 13,
                        "legacy tube request was not bounded to one page")
                    assert(#condensation.tubes == 12 and condensation.nextOffset == 13,
                        "condensation tube page was not bounded correctly")
                    assert(#serialization.serialize(first) < 8000 and #serialization.serialize(condensation) < 8000,
                        "tube page left insufficient room in an 8192-byte network packet")
                end
                error(COMPLETE)
            end }
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
    local requestedPages = {}
    local function request(requestType)
        if program ~= "heat-client.lua" then return nil end
        local offset = tonumber(tostring(requestType):match("^getExchangerTubes:(%d+)$"))
        assert(offset, "heat client sent an unpaged tube request: " .. tostring(requestType))
        requestedPages[#requestedPages + 1] = offset
        local count = math.min(12, 25 - offset + 1)
        local tubes = {}
        for index = 1, count do tubes[index] = { position = { x = offset + index - 1 } } end
        local nextOffset = offset + count <= 25 and offset + count or nil
        return { ok = true, tubes = tubes, offset = offset, nextOffset = nextOffset, total = 25 }
    end
    local modem = {
        open = function(value) openedPort = value return true end,
        isOpen = function(value) return openedPort == value end
    }

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
        openPort = function(receivedModem, port) return receivedModem.open(port) end,
        choose = function(services, options)
            assert(#services == 1 and options.requested == nil)
            assert(options.configPath == nil, program .. " persisted its service selection")
            assert(options.label and options.title)
            return services[1]
        end
    }
    package.loaded["nuclearcraft.rpc"] = {
        tunnel = function()
            selectedTransport = "tunnel"
            return { request = request }
        end,
        modemUnicast = function(receivedModem, address, receivedPort)
            assert(receivedModem == modem)
            selectedTransport = "modem"
            selectedAddress = address
            selectedPort = receivedPort
            return { request = request }
        end
    }
    package.loaded["nuclearcraft.ui"] = {
        new = function()
            if program == "heat-client.lua" then
                local screen = {}
                function screen.runMenu(_, entries)
                    for _, entry in ipairs(entries) do
                        if entry.key == "2" then return entry.action() end
                    end
                    error("heat client menu omitted exchanger tube details")
                end
                function screen.showResponse(requester, requestType)
                    local response, err = requester(requestType)
                    assert(response and not err and response.ok and #response.tubes == 25,
                        "heat client did not combine every tube page")
                    assert(#requestedPages == 3 and requestedPages[1] == 1 and requestedPages[2] == 13 and
                        requestedPages[3] == 25, "heat client requested incorrect tube page offsets")
                    error(COMPLETE)
                end
                return screen
            end
            return {
                runMenu = function() error(COMPLETE) end,
                runDashboard = function() error(COMPLETE) end
            }
        end
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
runServer("turbine-server.lua", false, "meatballcraft.nc.turbine", 48724)
runServer("geiger-server.lua", false, "meatballcraft.nc.geiger", 48721)
runClient("heat-client.lua", false, "meatballcraft.nc.heat-exchanger", 48722)
runClient("turbine-client.lua", false, "meatballcraft.nc.turbine", 48724)
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
runClientWithNoServices("turbine-client.lua")
runClientWithNoServices("geiger-client.lua")

print("NuclearCraft service discovery integration test complete")
