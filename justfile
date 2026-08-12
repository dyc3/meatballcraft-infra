set shell := ["sh", "-eu", "-c"]

# List available recipes.
default:
    @just --list

# Initialize and update test infrastructure submodules.
setup:
    git submodule update --init --recursive

# Run the complete test suite.
test: e2e e2e-reactor-relay e2e-provision-drive

# Verify reactor requests cross the modem/linked-card relay in OpenOS.
e2e-reactor-relay:
    ./test/e2e/run test/e2e/fixtures/reactor-relay.lua

# Verify OpenOS can install to an exact filesystem address used by the provisioner.
e2e-provision-drive:
    ./test/e2e/run test/e2e/fixtures/provision-drive.lua

# Run a Lua program end to end in the OpenComputers emulator.
e2e program="test/e2e/fixtures/smoke.lua":
    ./test/e2e/run {{ quote(program) }}
