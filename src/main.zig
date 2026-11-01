const std = @import("std");
const zz = @import("zigzag");
const app_mod = @import("app.zig");
const keymap_mod = @import("keymap.zig");
const ui = @import("ui.zig");

test {
    _ = @import("app.zig");
    _ = @import("keymap.zig");
    _ = @import("backend/ops.zig");
    _ = @import("domain/layout.zig");
    _ = @import("domain/payload.zig");
    _ = @import("backend/validate.zig");
    _ = @import("ui.zig");
}

const usage =
    \\usage: can_dbz_editor [--preserve-opaque] [--plain] [--no-mouse] [FILE.dbc | FILE.can.json]
    \\
    \\  --preserve-opaque  import DBC keeping unsupported statements (default: strict)
    \\  --plain            no colors or video attributes; selection shown with > and * markers (also NO_COLOR)
    \\  --no-mouse         do not capture the mouse (keeps the terminal's own text selection)
    \\
;

fn readKeymap(init: std.process.Init, km: *keymap_mod.Keymap) void {
    const gpa = init.gpa;
    var path_buf: ?[]u8 = null;
    defer if (path_buf) |p| gpa.free(p);
    const path: []const u8 = if (init.environ_map.get("CAN_DBZ_EDITOR_KEYS")) |p| p else blk: {
        const home = init.environ_map.get("HOME") orelse return;
        path_buf = std.fmt.allocPrint(gpa, "{s}/.config/can_dbz_editor/keys.conf", .{home}) catch return;
        break :blk path_buf.?;
    };
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(text);
    _ = km.applyConfig(text);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var path: ?[]const u8 = null;
    var preserve = false;
    var mouse = true;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-mouse")) {
            mouse = false;
        } else if (std.mem.eql(u8, arg, "--preserve-opaque")) {
            preserve = true;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            ui.plain = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (path == null and !std.mem.startsWith(u8, arg, "-")) {
            path = arg;
        } else {
            std.debug.print("{s}", .{usage});
            return error.InvalidArguments;
        }
    }

    var app = try app_mod.App.init(gpa, init.io);
    if (init.environ_map.get("NO_COLOR")) |v| {
        if (v.len > 0) ui.plain = true;
    }
    if (preserve) app.dbc_mode = .preserve_opaque;

    var model: ui.Model = .{ .app = app };
    readKeymap(init, &model.keymap);
    if (path) |p| {
        model.app.open(p) catch |e| {
            // The TUI starts anyway so parse diagnostics can be inspected.
            try model.setStatus("Failed to open {s}: {s}", .{ p, @errorName(e) });
        };
    }

    if (path == null) try model.promptCreate();

    var program = zz.Program(ui.Model).initWithModel(gpa, init.io, init.environ_map, model, .{ .mouse = mouse });
    defer program.deinit();
    try program.run();
}
