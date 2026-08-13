# Repository guidance

This repository is an OpenPrograms Package Manager (OPPM) source for Lua programs used with the OpenComputers Minecraft mod.

- Keep the default branch named `master`; paths in `programs.cfg` depend on it.
- Put executable programs in their feature directory and reusable modules under a `lib/` tree that matches their Lua `require` path.
- Update `programs.cfg` whenever package files, install destinations, or requirements change. Every listed source file must exist.
- Preserve OpenComputers/OpenOS compatibility; do not assume host Lua libraries or APIs are available.
- Initialize dependencies with `just setup`.
- Run `just test` before finishing changes. Use `just e2e path/to/program.lua` for a terminating program that can run with the standard emulated components.
- The end-to-end harness uses Ocelot Brain, OpenOS 1.8.9, and JDK 17. Programs requiring Minecraft mod components or interactive input need dedicated fixtures.
- Networked programs require realistic end-to-end coverage. Boot separate emulated OpenOS computers with the same card topology used in production, run the actual client/server/relay entry points where components permit, and verify discovery is followed by a successful application request and response. Transport mocks alone are not sufficient.
- End-to-end tests must cover user-visible failure paths as well as success, including zero discovered services, timeouts, malformed responses, and server handler failures when relevant. Assert the diagnostic text rendered to the user and ensure expected operational errors exit cleanly without stack traces.
- When a Minecraft component cannot be emulated, keep the real networking and program entry points in the topology and substitute only that component boundary. Component fixtures must match the documented mod API and should reject unknown methods so API-name mistakes fail tests.
- Treat `test/ocelot-brain` as vendored upstream code: do not edit it for repository features.
