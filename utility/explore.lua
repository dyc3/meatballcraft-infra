local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local gpu = component.gpu

----------------------------------------------------------------------
-- Utility
----------------------------------------------------------------------

local function clear()
  term.clear()
  term.setCursor(1, 1)
end

local function crop(text, width)
  text = tostring(text)

  if #text > width then
    return text:sub(1, math.max(1, width - 3)) .. "..."
  end

  return text
end

----------------------------------------------------------------------
-- Generic scrollable selector
----------------------------------------------------------------------

local function selectList(title, items, renderItem)
  local selected = 1
  local top = 1

  while true do
    local width, height = gpu.getResolution()

    -- title + blank + footer
    local contentTop = 3
    local contentHeight = height - 3

    if #items == 0 then
      selected = 0
      top = 1
    else
      if selected < 1 then
        selected = 1
      elseif selected > #items then
        selected = #items
      end

      if selected < top then
        top = selected
      elseif selected >= top + contentHeight then
        top = selected - contentHeight + 1
      end

      local maxTop = math.max(1, #items - contentHeight + 1)

      if top > maxTop then
        top = maxTop
      end
    end

    clear()

    gpu.set(1, 1, crop(title, width))

    if #items == 0 then
      gpu.set(1, 3, "<no items>")
    else
      for row = 0, contentHeight - 1 do
        local index = top + row

        if index > #items then
          break
        end

        local prefix

        if index == selected then
          prefix = "> "
        else
          prefix = "  "
        end

        local text = prefix .. renderItem(items[index], index)

        gpu.set(
          1,
          contentTop + row,
          crop(text, width)
        )
      end
    end

    local footer

    if #items > 0 then
      footer = string.format(
        "%d/%d  Up/Down PgUp/PgDn Enter=open q=back",
        selected,
        #items
      )
    else
      footer = "q/backspace = back"
    end

    gpu.set(1, height, crop(footer, width))

    local _, _, char, code = event.pull("key_down")

    if code == keyboard.keys.up and #items > 0 then
      selected = selected - 1

      if selected < 1 then
        selected = 1
      end

    elseif code == keyboard.keys.down and #items > 0 then
      selected = selected + 1

      if selected > #items then
        selected = #items
      end

    elseif code == keyboard.keys.pageUp and #items > 0 then
      selected = selected - contentHeight

      if selected < 1 then
        selected = 1
      end

    elseif code == keyboard.keys.pageDown and #items > 0 then
      selected = selected + contentHeight

      if selected > #items then
        selected = #items
      end

    elseif code == keyboard.keys.home and #items > 0 then
      selected = 1

    elseif code == keyboard.keys["end"] and #items > 0 then
      selected = #items

    elseif code == keyboard.keys.enter and #items > 0 then
      return selected

    elseif code == keyboard.keys.back then
      return nil

    elseif char == string.byte("q") or
           char == string.byte("Q") then
      return nil
    end
  end
end

----------------------------------------------------------------------
-- Scrollable text viewer
----------------------------------------------------------------------

local function pager(lines, title)
  local top = 1

  while true do
    local width, height = gpu.getResolution()
    local contentTop = 3
    local contentHeight = height - 3

    local maxTop = math.max(
      1,
      #lines - contentHeight + 1
    )

    if top < 1 then
      top = 1
    elseif top > maxTop then
      top = maxTop
    end

    clear()

    gpu.set(1, 1, crop(title or "Output", width))

    for row = 0, contentHeight - 1 do
      local index = top + row

      if index > #lines then
        break
      end

      gpu.set(
        1,
        contentTop + row,
        crop(lines[index], width)
      )
    end

    local lastVisible = math.min(
      #lines,
      top + contentHeight - 1
    )

    local footer = string.format(
      "%d-%d/%d  Up/Down PgUp/PgDn Home/End q=back",
      top,
      lastVisible,
      #lines
    )

    gpu.set(1, height, crop(footer, width))

    local _, _, char, code = event.pull("key_down")

    if code == keyboard.keys.up then
      top = top - 1

    elseif code == keyboard.keys.down then
      top = top + 1

    elseif code == keyboard.keys.pageUp then
      top = top - contentHeight

    elseif code == keyboard.keys.pageDown then
      top = top + contentHeight

    elseif code == keyboard.keys.home then
      top = 1

    elseif code == keyboard.keys["end"] then
      top = maxTop

    elseif code == keyboard.keys.back then
      return

    elseif char == string.byte("q") or
           char == string.byte("Q") then
      return
    end
  end
end

----------------------------------------------------------------------
-- Better table dumping
----------------------------------------------------------------------

local function isArray(t)
  local count = 0
  local max = 0

  for k in pairs(t) do
    if type(k) ~= "number" or
       k < 1 or
       k % 1 ~= 0 then
      return false
    end

    count = count + 1

    if k > max then
      max = k
    end
  end

  return count == max
end

local function dumpValue(lines, value, indent, seen)
  indent = indent or ""
  seen = seen or {}

  if type(value) ~= "table" then
    table.insert(lines, indent .. tostring(value))
    return
  end

  if seen[value] then
    table.insert(lines, indent .. "<recursive table>")
    return
  end

  seen[value] = true

  if next(value) == nil then
    table.insert(lines, indent .. "{}")
    return
  end

  local array = isArray(value)

  if array then
    for i = 1, #value do
      local v = value[i]

      if type(v) == "table" then
        table.insert(
          lines,
          indent .. "[" .. i .. "] = {"
        )

        dumpValue(
          lines,
          v,
          indent .. "  ",
          seen
        )

        table.insert(lines, indent .. "}")
      else
        table.insert(
          lines,
          indent ..
          "[" .. i .. "] = " ..
          tostring(v)
        )
      end
    end
  else
    local keys = {}

    for k in pairs(value) do
      table.insert(keys, k)
    end

    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for _, k in ipairs(keys) do
      local v = value[k]

      local key

      if type(k) == "string" then
        key = k
      else
        key = "[" .. tostring(k) .. "]"
      end

      if type(v) == "table" then
        table.insert(
          lines,
          indent .. key .. " = {"
        )

        dumpValue(
          lines,
          v,
          indent .. "  ",
          seen
        )

        table.insert(lines, indent .. "}")
      else
        table.insert(
          lines,
          indent ..
          key .. " = " ..
          tostring(v)
        )
      end
    end
  end
end

----------------------------------------------------------------------
-- Component discovery
----------------------------------------------------------------------

local function getComponents()
  local result = {}

  for address, componentType in component.list() do
    table.insert(result, {
      address = address,
      type = componentType
    })
  end

  table.sort(result, function(a, b)
    if a.type == b.type then
      return a.address < b.address
    end

    return a.type < b.type
  end)

  return result
end

local function getMethods(address)
  local result = {}

  local methods = component.methods(address)

  for name, direct in pairs(methods) do
    table.insert(result, {
      name = name,
      direct = direct,
      doc = component.doc(address, name)
    })
  end

  table.sort(result, function(a, b)
    return a.name < b.name
  end)

  return result
end

----------------------------------------------------------------------
-- Call method
----------------------------------------------------------------------

local function callMethod(address, method)
  local lines = {}

  table.insert(lines, method.name .. "()")

  if method.doc then
    table.insert(lines, "")
    table.insert(lines, "Documentation:")
    table.insert(lines, tostring(method.doc))
  end

  table.insert(lines, "")
  table.insert(lines, "Result:")
  table.insert(lines, "")

  local result = table.pack(
    pcall(function()
      return component.invoke(
        address,
        method.name
      )
    end)
  )

  if not result[1] then
    table.insert(lines, "ERROR:")
    table.insert(lines, tostring(result[2]))

    pager(lines, method.name)
    return
  end

  if result.n == 1 then
    table.insert(lines, "<no return values>")
  else
    for i = 2, result.n do
      if result.n > 2 then
        table.insert(
          lines,
          "Return value #" .. (i - 1) ..
          " [" .. type(result[i]) .. "]"
        )
      else
        table.insert(
          lines,
          "Type: " .. type(result[i])
        )
      end

      dumpValue(
        lines,
        result[i],
        "  "
      )

      table.insert(lines, "")
    end
  end

  pager(lines, method.name)
end

----------------------------------------------------------------------
-- Explore a component
----------------------------------------------------------------------

local function exploreComponent(c)
  while true do
    local methods = getMethods(c.address)

    local choice = selectList(
      c.type .. "  " .. c.address:sub(1, 8),
      methods,
      function(method)
        if method.doc then
          return method.name .. "  -  " .. method.doc
        end

        return method.name
      end
    )

    if not choice then
      return
    end

    callMethod(
      c.address,
      methods[choice]
    )
  end
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

while true do
  local components = getComponents()

  local choice = selectList(
    "Components",
    components,
    function(c)
      return string.format(
        "%-28s %s",
        c.type,
        c.address:sub(1, 8)
      )
    end
  )

  if not choice then
    break
  end

  exploreComponent(components[choice])
end

clear()
