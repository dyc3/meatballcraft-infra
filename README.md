# MeatballCraft OpenComputers packages

This repo contains the code that my friends and I used for various automations during our playthrough.

This repository is an [OpenPrograms Package Manager (OPPM)](https://ocdoc.cil.li/tutorial:program:oppm) package source for OpenComputers.

## Register the repository

Register this repository on an OpenComputers machine with:

```sh
oppm register dyc3/meatballcraft-infra
```

OPPM requires the default branch to be named `master` and reads package definitions from [`programs.cfg`](programs.cfg) at the repository root.

## Add a package

Place the package files in a directory in this repository and add an entry to `programs.cfg`:

```lua
{
  ["example-package"] = {
    files = {
      ["master/example-package/example.lua"] = "/bin"
    },
    name = "Example package",
    description = "A short description",
    authors = "Your name",
    repo = "tree/master/example-package"
  }
}
```

Paths such as `/bin` are relative to the selected OPPM installation root (normally `/usr`). Use a double slash, such as `//etc`, only for an absolute destination. Do not leave example entries in `programs.cfg` unless their referenced files exist.

## End-to-end testing

The test harness boots a real OpenComputers machine in [Ocelot Brain](https://gitlab.com/cc-ru/ocelot/ocelot-brain), starts its bundled OpenOS 1.8.9, mounts this repository as a disk, and runs a Lua program inside the emulated computer.

Initialize the emulator submodule after cloning:

```sh
git submodule update --init --recursive
```

Run the smoke test with JDK 17 (the first run downloads the pinned sbt launcher and Scala dependencies):

```sh
./test/e2e/run
```

The runner finds common Linux JDK 17 installations automatically. Elsewhere, set `OC_E2E_JAVA` to the path of a JDK 17 `java` executable; Ocelot's pinned Scala 2.13.10 compiler is not compatible with JDK 21.

Run any repository-relative Lua program that terminates on its own:

```sh
./test/e2e/run path/to/program.lua
```

The runner provides a tier-three CPU, memory, GPU, screen, keyboard, the Lua BIOS, OpenOS, and a writable disk. Programs needing mod-specific components or user input need a purpose-built fixture before they can complete unattended.
