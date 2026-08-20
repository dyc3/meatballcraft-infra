set shell := ["sh", "-eu", "-c"]

# List available recipes.
default:
    @just --list

# Initialize and update test infrastructure submodules.
setup:
    git submodule update --init --recursive

# Run the complete test suite.
test: e2e e2e-package-install e2e-rc-services e2e-service-discovery e2e-nuclearcraft-discovery e2e-reactor-network e2e-heat-network e2e-turbine-network e2e-geiger-network e2e-dashboard-network e2e-reactor-relay e2e-reactor-safety e2e-provision-drive

# Build and launch an OPPM-shaped package using only its manifest files.
e2e-package-install:
    ./test/e2e/run test/e2e/fixtures/package-install.lua

# Boot every packaged rc service and verify start, stop, and restart behavior.
e2e-rc-services:
    ./test/e2e/run test/e2e/fixtures/rc-services.lua

# Verify broadcast discovery, offer validation, conflicts, and port ownership.
e2e-service-discovery:
    ./test/e2e/run test/e2e/fixtures/service-discovery.lua

# Verify heat and Geiger service advertisement and client transport selection.
e2e-nuclearcraft-discovery:
    ./test/e2e/run test/e2e/fixtures/nuclearcraft-discovery.lua

# Boot a client, relay, and reactor server with real wireless and Linked Cards.
e2e-reactor-network:
    ./test/e2e/run test/e2e/fixtures/reactor-network.lua

# Boot the real heat client and a provider with separate wireless cards.
e2e-heat-network:
    ./test/e2e/run test/e2e/fixtures/heat-network.lua

# Boot the real turbine client/server with separate wireless cards and a strict turbine component fixture.
e2e-turbine-network:
    ./test/e2e/run test/e2e/fixtures/turbine-network.lua

# Boot the real Geiger client/server and verify live radiation severity colors.
e2e-geiger-network:
    ./test/e2e/run test/e2e/fixtures/geiger-network.lua

# Boot all real service entry points and display their metrics in the aggregate dashboard.
e2e-dashboard-network:
    ./test/e2e/run test/e2e/fixtures/dashboard-network.lua

# Verify reactor requests cross the modem/linked-card relay in OpenOS.
e2e-reactor-relay:
    ./test/e2e/run test/e2e/fixtures/reactor-relay.lua

# Verify the real reactor server deactivates on rising heat above 50%.
e2e-reactor-safety:
    ./test/e2e/run test/e2e/fixtures/reactor-safety.lua

# Verify OpenOS can install to an exact filesystem address used by the provisioner.
e2e-provision-drive:
    ./test/e2e/run test/e2e/fixtures/provision-drive.lua

# Run a Lua program end to end in the OpenComputers emulator.
e2e program="test/e2e/fixtures/smoke.lua":
    ./test/e2e/run {{ quote(program) }}
