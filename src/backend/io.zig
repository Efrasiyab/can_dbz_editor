const std = @import("std");
const can_dbz = @import("can_dbz");
const validate = @import("validate.zig");

pub const Format = enum { dbc, can_json };
pub const DbcMode = enum { strict, preserve_opaque };

pub const max_file_size = 64 * 1024 * 1024;

pub const Loaded = struct {
    doc: can_dbz.model.Document,
    format: Format,
    /// can_dbz's DBC parser borrows number strings from its input, so the bytes must outlive the document.
    source: ?[]u8 = null,
};

pub fn detectFormat(path: []const u8) ?Format {
    if (std.ascii.endsWithIgnoreCase(path, ".dbc")) return .dbc;
    if (std.ascii.endsWithIgnoreCase(path, ".can.json") or std.ascii.endsWithIgnoreCase(path, ".json")) return .can_json;
    return null;
}

/// Parse diagnostics are added to `diags`; returns error.ParseFailed when the file is rejected.
pub fn open(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    format_override: ?Format,
    mode: DbcMode,
    diags: *validate.List,
) !Loaded {
    const format = format_override orelse detectFormat(path) orelse return error.UnknownFormat;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size));
    var keep_bytes = false;
    defer if (!keep_bytes) gpa.free(bytes);

    var found: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer found.deinit(gpa);

    switch (format) {
        .can_json => {
            const doc = can_dbz.formats.can_json.parseWithDiagnostics(gpa, bytes, &found) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try diags.addAll(.parse, found.items, false);
                    if (found.items.len == 0) try diags.add(.parse, .@"error", "invalid CAN JSON document", .{});
                    return error.ParseFailed;
                },
            };
            return .{ .doc = doc, .format = format };
        },
        .dbc => {
            const opts: can_dbz.formats.dbc.ParseOptions = .{ .preserve_unsupported_statements = mode == .preserve_opaque };
            const doc = can_dbz.formats.dbc.parseWithOptions(gpa, bytes, &found, opts) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try diags.addAll(.parse, found.items, false);
                    if (found.items.len == 0) try diags.add(.parse, .@"error", "invalid or unsupported DBC file", .{});
                    return error.ParseFailed;
                },
            };
            try diags.addAll(.parse, found.items, true);
            keep_bytes = true;
            return .{ .doc = doc, .format = format, .source = bytes };
        },
    }
}

pub fn saveCanJson(gpa: std.mem.Allocator, io: std.Io, doc: *const can_dbz.model.Document, path: []const u8) !void {
    const bytes = try can_dbz.formats.can_json.write(gpa, doc);
    defer gpa.free(bytes);
    try atomicWrite(gpa, io, path, bytes);
}

/// Returns error.UnsupportedConstruct before touching the filesystem when DBC cannot express the model.
pub fn exportDbc(gpa: std.mem.Allocator, io: std.Io, doc: *const can_dbz.model.Document, path: []const u8) !void {
    const bytes = try can_dbz.formats.dbc.write(gpa, doc);
    defer gpa.free(bytes);
    try atomicWrite(gpa, io, path, bytes);
}

/// Writes `path.tmp`, syncs, then renames over `path`.
pub fn atomicWrite(gpa: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    {
        var file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        errdefer cwd.deleteFile(io, tmp) catch {};
        try file.writeStreamingAll(io, data);
        file.sync(io) catch {};
    }
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

/// Default CAN JSON destination next to `path`: `foo.dbc` -> `foo.can.json`.
pub fn siblingPath(gpa: std.mem.Allocator, path: []const u8, ext: []const u8) ![]u8 {
    var base = path;
    for ([_][]const u8{ ".can.json", ".json", ".dbc" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(base, suffix)) {
            base = base[0 .. base.len - suffix.len];
            break;
        }
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, ext });
}
