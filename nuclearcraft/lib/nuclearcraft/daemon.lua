local shell = require("shell")
local thread = require("thread")

local daemon = {}

function daemon.new(command)
    local worker
    local service = {}

    function service.start()
        if worker and worker:status() ~= "dead" then return end

        worker = thread.create(function()
            local ok, reason = shell.execute(command)
            if not ok then error(reason or (command .. " failed")) end
        end)

        if worker:status() == "dead" then
            worker = nil
            error(command .. " exited during startup")
        end

        worker:detach()
    end

    function service.stop()
        if worker and worker:status() ~= "dead" then worker:kill() end
        worker = nil
    end

    function service.status()
        local state = worker and worker:status() or "stopped"
        if state == "dead" then state = "stopped" end
        print(command .. " is " .. state)
    end

    return service
end

return daemon
