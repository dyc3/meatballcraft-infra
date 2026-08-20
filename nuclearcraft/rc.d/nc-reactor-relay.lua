local service = require("nuclearcraft.daemon").new("reactor-relay")

function start()
    service.start()
end

function stop()
    service.stop()
end

function status()
    service.status()
end
