local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")

local repositoryMount
local target
for proxy, path in filesystem.mounts() do
  if proxy.getLabel() == "e2e" then
    repositoryMount = path
  end
  if proxy.exists("/.provision-drive-e2e") or proxy.getLabel() == "provision-target" then
    target = proxy
  end
end

assert(repositoryMount, "e2e filesystem was not mounted")
assert(target, "provisioning target was not found")

if target.exists("/.provision-drive-e2e") then
  local root = filesystem.get("/")
  assert(root.address == target.address, "machine did not boot from the provisioned drive")
  assert(filesystem.exists("/usr/bin/oppm.lua"), "OPPM is missing after boot")

  local ran, reason = shell.execute("oppm list -i > /tmp/oppm-e2e-output")
  assert(ran, reason)
  local output = assert(io.open("/tmp/oppm-e2e-output", "r"))
  local text = output:read("*a")
  output:close()
  assert(text:find("oppm", 1, true), "installed OPPM did not report its own installed package record")

  local data = assert(io.open("/etc/opdata.svd", "r"))
  local state = serialization.unserialize(data:read("*a"))
  data:close()
  assert(state and state.oppm, "installed OPPM package record is missing")
  assert(state._repos and state._repos["dyc3/meatballcraft-infra"],
    "custom repository is not registered")

  print("Provisioned drive booted with usable OPPM and custom repository")
  return
end

assert(target.exists("/stale-file"), "test target must begin with stale data")
local provision = assert(loadfile(repositoryMount .. "/repo/utility/provision-drive.lua"))
local originalRead = io.read
local confirmations = 0
io.read = function()
  confirmations = confirmations + 1
  assert(confirmations == 1, "provisioning requested more than one keyboard confirmation")
  return "y"
end
local result = provision(target.address)
io.read = originalRead
assert(result == 0, "provision-drive failed with status " .. tostring(result))
assert(confirmations == 1, "provisioning did not request its initial destructive confirmation")
assert(not target.exists("/stale-file"), "provisioning did not erase stale target data")
assert(target.exists("/init.lua"), "OpenOS init.lua was not installed")
assert(target.exists("/usr/bin/oppm.lua"), "OPPM was not installed")

local targetMount
for proxy, path in filesystem.mounts() do
  if proxy.address == target.address then
    targetMount = path
    break
  end
end
assert(targetMount, "provisioned target is not mounted")
assert(filesystem.copy(repositoryMount .. "/autorun.lua", targetMount .. "/autorun.lua"))

local marker = assert(target.open("/.provision-drive-e2e", "w"))
assert(target.write(marker, "reboot into provisioned drive\n"))
target.close(marker)

computer.setBootAddress(target.address)
assert(computer.getBootAddress() == target.address, "could not select provisioned drive for boot")
computer.shutdown(true)
