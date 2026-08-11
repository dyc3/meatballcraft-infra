local component = require("component")
local rpc = require("nuclearcraft.rpc")
local uiModule = require("nuclearcraft.ui")

local PROTOCOL = "nc-monitor-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2

local tunnel = component.tunnel
local gpu = component.gpu

if not tunnel then error("No tunnel component found") end
if not gpu then error("No GPU found") end

local endpoint = rpc.tunnel(tunnel, PROTOCOL, TIMEOUT)
local request = endpoint.request
local ui = uiModule.new(gpu)

local TEXT = uiModule.TEXT
local MUTED = uiModule.MUTED
local HEADER = uiModule.HEADER
local GOOD = uiModule.GOOD
local WARN = uiModule.WARN
local BAD = uiModule.BAD

local n = uiModule.number
local function formatRadiation(value) return uiModule.metric(value, "Rads/t") end
local newLines = ui.newLines
local add = ui.add
local blank = ui.blank
local header = ui.header

local function buildReactorSummary(r)
    local lines = newLines()
    header(lines, "SALT FISSION REACTOR")
    add(lines, "--------------------------------", MUTED)

    add(lines, "Reactor: " .. (r.reactorOn and "ONLINE" or "OFFLINE"), r.reactorOn and GOOD or WARN)
    add(lines, "Structure: " .. (r.complete and "COMPLETE" or "INVALID"), r.complete and GOOD or BAD)

    if r.size then
        add(lines, "Size: " .. n(r.size.x) .. " x " .. n(r.size.y) .. " x " .. n(r.size.z))
    end

    if r.heat then
        blank(lines)
        header(lines, "HEAT")
        local color = TEXT
        if type(r.heat.percent) == "number" then
            if r.heat.percent >= 90 then color = BAD elseif r.heat.percent >= 70 then color = WARN else color = GOOD end
        end
        add(lines,
            "Stored: " ..
            n(r.heat.stored) ..
            " / " .. n(r.heat.capacity) .. (r.heat.percent and string.format(" (%.1f%%)", r.heat.percent) or ""), color)
        add(lines, "Heating: raw " .. n(r.heat.rawHeatingRate) .. " | net " .. n(r.heat.netHeatingRate))
        add(lines,
            "Cooling: " ..
            n(r.heat.coolingRate) .. " | eff " .. n(r.heat.coolingEfficiency) .. " | heat x" .. n(r.heat.multiplier))
    end

    blank(lines)
    header(lines, "EFFICIENCY")
    add(lines, "Raw: " .. n(r.efficiency and r.efficiency.raw))

    if r.counts then
        blank(lines)
        header(lines, "COMPONENTS")
        add(lines,
            "Vessels " ..
            n(r.counts.vessels) .. " | Heaters " .. n(r.counts.heaters) .. " | Moderators " .. n(r.counts.moderators))
    end

    return lines
end

local function buildVessels(vessels)
    local lines = newLines()
    header(lines, "FUEL VESSELS")
    add(lines, "--------------------------------", MUTED)

    if type(vessels) ~= "table" or #vessels == 0 then
        add(lines, "No vessel data.", MUTED)
        return lines
    end

    for i, v in ipairs(vessels) do
        blank(lines)
        local state = v.processing and "RUNNING" or "IDLE"
        local p = v.position or {}
        add(lines,
            string.format("[%d] %s @ %s,%s,%s", i, state, tostring(p.x or "?"), tostring(p.y or "?"),
                tostring(p.z or "?")), v.processing and GOOD or MUTED)

        local parts = {}
        if v.process and v.process.progressPercent ~= nil then table.insert(parts,
                string.format("Progress %.1f%%", v.process.progressPercent)) end
        if v.efficiency ~= nil then table.insert(parts, "Eff " .. n(v.efficiency)) end
        if v.heatMultiplier ~= nil then table.insert(parts, "Heat x" .. n(v.heatMultiplier)) end
        if #parts > 0 then add(lines, " " .. table.concat(parts, " | ")) end
        if v.heat ~= nil then add(lines, " Process heat: " .. n(v.heat)) end
        if v.process and v.process.currentTime ~= nil and v.process.totalTime ~= nil then
            add(lines, " Time: " .. n(v.process.currentTime) .. " / " .. n(v.process.totalTime), MUTED)
        end
    end

    return lines
end

