# Repository guidance

This repository is an OpenPrograms Package Manager (OPPM) source for Lua programs used with the OpenComputers Minecraft mod.

- Keep the default branch named `master`; paths in `programs.cfg` depend on it.
- Put executable programs in their feature directory and reusable modules under a `lib/` tree that matches their Lua `require` path.
- Update `programs.cfg` whenever package files, install destinations, or requirements change. Every listed source file must exist.
- Preserve OpenComputers/OpenOS compatibility; do not assume host Lua libraries or APIs are available.
- Initialize dependencies with `just setup`.
- Run `just test` before finishing changes. Use `just e2e path/to/program.lua` for a terminating program that can run with the standard emulated components.
- The end-to-end harness uses Ocelot Brain, OpenOS 1.8.9, and JDK 17. Programs requiring Minecraft mod components or interactive input need dedicated fixtures.
- Treat `test/ocelot-brain` as vendored upstream code: do not edit it for repository features.
