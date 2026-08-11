local component = require("component")
local event = require("event")
local serialization = require("serialization")
local keyboard = require("keyboard")
local term = require("term")

local PROTOCOL = "nc-monitor-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2

local tunnel = component.tunnel
local gpu = component.gpu

if not tunnel then error("No tunnel component found") end
if not gpu then error("No GPU found") end

local TEXT = 0xFFFFFF
local MUTED = 0xAAAAAA
local HEADER = 0x55FFFF
local GOOD = 0x55FF55
local WARN = 0xFFFF55
local BAD = 0xFF5555
local BG = 0x000000

gpu.setBackground(BG)
gpu.setForeground(TEXT)

local function request(requestType)
    tunnel.send(PROTOCOL, requestType)

    while true do
        local _, _, _, _, _, protocol, messageType, encoded = event.pull(TIMEOUT, "modem_message")
        if not protocol then return nil, "Request timed out" end

        if protocol == PROTOCOL and messageType == "response" then
            local ok, response = pcall(serialization.unserialize, encoded)
            if not ok then return nil, "Failed to decode response" end
            return response
        end
    end
end

local function n(value, decimals)
    if value == nil then return "-" end
    if type(value) ~= "number" then return tostring(value) end
    if value == math.floor(value) then return tostring(value) end
    return string.format("%." .. tostring(decimals or 2) .. "f", value)
end

local function newLines() return {} end
local function add(lines, text, color) table.insert(lines, { text = tostring(text or ""), color = color or TEXT }) end
local function blank(lines) add(lines, "") end
local function header(lines, text) add(lines, text, HEADER) end

local function viewer(lines)
    local width, height = gpu.getResolution()
    local pageHeight = height - 1
    local offset = 1

    local function maxOffset() return math.max(1, #lines - pageHeight + 1) end
    local function clamp() offset = math.max(1, math.min(offset, maxOffset())) end

    local function render()
        gpu.setBackground(BG)
        gpu.fill(1, 1, width, height, " ")

        for row = 1, pageHeight do
            local line = lines[offset + row - 1]
            if line then
                gpu.setForeground(line.color)
                gpu.set(1, row, line.text:sub(1, width))
            end
        end

        gpu.setForeground(MUTED)
        local footer = string.format(
            "Up/Down PgUp/PgDn Home/End q=back [%d-%d/%d]",
            offset,
            math.min(offset + pageHeight - 1, #lines),
            #lines
        )
        gpu.set(1, height, footer:sub(1, width))
    end

    render()

    while true do
        local e = table.pack(event.pull())

        if e[1] == "key_down" then
            local char = e[3]
            local code = e[4]

            if char == string.byte("q") or char == string.byte("Q") then
                break
            elseif code == keyboard.keys.up then
                offset = offset - 1
            elseif code == keyboard.keys.down then
                offset = offset + 1
            elseif code == keyboard.keys.pageUp then
                offset = offset - pageHeight
            elseif code == keyboard.keys.pageDown then
                offset = offset + pageHeight
            elseif code == keyboard.keys.home then
                offset = 1
            elseif code == keyboard.keys["end"] then
                offset = maxOffset()
            end

            clamp()
            render()
        elseif e[1] == "scroll" then
            if e[5] > 0 then offset = offset - 3 else offset = offset + 3 end
            clamp()
            render()
        end
    end

    term.clear()
end

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
    if r and r.level ~= nil then add(lines, "Chunk radiation: " .. n(r.level)) else add(lines,
            "Chunk radiation unavailable", WARN) end
    if r and r.error then add(lines, tostring(r.error), BAD) end
    return lines
end

local function drawAt(x, y, text, color)
    local width, height = gpu.getResolution()
    if y < 1 or y > height or x > width then return end
    gpu.setForeground(color or TEXT)
    gpu.set(x, y, tostring(text):sub(1, width - x + 1))
end

local function drawDashboard(response, err)
    local width, height = gpu.getResolution()
    gpu.setBackground(BG)
    gpu.fill(1, 1, width, height, " ")

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
    drawAt(1, 11, "Radiation: " .. n(radiation and radiation.level))

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
    local response = nil
    local lastError = nil
    local refresh = true

    while true do
        if refresh then
            local newResponse, err = request("getAll")
            if newResponse and newResponse.ok then
                response = newResponse; lastError = nil
            else
                lastError = err or (newResponse and newResponse.error) or "Unknown error"
            end
            drawDashboard(response, lastError)
            refresh = false
        end

        local e = table.pack(event.pull(REFRESH_INTERVAL, "key_down"))
        if not e[1] then
            refresh = true
        else
            local char = e[3]
            if char == string.byte("q") or char == string.byte("Q") then
                term.clear(); return
            elseif char == string.byte("r") or char == string.byte("R") then
                refresh = true
            end
        end
    end
end

local function showResponse(requestType, builder, field)
    local response, err = request(requestType)
    if not response then
        print("ERROR: " .. tostring(err)); os.sleep(1); return
    end
    if not response.ok then
        print("Server error: " .. tostring(response.error)); os.sleep(1); return
    end
    viewer(builder(response[field]))
end

while true do
    term.clear()
    gpu.setForeground(HEADER)
    print("NC Reactor Monitor")
    gpu.setForeground(MUTED)
    print("==================")
    gpu.setForeground(TEXT)
    print("1. Reactor summary")
    print("2. Vessel stats")
    print("3. Radiation")
    print("4. Live dashboard")
    print("q. Quit")
    print()
    io.write("> ")

    local choice = io.read()
    if choice == "1" then
        showResponse("getReactor", buildReactorSummary, "reactor")
    elseif choice == "2" then
        showResponse("getVessels", buildVessels, "vessels")
    elseif choice == "3" then
        showResponse("getRadiation", buildRadiation, "radiation")
    elseif choice == "4" then
        dashboard()
    elseif choice == "q" or choice == "quit" or choice == "exit" then
        term.clear(); break
    end
end
