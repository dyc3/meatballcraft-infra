set shell := ["sh", "-eu", "-c"]

# List available recipes.
default:
    @just --list

# Initialize and update test infrastructure submodules.
setup:
    git submodule update --init --recursive

# Run the complete test suite.
test: e2e e2e-reactor-relay

# Verify reactor requests cross the modem/linked-card relay in OpenOS.
e2e-reactor-relay:
    ./test/e2e/run test/e2e/fixtures/reactor-relay.lua

# Run a Lua program end to end in the OpenComputers emulator.
e2e program="test/e2e/fixtures/smoke.lua":
    ./test/e2e/run {{ quote(program) }}