local function buildRadiation(r)
    local lines = newLines()
    header(lines, "RADIATION")
    add(lines, "--------------------------------", MUTED)
    if r and r.level ~= nil then add(lines, "Chunk radiation: " .. formatRadiation(r.level)) else add(lines,
            "Chunk radiation unavailable", WARN) end
    if r and r.error then add(lines, tostring(r.error), BAD) end
    return lines
end

local drawAt = ui.draw

local function drawDashboard(response, err)
    local width, height = ui.clear()

    drawAt(1, 1, "NC REACTOR DASHBOARD", HEADER)
    if err then
        drawAt(math.max(1, width - #tostring(err) - 6), 1, "ERROR " .. tostring(err), BAD)
    else
        drawAt(math.max(1, width - 8), 1, "CONNECTED", GOOD)
    end

    if not response or not response.reactor then
        drawAt(1, 3, "Waiting for reactor data...", WARN)
        return
    end

    local r = response.reactor
    local radiation = response.radiation

    drawAt(1, 3, "Reactor: " .. (r.reactorOn and "ONLINE" or "OFFLINE"), r.reactorOn and GOOD or WARN)
    drawAt(22, 3, "Structure: " .. (r.complete and "COMPLETE" or "INVALID"), r.complete and GOOD or BAD)
    if r.size then drawAt(45, 3, "Size " .. n(r.size.x) .. "x" .. n(r.size.y) .. "x" .. n(r.size.z), MUTED) end

    if r.heat then
        drawAt(1, 5, "HEAT", HEADER)
        local color = TEXT
        if type(r.heat.percent) == "number" then
            if r.heat.percent >= 90 then color = BAD elseif r.heat.percent >= 70 then color = WARN else color = GOOD end
        end
        drawAt(1, 6,
            "Stored: " ..
            n(r.heat.stored) ..
            " / " .. n(r.heat.capacity) .. (r.heat.percent and string.format(" (%.1f%%)", r.heat.percent) or ""), color)
        drawAt(1, 7,
            "Heating raw " ..
            n(r.heat.rawHeatingRate) .. " | net " .. n(r.heat.netHeatingRate) .. " | cooling " .. n(r.heat.coolingRate))
    end

    drawAt(1, 9, "REACTOR", HEADER)
    drawAt(1, 10, "Efficiency: " .. n(r.efficiency and r.efficiency.raw))
    if r.counts then drawAt(22, 10,
            "Vessels " ..
            n(r.counts.vessels) .. " | Heaters " .. n(r.counts.heaters) .. " | Mods " .. n(r.counts.moderators)) end
    drawAt(1, 11, "Radiation: " .. formatRadiation(radiation and radiation.level))

    local y = 13
    drawAt(1, y, "VESSELS", HEADER)
    y = y + 1
    drawAt(1, y, "#  POS          STATE  PROG   HEAT    EFF     MULT", MUTED)
    y = y + 1

    for i, v in ipairs(r.vessels or {}) do
        if y >= height then break end
        local p = v.position or {}
        local proc = v.process or {}
        local row = string.format(
            "%-2d %-12s %-5s %-6s %-7s %-7s x%s",
            i,
            string.format("%s,%s,%s", tostring(p.x or "?"), tostring(p.y or "?"), tostring(p.z or "?")),
            v.processing and "RUN" or "IDLE",
            proc.progressPercent ~= nil and string.format("%.0f%%", proc.progressPercent) or "-",
            n(v.heat),
            n(v.efficiency),
            n(v.heatMultiplier)
        )
        drawAt(1, y, row, v.processing and GOOD or MUTED)
        y = y + 1
    end

    drawAt(1, height, "Refresh " .. REFRESH_INTERVAL .. "s   q=back   r=refresh", MUTED)
end

local function dashboard()
    ui.runDashboard(REFRESH_INTERVAL, function() return request("getAll") end, drawDashboard)
end

local function showResponse(requestType, builder, field)
    ui.showResponse(request, requestType, builder, field)
end

ui.runMenu("NC Reactor Monitor", {
    { key = "1", label = "Reactor summary", action = function()
        showResponse("getReactor", buildReactorSummary, "reactor")
    end },
    { key = "2", label = "Vessel stats", action = function()
        showResponse("getVessels", buildVessels, "vessels")
    end },
    { key = "3", label = "Radiation", action = function()
        showResponse("getRadiation", buildRadiation, "radiation")
    end },
    { key = "4", label = "Live dashboard", action = dashboard }
})
