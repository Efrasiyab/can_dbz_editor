# can_dbz_editor

A Zig terminal UI (TUI) CAN database viewer/editor.

> **Warning:** This project is under active development and is not ready for any type of use. Do not rely on it to edit, validate, or export CAN databases.

- Parsing/export is powered by [`can_dbz`](https://github.com/Efrasiyab/can_dbz).
- Terminal rendering and input are powered by [`zigzag`](https://github.com/Efrasiyab/zigzag).
- The canonical on-disk format for saves is **CAN JSON v1** (`.can.json`).
- DBC is supported as **import** and **export**, including selected-bus exports for multi-bus documents (per the `can_dbz` support profile).

CAN JSON v1 preserves environment variables, bus definitions, and typed attribute definitions and assignments. The editor supports message transmitters, signal receivers, and attributes at document, bus, node, message, signal, and environment-variable scopes. DBC import/export supports environment variables, additional message transmitters, and standard typed attributes; bus timing, protocol, description, bus-scoped attributes, and message-level receivers are not representable by the current DBC profile and block export. Multi-bus DBC export prompts for one bus per file because DBC cannot retain bus names; exports from buses other than `can0` report that name loss.

The Metadata tab edits the document name and description, DBC version, document-scoped attributes, and JSON-object extensions.

For multiplexed messages, the filter strip above the Signals list shows every selector in a dropdown box. Click a selector's value to open its cases, then click a case or use Up/Down and Enter; choose `Custom value...` for a signed value not in the list. The filters are independent, and the layout shows common signals plus branches matching all selected nested conditions.

## Quick start

This project requires Zig **0.17.0**. Dependencies are pinned in `build.zig.zon` and fetched by Zig during the build.

Build and run:

```sh
zig build
zig build run -- [--preserve-opaque] [--plain] [--no-mouse] [FILE.dbc | FILE.can.json]
```

Execute the test suite with:

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

## Build checks

`zig build` runs the default `check` gate, compiling the editor and test suite without editor-specific configuration. Use `zig build check` to invoke that gate directly, or `zig build test` to execute the tests. The default check compiles for the selected target, so it also works for cross-compilation.

