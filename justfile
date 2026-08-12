set shell := ["sh", "-eu", "-c"]

# List available recipes.
default:
    @just --list

# Initialize and update test infrastructure submodules.
setup:
    git submodule update --init --recursive

# Run the complete test suite.
test: e2e

# Run a Lua program end to end in the OpenComputers emulator.
e2e program="test/e2e/fixtures/smoke.lua":
    ./test/e2e/run {{ quote(program) }}
