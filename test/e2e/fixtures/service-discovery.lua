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

local now = 10
local listeners = {}
local queued = {}
local timers = {}

local fakeComputer = {
    uptime = function() return now end
}

local fakeEvent = {}
function fakeEvent.listen(name, callback)
    listeners[#listeners + 1] = { name = name, callback = callback }
    return #listeners
end
function fakeEvent.ignore(name, callback)
    for index, listener in ipairs(listeners) do
        if listener.name == name and listener.callback == callback then
            table.remove(listeners, index)
            return true
        end
    end
    return false
end
function fakeEvent.timer(delay, callback)
    timers[#timers + 1] = { at = now + delay, callback = callback }
    return #timers
end
function fakeEvent.pull(timeout)
    local deadline = now + (timeout or math.huge)
    if #queued > 0 then
        local signal = table.remove(queued, 1)
        local copy = { table.unpack(listeners) }
        for _, listener in ipairs(copy) do
            if listener.name == signal[1] then listener.callback(table.unpack(signal)) end
        end
        return table.unpack(signal)
    end

    local selected
    for index, timer in ipairs(timers) do
        if timer.at <= deadline and (not selected or timer.at < timers[selected].at) then selected = index end
    end
    if selected then
        local timer = table.remove(timers, selected)
        now = timer.at
        timer.callback()
        return
    end

    now = deadline
end

package.loaded.computer = fakeComputer
package.loaded.event = fakeEvent

local discovery = assert(loadfile(mount .. "/repo/service-discovery/lib/meatball/discovery.lua"))()
local open = false
local opens = 0
local closes = 0
local sent = {}
local modem = { address = "client-card" }

function modem.isOpen(port)
    assert(port == discovery.PORT)
    return open
end
function modem.open(port)
    assert(port == discovery.PORT)
    open = true
    opens = opens + 1
    return true
end
function modem.close(port)
    assert(port == discovery.PORT)
    open = false
    closes = closes + 1
    return true
end
function modem.send(...)
    local packet = table.pack(...)
    assert(packet.n - 2 <= 8, "offer exceeded OpenComputers' eight-part payload limit")
    sent[#sent + 1] = packet
    return true
end
function modem.broadcast(port, protocol, kind, requestId, serviceType, apiVersion)
    assert(port == discovery.PORT and protocol == discovery.PROTOCOL and kind == "discover")
    local function offer(address, instanceId, displayName, metadata, receivedRequestId)
        queued[#queued + 1] = table.pack("modem_message", modem.address, address, port, 1, protocol, "offer",
            receivedRequestId or requestId, serviceType, instanceId, apiVersion, 48723,
            serialization.serialize({ displayName = displayName, metadata = metadata or {} }))
    end

    offer("relay-b", "reactor-south", "South Reactor", { zone = "south" })
    offer("relay-a", "reactor-north", "North Reactor", { zone = "north" })
    offer("relay-a", "reactor-north", "North Reactor", { zone = "north" })
    offer("relay-c", "reactor-north", "North Reactor Clone", {})
    offer("wrong-request", "ignored", "Ignored", {}, "another-request")
    queued[#queued + 1] = table.pack("modem_message", modem.address, "malformed", port, 1, protocol, "offer",
        requestId, serviceType, "bad", apiVersion, 48723, "Bad", "not serialized data")
    return true
end

local services, findError = discovery.find(modem, {
    serviceType = "meatballcraft.nc.reactor",
    apiVersion = 1,
    timeout = 1
})
assert(services, findError)
assert(#services == 3, "discovery did not deduplicate and validate offers")
assert(services[1].displayName == "North Reactor", "services were not sorted by display name")
assert(services[1].address == "relay-a" and services[1].metadata.zone == "north", "offer fields were lost")
assert(services[1].conflict and services[2].conflict, "duplicate instance IDs were not marked as conflicts")
assert(not services[3].conflict, "unique service was marked as a conflict")
assert(not open and opens == 1 and closes == 1, "find did not release its discovery port")

sent = {}
local first, firstError = discovery.advertise(modem, {
    serviceType = "meatballcraft.nc.reactor",
    instanceId = "reactor-north",
    displayName = "North Reactor",
    apiVersion = 1,
    servicePort = 48723,
    metadata = { zone = "north" },
    responseJitter = 0
})
assert(first, firstError)
local second, secondError = discovery.advertise(modem, {
    serviceType = "meatballcraft.nc.reactor",
    instanceId = "reactor-south",
    displayName = "South Reactor",
    apiVersion = 1,
    servicePort = 48723,
    responseJitter = 0
})
assert(second, secondError)
assert(open and opens == 2, "advertisements did not share the open discovery port")

queued[#queued + 1] = table.pack("modem_message", modem.address, "seeking-client", discovery.PORT, 1,
    discovery.PROTOCOL, "discover", "probe-1", "meatballcraft.nc.reactor", 1)
fakeEvent.pull(0)
assert(#sent == 2, "each matching advertisement did not answer the probe")
for _, packet in ipairs(sent) do
    assert(packet[1] == "seeking-client", "offer was not unicast to the probe sender")
    assert(packet[2] == discovery.PORT and packet[3] == discovery.PROTOCOL and packet[4] == "offer",
        "offer used the wrong endpoint or message kind")
    assert(packet[5] == "probe-1", "offer did not preserve the request ID")
end

assert(first.close(), "first advertisement did not close")
assert(open, "closing one advertisement closed a shared discovery port")
assert(second.close(), "second advertisement did not close")
assert(not open and closes == 2, "final advertisement did not release the discovery port")
assert(not second.close(), "advertisement close was not idempotent")

local invalid, invalidError = discovery.advertise(modem, {
    serviceType = "meatballcraft.nc.reactor",
    instanceId = "",
    displayName = "Invalid",
    apiVersion = 1,
    servicePort = 48723
})
assert(not invalid and invalidError:find("instanceId", 1, true), "invalid identity was accepted")

print("service discovery test complete")
