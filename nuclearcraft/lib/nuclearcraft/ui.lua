local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local ui = {
    BG = 0x000000,
    TEXT = 0xFFFFFF,
    MUTED = 0xAAAAAA,
    HEADER = 0x55FFFF,
    GOOD = 0x55FF55,
    WARN = 0xFFFF55,
    ORANGE = 0xFFAA00,
    INFO = 0x55AAFF,
    BAD = 0xFF5555
}

local METRIC_PREFIXES = {
    { factor = 1e15, prefix = "P" },
    { factor = 1e12, prefix = "T" },
    { factor = 1e9, prefix = "G" },
    { factor = 1e6, prefix = "M" },
    { factor = 1e3, prefix = "k" },
    { factor = 1, prefix = "" },
    { factor = 1e-3, prefix = "m" },
    { factor = 1e-6, prefix = "u" },
    { factor = 1e-9, prefix = "n" },
    { factor = 1e-12, prefix = "p" },
    { factor = 1e-15, prefix = "f" }
}

function ui.number(value, decimals)
    if value == nil then return "-" end
    if type(value) ~= "number" then return tostring(value) end
    if value == math.floor(value) then return tostring(value) end
    return string.format("%." .. tostring(decimals or 2) .. "f", value)
end

function ui.percentage(value)
    if type(value) ~= "number" then return "-" end
    return string.format("%.1f%%", value)
end

function ui.position(position)
    if not position then return "?,?,?" end
    return string.format("%s,%s,%s", tostring(position.x or "?"), tostring(position.y or "?"),
        tostring(position.z or "?"))
end

function ui.metric(value, unit)
    if value == nil then return "-" end
    if type(value) ~= "number" then return tostring(value) end
    if value == 0 then return "0 " .. unit end

    local absolute = math.abs(value)
    local selected = METRIC_PREFIXES[#METRIC_PREFIXES]
    for _, prefix in ipairs(METRIC_PREFIXES) do
        if absolute >= prefix.factor then
            selected = prefix
            break
        end
    end

    local scaled = value / selected.factor
    local decimals = 2
    if math.abs(scaled) >= 100 then
        decimals = 0
    elseif math.abs(scaled) >= 10 then
        decimals = 1
    end

    return string.format("%." .. decimals .. "f %s%s", scaled, selected.prefix, unit)
end

function ui.new(gpu)
    gpu.setBackground(ui.BG)
    gpu.setForeground(ui.TEXT)

    local screen = {}

    function screen.newLines()
        return {}
    end

    function screen.add(lines, text, color)
        table.insert(lines, { text = tostring(text or ""), color = color or ui.TEXT })
    end

    function screen.blank(lines)
        screen.add(lines, "")
    end

    function screen.header(lines, text)
        screen.add(lines, text, ui.HEADER)
    end

    function screen.view(lines)
        local width, height = gpu.getResolution()
        local pageHeight = height - 1
        local offset = 1

        local function maxOffset()
            return math.max(1, #lines - pageHeight + 1)
        end

        local function clamp()
            offset = math.max(1, math.min(offset, maxOffset()))
        end

        local function render()
            gpu.setBackground(ui.BG)
            gpu.fill(1, 1, width, height, " ")

            for row = 1, pageHeight do
                local line = lines[offset + row - 1]
                if line then
                    gpu.setForeground(line.color)
                    gpu.set(1, row, line.text:sub(1, width))
                end
            end

            gpu.setForeground(ui.MUTED)
            local footer = string.format("Up/Down PgUp/PgDn Home/End q=back [%d-%d/%d]", offset,
                math.min(offset + pageHeight - 1, #lines), #lines)
            gpu.set(1, height, footer:sub(1, width))
        end

        render()

        while true do
            local pulled = table.pack(event.pull())
            if pulled[1] == "key_down" then
                local char = pulled[3]
                local code = pulled[4]
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
            elseif pulled[1] == "scroll" then
                if pulled[5] > 0 then offset = offset - 3 else offset = offset + 3 end
                clamp()
                render()
            end
        end

        term.clear()
    end

    function screen.draw(x, y, text, color)
        local width, height = gpu.getResolution()
        if y < 1 or y > height or x > width then return end
        gpu.setForeground(color or ui.TEXT)
        gpu.set(x, y, tostring(text):sub(1, width - x + 1))
    end

    function screen.clear()
        local width, height = gpu.getResolution()
        gpu.setBackground(ui.BG)
        gpu.fill(1, 1, width, height, " ")
        return width, height
    end

    function screen.showResponse(request, requestType, builder, field)
        print("Sending request '" .. tostring(requestType) .. "'; waiting for response...")
        local response, err = request(requestType)
        if not response then
            print("REQUEST FAILED: " .. tostring(err))
            os.sleep(1)
            return
        end
        if type(response.ok) ~= "boolean" then
            print("INVALID RESPONSE: missing boolean 'ok' field")
            os.sleep(1)
            return
        end
        if not response.ok then
            print("Server error: " .. tostring(response.error))
            os.sleep(1)
            return
        end
        if field and type(response[field]) ~= "table" then
            print("INVALID RESPONSE: missing or invalid '" .. tostring(field) .. "' data")
            os.sleep(1)
            return
        end
        screen.view(builder(response[field]))
    end

    function screen.runDashboard(refreshInterval, load, render, expectedField)
        local response = nil
        local lastError = nil
        local refresh = true

        while true do
            if refresh then
                render(response, nil, "requesting")
                local newResponse, err = load()
                if newResponse and type(newResponse.ok) ~= "boolean" then
                    lastError = "Response received, but it is missing the boolean 'ok' field"
                elseif newResponse and newResponse.ok and expectedField and type(newResponse[expectedField]) ~= "table" then
                    lastError = "Response received, but '" .. expectedField .. "' data is missing or invalid"
                elseif newResponse and newResponse.ok then
                    response = newResponse
                    lastError = nil
                else
                    lastError = err or (newResponse and newResponse.error) or "Unknown error"
                end
                render(response, lastError)
                refresh = false
            end

            local pulled = table.pack(event.pull(refreshInterval, "key_down"))
            if not pulled[1] then
                refresh = true
            else
                local char = pulled[3]
                if char == string.byte("q") or char == string.byte("Q") then
                    term.clear()
                    return
                elseif char == string.byte("r") or char == string.byte("R") then
                    refresh = true
                end
            end
        end
    end

    function screen.runMenu(title, entries)
        while true do
            term.clear()
            gpu.setForeground(ui.HEADER)
            print(title)
            gpu.setForeground(ui.MUTED)
            print(string.rep("=", #title))
            gpu.setForeground(ui.TEXT)
            for _, entry in ipairs(entries) do
                print(entry.key .. ". " .. entry.label)
            end
            print("q. Quit")
            print()
            io.write("> ")

            local choice = io.read()
            if choice == "q" or choice == "quit" or choice == "exit" then
                term.clear()
                return
            end

            for _, entry in ipairs(entries) do
                if choice == entry.key then
                    entry.action()
                    break
                end
            end
        end
    end

    return screen
end

return ui
