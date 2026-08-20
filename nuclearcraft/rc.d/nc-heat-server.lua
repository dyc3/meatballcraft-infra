local service = require("nuclearcraft.daemon").new("heat-server")

function start()
    service.start()
end

function stop()
    service.stop()
end

function status()
    service.status()
end
