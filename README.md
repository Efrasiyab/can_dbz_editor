# can_dbz_editor

A Zig terminal UI (TUI) CAN database viewer/editor.

> **Warning:** This project is under active development and is not ready for any type of use. Do not rely on it to edit, validate, or export CAN databases.

- Parsing/export is powered by [`can_dbz`](https://github.com/Efrasiyab/can_dbz).
- Terminal rendering and input are powered by [`zigzag`](https://github.com/Efrasiyab/zigzag).
- The canonical on-disk format for saves is **CAN JSON v1** (`.can.json`).
- DBC is supported as **import** and **export** (limited profile, per `can_dbz`).

## Quick start

This project requires Zig **0.17.0**. Dependencies are pinned in `build.zig.zon` and fetched by Zig during the build.

Build and run:

```sh
zig build
zig build run -- [--preserve-opaque] [--plain] [--no-mouse] [FILE.dbc | FILE.can.json]
```

Run the test suite with:

```sh
zig build test
```

DBC import is strict by default; pass `--preserve-opaque` to retain unsupported statements. `--plain` disables colors and video attributes, and `--no-mouse` leaves terminal text selection available.

## Build for Linux and Windows

These commands produce optimized x86-64 binaries in separate output directories:

```sh
# Linux x86-64
zig build -Dtarget=x86_64-linux-gnu -Doptimize=fast -p zig-out/linux-x86_64

# Windows x86-64
zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast -p zig-out/windows-x86_64
```

The binaries are written to `zig-out/linux-x86_64/bin/can_dbz_editor` and `zig-out/windows-x86_64/bin/can_dbz_editor.exe`.

Run tests with `zig build test`.

## VS Code / ZLS dependency awareness

Two things help ZLS resolve fetched dependencies reliably:

1. `build.zig` uses `b.dependency(...)` / `addImport(...)` to expose modules to the build.
2. The project defines a `check` build step. Many editor setups run `zig build check` on save.

This repo includes a default config in `.vscode/settings.json` that sets `zig.buildOnSaveProvider` to `zls` and relies on the `check` step.

