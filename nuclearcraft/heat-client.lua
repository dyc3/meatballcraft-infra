local component = require("component")
local event = require("event")
local serialization = require("serialization")
local keyboard = require("keyboard")
local term = require("term")

local PORT = 48722
local PROTOCOL = "nc-heat-exchanger-v1"
local TIMEOUT = 5
local REFRESH_INTERVAL = 2

if not component.isAvailable("modem") then error("No Network Card found (missing 'modem' component)") end
if not component.isAvailable("gpu") then error("No GPU found") end

local modem = component.modem
local gpu = component.gpu
modem.open(PORT)

local BG = 0x000000
local TEXT = 0xFFFFFF
local MUTED = 0xAAAAAA
local HEADER = 0x55FFFF
local GOOD = 0x55FF55
local WARN = 0xFFFF55
local BAD = 0xFF5555

gpu.setBackground(BG)
gpu.setForeground(TEXT)

local function request(requestType)
    modem.broadcast(PORT, PROTOCOL, requestType)

    while true do
        local _, _, remoteAddress, port, _, protocol, messageType, encoded = event.pull(TIMEOUT, "modem_message")
        if not remoteAddress then return nil, "Request timed out" end

        if port == PORT and protocol == PROTOCOL and messageType == "response" then
            local ok, response = pcall(serialization.unserialize, encoded)
            if not ok then return nil, "Invalid response" end
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

local function pct(value)
    if type(value) ~= "number" then return "-" end
    return string.format("%.1f%%", value)
end

