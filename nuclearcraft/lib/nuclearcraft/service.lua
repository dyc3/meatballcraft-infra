local filesystem = require("filesystem")
local serialization = require("serialization")

local service = {}

local function loadConfig(path)
    if not path then return {} end
    local file = io.open(path, "r")
    if not file then return {} end
    local encoded = file:read("*a")
    file:close()
    local ok, config = pcall(serialization.unserialize, encoded)
    if ok and type(config) == "table" then return config end
    return {}
end

local function saveConfig(path, config)
    if not path then return true end
    local directory = filesystem.path(path)
    if not filesystem.isDirectory(directory) then
        local made, reason = filesystem.makeDirectory(directory)
        if not made then return nil, reason end
    end
    local file, reason = io.open(path, "w")
    if not file then return nil, reason end
    local ok, encoded = pcall(serialization.serialize, config)
    if not ok then
        file:close()
        return nil, encoded
    end
    local written, writeReason = file:write(encoded)
    file:close()
    if not written then return nil, writeReason end
    return true
end

local function loadPreferredInstance(path)
    local config = loadConfig(path)
    if type(config.instanceId) == "string" then return config.instanceId end
end

local function savePreferredInstance(path, instanceId)
    return saveConfig(path, { instanceId = instanceId })
end

local function nonEmpty(value)
    return type(value) == "string" and value:find("%S") ~= nil
end

local function promptRequired(prompt)
    while true do
        io.write(prompt)
        local value = io.read()
        if value == nil then error("Service setup cancelled") end
        if nonEmpty(value) then return value end
        print("A value is required.")
    end
end

function service.configure(options)
    options = options or {}
    if not options.configPath then error("configPath is required") end

    if options.instanceId ~= nil and not nonEmpty(options.instanceId) then
        error("--id must be a non-empty string")
    end
    if options.displayName ~= nil and not nonEmpty(options.displayName) then
        error("--name must be a non-empty string")
    end

    local saved = loadConfig(options.configPath)
    local instanceId = options.instanceId
    if instanceId == nil and nonEmpty(saved.instanceId) then instanceId = saved.instanceId end
    local displayName = options.displayName
    if displayName == nil and nonEmpty(saved.displayName) then displayName = saved.displayName end

    if not instanceId then
        local title = options.title or "Service discovery setup"
        print(title)
        print(string.rep("=", #title))
        print("Choose a stable ID. Clients remember this ID across server restarts.")
        instanceId = promptRequired("Service ID: ")
    end

    if not displayName and options.instanceId ~= nil then displayName = instanceId end
    if not displayName then
        io.write("Display name [" .. instanceId .. "]: ")
        local entered = io.read()
        if entered == nil then error("Service setup cancelled") end
        displayName = nonEmpty(entered) and entered or instanceId
    end

    local config = { instanceId = instanceId, displayName = displayName }
    local savedOk, reason = saveConfig(options.configPath, config)
    if not savedOk then error("Could not save service configuration: " .. tostring(reason)) end
    return config
end

local function matchingInstance(services, instanceId)
    if not instanceId then return nil, 0 end
    local match
    local count = 0
    for _, candidate in ipairs(services) do
        if candidate.instanceId == instanceId then
            match = candidate
            count = count + 1
        end
    end
    return match, count
end

function service.choose(services, options)
    options = options or {}
    local label = options.label or "service"
    if type(services) ~= "table" or #services == 0 then error("No " .. label .. " services found on the modem network") end

    local preferred = options.requested or loadPreferredInstance(options.configPath)
    local matched, matchCount = matchingInstance(services, preferred)
    local selected

    if matchCount == 1 then
        selected = matched
    elseif options.requested then
        if matchCount == 0 then error("Requested " .. label .. " not found: " .. options.requested) end
        error("Requested " .. label .. " identity is duplicated: " .. options.requested)
    elseif #services == 1 then
        selected = services[1]
    else
        print(options.title or "Available services")
        print(string.rep("=", #(options.title or "Available services")))
        for index, candidate in ipairs(services) do
            local conflict = candidate.conflict and " [DUPLICATE ID]" or ""
            print(string.format("%d. %s (%s)%s", index, candidate.displayName, candidate.instanceId, conflict))
        end
        print()

        while not selected do
            io.write("Select " .. label .. " [1-" .. tostring(#services) .. "]: ")
            local choice = tonumber(io.read())
            if choice and choice == math.floor(choice) then selected = services[choice] end
            if not selected then print("Invalid selection.") end
        end
    end

    local saved, reason = savePreferredInstance(options.configPath, selected.instanceId)
    if not saved then io.stderr:write("Warning: could not save ", label, " selection: ", tostring(reason), "\n") end
    return selected
end

return service
