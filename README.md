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