local function pos(p)
    if not p then return "?,?,?" end
    return string.format("%s,%s,%s", tostring(p.x or "?"), tostring(p.y or "?"), tostring(p.z or "?"))
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
        local footer = string.format("Up/Down PgUp/PgDn Home/End q=back [%d-%d/%d]", offset,
            math.min(offset + pageHeight - 1, #lines), #lines)
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
            clamp(); render()
        elseif e[1] == "scroll" then
            if e[5] > 0 then offset = offset - 3 else offset = offset + 3 end
            clamp(); render()
        end
    end

    term.clear()
end

local function buildSummary(e)
    local lines = newLines()
    header(lines, "HEAT EXCHANGER")
    add(lines, "--------------------------------", MUTED)
    add(lines, "State: " .. (e.active and "ONLINE" or "OFFLINE"), e.active and GOOD or WARN)
    add(lines, "Structure: " .. (e.complete and "COMPLETE" or "INVALID"), e.complete and GOOD or BAD)
    if e.size then add(lines, "Size: " .. n(e.size.x) .. " x " .. n(e.size.y) .. " x " .. n(e.size.z)) end
    blank(lines)
    add(lines, "Mean efficiency: " .. n(e.efficiency))
    if e.fractionActive ~= nil then add(lines, "Tubes active: " .. pct(e.fractionActive * 100)) end
    if e.counts then
        add(lines, "Exchanger tubes: " .. n(e.counts.exchanger))
        add(lines, "Condensation tubes: " .. n(e.counts.condensation))
    end
    return lines
end

local function buildExchangerTubes(tubes)
    local lines = newLines()
    header(lines, "EXCHANGER TUBES")
    add(lines, "--------------------------------", MUTED)

    for i, t in ipairs(tubes or {}) do
        blank(lines)
        add(lines, string.format("[%d] %s @ %s", i, t.processing and "RUNNING" or "IDLE", pos(t.position)),
            t.processing and GOOD or MUTED)
        add(lines,
            string.format(" Conductivity %s | Speed x%s | %s", n(t.conductivity),
                n(t.process and t.process.speedMultiplier), tostring(t.flowDirection or "?")))
        if t.process then add(lines,
                " Progress " .. pct(t.process.progressPercent) .. " | " .. n(t.process.processTime) .. " ticks/op") end
        if t.temperature then
            local change = t.temperature.change
            local sign = type(change) == "number" and change > 0 and "+" or ""
            add(lines,
                " Temp " ..
                n(t.temperature.input) .. " K -> " .. n(t.temperature.output) .. " K (" .. sign .. n(change) .. " K)")
        end
    end

    if #(tubes or {}) == 0 then add(lines, "No exchanger tubes.") end
    return lines
end

local function buildCondensationTubes(tubes)
    local lines = newLines()
    header(lines, "CONDENSATION TUBES")
    add(lines, "--------------------------------", MUTED)

    for i, t in ipairs(tubes or {}) do
        blank(lines)
        add(lines, string.format("[%d] %s @ %s", i, t.processing and "RUNNING" or "IDLE", pos(t.position)),
            t.processing and GOOD or MUTED)
        add(lines, " Conductivity " .. n(t.conductivity) .. " | Speed x" .. n(t.process and t.process.speedMultiplier))
        if t.process then add(lines,
                " Progress " .. pct(t.process.progressPercent) .. " | " .. n(t.process.processTime) .. " ticks/op") end
        add(lines, " Condensing temp: " .. n(t.condensingTemperature) .. " K")
        local a = t.adjacentTemperatures
        if a then
            add(lines, " Adj D/U: " .. n(a.down) .. " / " .. n(a.up) .. " K")
            add(lines, " Adj N/S: " .. n(a.north) .. " / " .. n(a.south) .. " K")
            add(lines, " Adj W/E: " .. n(a.west) .. " / " .. n(a.east) .. " K")
        end
    end

    if #(tubes or {}) == 0 then add(lines, "No condensation tubes.") end
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

    drawAt(1, 1, "HEAT EXCHANGER DASHBOARD", HEADER)
    if err then
        local text = "ERROR " .. tostring(err)
        drawAt(math.max(1, width - #text + 1), 1, text, BAD)
    else
        drawAt(math.max(1, width - 8), 1, "CONNECTED", GOOD)
    end

    if not response or not response.exchanger then
        drawAt(1, 3, "Waiting for data...", WARN)
        return
    end

    local e = response.exchanger
    drawAt(1, 3, "State: " .. (e.active and "ONLINE" or "OFFLINE"), e.active and GOOD or WARN)
    drawAt(22, 3, "Complete: " .. tostring(e.complete), e.complete and GOOD or BAD)
    if e.size then drawAt(45, 3, "Size " .. n(e.size.x) .. "x" .. n(e.size.y) .. "x" .. n(e.size.z), MUTED) end
    drawAt(1, 5, "Efficiency: " .. n(e.efficiency))
    drawAt(25, 5, "Active tubes: " .. pct((e.fractionActive or 0) * 100))
    if e.counts then drawAt(1, 6,
            "Exchanger tubes: " .. n(e.counts.exchanger) .. "   Condensers: " .. n(e.counts.condensation)) end

    local y = 8
    drawAt(1, y, "EXCHANGER TUBES", HEADER)
    y = y + 1
    drawAt(1, y, "#  POS          STATE  PROG   TICKS   SPEED    TEMP", MUTED)
    y = y + 1

    for i, t in ipairs(e.exchangerTubes or {}) do
        if y >= height - 3 then break end
        local p = t.process or {}
        local temp = t.temperature or {}
        local row = string.format("%-2d %-12s %-5s %-6s %-7s x%-7s %s>%s", i, pos(t.position),
            t.processing and "RUN" or "IDLE", pct(p.progressPercent), n(p.processTime, 1), n(p.speedMultiplier, 1),
            n(temp.input), n(temp.output))
        drawAt(1, y, row, t.processing and GOOD or MUTED)
        y = y + 1
    end

    if y < height - 2 then
        y = y + 1
        drawAt(1, y, "CONDENSATION TUBES", HEADER)
        y = y + 1
        drawAt(1, y, "#  POS          STATE  PROG   TICKS   SPEED    COND TEMP", MUTED)
        y = y + 1

        for i, t in ipairs(e.condensationTubes or {}) do
            if y >= height then break end
            local p = t.process or {}
            local row = string.format("%-2d %-12s %-5s %-6s %-7s x%-7s %s K", i, pos(t.position),
                t.processing and "RUN" or "IDLE", pct(p.progressPercent), n(p.processTime, 1), n(p.speedMultiplier, 1),
                n(t.condensingTemperature))
            drawAt(1, y, row, t.processing and GOOD or MUTED)
            y = y + 1
        end
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

while true do
    term.clear()
    gpu.setForeground(HEADER)
    print("NC Heat Exchanger")
    gpu.setForeground(MUTED)
    print("=================")
    gpu.setForeground(TEXT)
    print("1. Summary")
    print("2. Exchanger tubes")
    print("3. Condensation tubes")
    print("4. Live dashboard")
    print("q. Quit")
    print()
    io.write("> ")

    local choice = io.read()

    if choice == "1" then
        local response, err = request("getSummary")
        if response and response.ok then viewer(buildSummary(response.exchanger)) else
            print("ERROR: " .. tostring(err or (response and response.error))); os.sleep(1)
        end
    elseif choice == "2" then
        local response, err = request("getExchangerTubes")
        if response and response.ok then viewer(buildExchangerTubes(response.tubes)) else
            print("ERROR: " .. tostring(err or (response and response.error))); os.sleep(1)
        end
    elseif choice == "3" then
        local response, err = request("getCondensationTubes")
        if response and response.ok then viewer(buildCondensationTubes(response.tubes)) else
            print("ERROR: " .. tostring(err or (response and response.error))); os.sleep(1)
        end
    elseif choice == "4" then
        dashboard()
    elseif choice == "q" or choice == "quit" or choice == "exit" then
        term.clear()
        break
    end
end
