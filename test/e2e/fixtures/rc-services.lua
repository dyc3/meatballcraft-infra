local computer = require("computer")
local event = require("event")
local shell = require("shell")

local services = {
    "nc-geiger-server",
    "nc-heat-server",
    "nc-reactor-relay",
    "nc-reactor-server",
    "nc-turbine-server"
}

local function startCount(name)
    local file = io.open("/tmp/" .. name .. ".starts", "r")
    if not file then return 0 end
    local count = tonumber(file:read("*a")) or 0
    file:close()
    return count
end

local function waitForStartCount(expected)
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        local ready = true
        for _, name in ipairs(services) do
            if startCount(name) < expected then ready = false break end
        end
        if ready then return end
        event.pull(0.1)
    end
    error("services did not reach start count " .. tostring(expected))
end

waitForStartCount(1)

for _, name in ipairs(services) do
    assert(shell.execute("rc " .. name .. " start"))
end
event.pull(0.5)
for _, name in ipairs(services) do
    assert(startCount(name) == 1, name .. " started twice")
    assert(shell.execute("rc " .. name .. " stop"))
end

for _, name in ipairs(services) do
    assert(shell.execute("rc " .. name .. " start"))
end
waitForStartCount(2)

for _, name in ipairs(services) do
    assert(shell.execute("rc " .. name .. " stop"))
end

print("OpenOS rc service boot test complete")
