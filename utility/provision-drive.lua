local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")

local args, options = shell.parse(...)
local customRepository = "dyc3/meatballcraft-infra"

local function usage(stream)
  stream:write([[
Usage: provision-drive [target] [--source=OpenOS] [--oppm-source=OPPM] [--yes]

Install OpenOS and OPPM from attached installation disks, then copy this
computer's OPPM repository configuration to the new drive. Labels and address
prefixes are accepted. Without a target, an interactive drive picker is shown.
]])
end

local function fail(message)
  io.stderr:write("provision-drive: ", tostring(message), "\n")
  return 1
end

local function filesystems(writableOnly)
  local result = {}
  local root = filesystem.get("/")
  local bootAddress = computer.getBootAddress()
  local temporaryAddress = computer.tmpAddress()

  for address in component.list("filesystem", true) do
    local proxy = component.proxy(address)
    if not writableOnly or
        not proxy.isReadOnly() and address ~= bootAddress and
        address ~= temporaryAddress and address ~= root.address then
      result[#result + 1] = proxy
    end
  end
  table.sort(result, function(left, right)
    return left.address < right.address
  end)
  return result
end

local function matches(proxy, filter)
  local label = proxy.getLabel()
  return label and label:lower() == filter:lower() or proxy.address:sub(1, #filter) == filter
end

local function findFilesystem(filter, writableOnly, installationSource)
  local found
  for _, proxy in ipairs(filesystems(writableOnly)) do
    if matches(proxy, filter) and (not installationSource or proxy.exists("/.prop")) then
      if found then
        return nil, "'" .. filter .. "' matches multiple drives; use a longer address"
      end
      found = proxy
    end
  end
  if not found then
    return nil, "no " .. (writableOnly and "writable " or "installation ") .. "drive matches '" .. filter .. "'"
  end
  return found
end

local function chooseTarget()
  local choices = filesystems(true)
  if #choices == 0 then
    return nil, "no writable target drives are attached"
  end

  print("Select the new server drive:")
  for index, proxy in ipairs(choices) do
    print(string.format(
      "  %d) %-16s %7d KiB  %s",
      index,
      proxy.getLabel() or "<unlabeled>",
      math.floor(proxy.spaceTotal() / 1024),
      proxy.address
    ))
  end
  io.write("Drive number (or q to cancel): ")
  local answer = io.read()
  if answer == "q" or answer == "Q" or answer == nil then
    return nil, "cancelled"
  end
  local index = tonumber(answer)
  if not index or not choices[index] then
    return nil, "invalid drive selection"
  end
  return choices[index]
end

local function mountPath(address)
  local best
  for proxy, path in filesystem.mounts() do
    if proxy.address == address and (not best or #path < #best) then
      best = path
    end
  end
  return best
end

local function removeTree(proxy, path, keepRoot)
  if proxy.isDirectory(path) then
    local entries, reason = proxy.list(path)
    if not entries then return nil, reason end
    for _, name in ipairs(entries) do
      name = name:gsub("/$", "")
      local child = path == "/" and "/" .. name or path .. "/" .. name
      local ok, removeReason = removeTree(proxy, child, false)
      if not ok then return nil, removeReason end
    end
    if keepRoot then return true end
  end
  local ok, reason = proxy.remove(path)
  if not ok then return nil, reason end
  return true
end

local function install(source, target)
  local command = string.format(
    "install --from=%s --to=%s --noreboot --nosetboot",
    source.address,
    target.address
  )
  local originalRead = io.read
  io.read = function() return "y" end
  local result = table.pack(pcall(shell.execute, command))
  io.read = originalRead
  if not result[1] then return false, result[2] end
  return table.unpack(result, 2, result.n)
end

local function readFile(path)
  local file, reason = io.open(path, "r")
  if not file then return nil, reason end
  local value = file:read("*a")
  file:close()
  return value
end

local function writeFile(path, value)
  local file, reason = io.open(path, "w")
  if not file then return nil, reason end
  local ok, writeReason = file:write(value)
  file:close()
  return ok, writeReason
end

local function readSerialized(path)
  local file, reason = io.open(path, "r")
  if not file then return nil, reason end
  local value = serialization.unserialize(file:read("*a"))
  file:close()
  if type(value) ~= "table" then
    return nil, path .. " is not valid serialized data"
  end
  return value
end

local function writeSerialized(path, value)
  local file, reason = io.open(path, "w")
  if not file then return nil, reason end
  local ok, writeReason = file:write(serialization.serialize(value))
  file:close()
  return ok, writeReason
end

if options.help or options.h then
  usage(io.stdout)
  return 0
end

if #args > 1 then
  usage(io.stderr)
  return fail("too many arguments")
end

if not filesystem.exists("/etc/oppm.cfg") then
  return fail("/etc/oppm.cfg is missing; register the custom repository first")
end
local oppmState, stateReason = readSerialized("/etc/opdata.svd")
if not oppmState then
  return fail("could not read OPPM repository registry: " .. tostring(stateReason))
end
if not oppmState._repos or not oppmState._repos[customRepository] then
  return fail("custom repository is not registered; run 'oppm register " .. customRepository .. "' first")
end

local sourceFilter = options.source or "OpenOS"
if type(sourceFilter) ~= "string" then
  return fail("--source requires a label or address, for example --source=OpenOS")
end
local source, sourceReason = findFilesystem(sourceFilter, false, true)
if not source then return fail(sourceReason) end

local oppmFilter = options["oppm-source"] or "OPPM"
if type(oppmFilter) ~= "string" then
  return fail("--oppm-source requires a label or address, for example --oppm-source=OPPM")
end

local target, targetReason
if args[1] then
  target, targetReason = findFilesystem(args[1], true)
else
  target, targetReason = chooseTarget()
end
if not target then return fail(targetReason) end
if target.address == source.address then
  return fail("the OpenOS source and target must be different drives")
end

if not options.yes then
  io.write("ERASE and provision ", target.getLabel() or "<unlabeled>", " (", target.address, ")? [y/N] ")
  local answer = (io.read() or ""):lower()
  if answer ~= "y" and answer ~= "yes" then
    print("Cancelled; target was not changed")
    return 2
  end
end

print("Erasing target drive...")
local erased, eraseReason = removeTree(target, "/", true)
if not erased then
  return fail("could not erase target: " .. tostring(eraseReason))
end

print("Installing OpenOS...")
local installed, installReason = install(source, target)
if not installed then
  return fail("OpenOS installer failed: " .. tostring(installReason))
end
if not target.exists("/init.lua") then
  return fail("OpenOS installation was cancelled or did not install init.lua")
end

local targetMount = mountPath(target.address)
if not targetMount then
  return fail("OpenOS installed, but the target mount point could not be found")
end

local oppmSource, oppmSourceReason = findFilesystem(oppmFilter, false, true)
if not oppmSource then
  print("Remove the OpenOS disk and insert the OPPM installation disk.")
  print("Waiting for the OPPM disk...")
  repeat
    os.sleep(1)
    oppmSource, oppmSourceReason = findFilesystem(oppmFilter, false, true)
  until oppmSource
end
if target.address == oppmSource.address then
  return fail("the OPPM source and target must be different drives")
end

print("Installing OPPM...")
local originalState, originalStateReason = readFile("/etc/opdata.svd")
if not originalState then
  return fail("could not preserve provisioning computer's OPPM state: " .. tostring(originalStateReason))
end
local isolatedState = {_repos = oppmState._repos}
local isolated, isolateReason = writeSerialized("/etc/opdata.svd", isolatedState)
if not isolated then
  return fail("could not isolate OPPM package state: " .. tostring(isolateReason))
end

local installCallOk, installResult, installFailure = pcall(install, oppmSource, target)
local generatedState = readSerialized("/etc/opdata.svd")
local restored, restoreReason = writeFile("/etc/opdata.svd", originalState)
if not restored then
  return fail("could not restore provisioning computer's OPPM state: " .. tostring(restoreReason))
end
installed = installCallOk and installResult
installReason = installCallOk and installFailure or installResult
if not installed or not generatedState or not generatedState.oppm or not target.exists("/usr/bin/oppm.lua") then
  return fail("OPPM installation was cancelled or failed: " .. tostring(installReason))
end

print("Copying custom repository configuration...")
local configTarget = filesystem.concat(targetMount, "/etc/oppm.cfg")
local copied, copyReason = filesystem.copy("/etc/oppm.cfg", configTarget)
if not copied then
  return fail("OPPM installed, but repository configuration failed: " .. tostring(copyReason))
end
local stateTarget = filesystem.concat(targetMount, "/etc/opdata.svd")
local stateWritten, stateWriteReason = writeSerialized(stateTarget, {
  oppm = generatedState.oppm,
  _repos = oppmState._repos
})
if not stateWritten then
  return fail("OPPM installed, but repository registry failed: " .. tostring(stateWriteReason))
end

print("Provisioning complete. The drive is ready for the new server.")
return 0
