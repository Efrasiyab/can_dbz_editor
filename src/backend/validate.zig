const std = @import("std");
const can_dbz = @import("can_dbz");

pub const Group = enum { parse, validation, export_dbc };

pub const Item = struct {
    group: Group,
    severity: can_dbz.diagnostic.Severity,
    text: []const u8,
    bus: ?[]const u8 = null,
    message: ?[]const u8 = null,
    signal: ?[]const u8 = null,
    /// Export items only: true when the DBC writer cannot proceed, false for an omission it would report.
    blocking: bool = false,
};

/// Owns every string it stores, so entries survive the document they came from.
pub const List = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *List) void {
        self.clear();
        self.items.deinit(self.gpa);
    }

    pub fn clear(self: *List) void {
        for (self.items.items) |it| self.freeItem(it);
        self.items.clearRetainingCapacity();
    }

    pub fn clearGroup(self: *List, group: Group) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].group == group) {
                self.freeItem(self.items.items[i]);
                _ = self.items.orderedRemove(i);
            } else i += 1;
        }
    }

    fn freeItem(self: *List, it: Item) void {
        self.gpa.free(it.text);
        if (it.bus) |s| self.gpa.free(s);
        if (it.message) |s| self.gpa.free(s);
        if (it.signal) |s| self.gpa.free(s);
    }

    pub fn add(
        self: *List,
        group: Group,
        severity: can_dbz.diagnostic.Severity,
        text: []const u8,
        ctx: can_dbz.diagnostic.Context,
    ) !void {
        const t = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(t);
        const bus = try dupeOpt(self.gpa, ctx.bus);
        errdefer if (bus) |s| self.gpa.free(s);
        const msg = try dupeOpt(self.gpa, ctx.message);
        errdefer if (msg) |s| self.gpa.free(s);
        const sig = try dupeOpt(self.gpa, ctx.signal);
        errdefer if (sig) |s| self.gpa.free(s);
        try self.items.append(self.gpa, .{
            .group = group,
            .severity = severity,
            .text = t,
            .bus = bus,
            .message = msg,
            .signal = sig,
        });
    }

    /// Copies library diagnostics; `with_context` must be false when the source document is gone.
    pub fn addAll(self: *List, group: Group, diags: []const can_dbz.diagnostic.Diagnostic, with_context: bool) !void {
        for (diags) |d| {
            const text = switch (d.source) {
                .dbc => |loc| try std.fmt.allocPrint(self.gpa, "{s}: {s} (dbc {d}:{d})", .{ @tagName(d.code), d.message, loc.line, loc.column }),
                else => try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ @tagName(d.code), d.message }),
            };
            defer self.gpa.free(text);
            try self.add(group, d.severity, text, if (with_context) d.context else .{});
        }
    }

    /// Adds an export item; blockers are stored as warnings so they do not inflate the error count.
    pub fn addExport(self: *List, d: can_dbz.diagnostic.Diagnostic) !void {
        const text = try std.fmt.allocPrint(self.gpa, "DBC export: {s}", .{d.message});
        defer self.gpa.free(text);
        try self.add(.export_dbc, .warning, text, d.context);
        self.items.items[self.items.items.len - 1].blocking = d.severity == .@"error";
    }

    pub fn count(self: *const List, severity: can_dbz.diagnostic.Severity) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (it.severity == severity) n += 1;
        }
        return n;
    }
};

fn dupeOpt(gpa: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try gpa.dupe(u8, v) else null;
}

/// General validation: semantic checks plus DBC export feasibility.
pub fn validateAll(gpa: std.mem.Allocator, doc: *const can_dbz.model.Document, list: *List) !void {
    list.clearGroup(.validation);

    var diags: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    _ = try can_dbz.validate.validateDocument(doc, gpa, &diags);
    try list.addAll(.validation, diags.items, true);

    try validateDbcExport(gpa, doc, list, null);
}

/// Checks DBC export feasibility for one bus, or for the whole document when `bus_name` is null.
pub fn validateDbcExport(gpa: std.mem.Allocator, doc: *const can_dbz.model.Document, list: *List, bus_name: ?[]const u8) !void {
    list.clearGroup(.export_dbc);

    var blockers: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer blockers.deinit(gpa);
    const written = if (bus_name) |name|
        can_dbz.formats.dbc.writeForBusWithDiagnostics(gpa, doc, name, &blockers)
    else
        can_dbz.formats.dbc.writeWithDiagnostics(gpa, doc, &blockers);
    for (blockers.items) |d| try list.addExport(d);
    if (written) |bytes| {
        gpa.free(bytes);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedConstruct => if (blockers.items.len == 0) {
            try list.addExport(.{ .severity = .@"error", .code = .unsupported_dbc_export, .message = "document contains constructs the supported DBC profile cannot express" });
        },
        error.InvalidDbc => try list.addExport(.{ .severity = .@"error", .code = .unsupported_dbc_export, .message = "document is not representable as DBC" }),
        error.UnknownBus => {
            for (blockers.items) |d| {
                if (d.code == .unknown_bus) return;
            }
            try list.addExport(.{ .severity = .@"error", .code = .unknown_bus, .message = "DBC export references a bus that is not defined" });
        },
    }
}

/// True when the document carries DBC statements that were kept as opaque text.
pub fn hasOpaqueStatements(doc: *const can_dbz.model.Document) bool {
    const meta = doc.dbc orelse return false;
    if (meta != .object) return false;
    const stmts = meta.object.get("opaque_statements") orelse return false;
    return stmts == .array and stmts.array.items.len > 0;
}

test "export items separate blockers from omissions" {
    var doc = can_dbz.model.Document.init(std.testing.allocator);
    defer doc.deinit();
    doc.name = "Named";
    try doc.buses.append(doc.allocator(), .{ .name = "other" });
    var list = List.init(std.testing.allocator);
    defer list.deinit();
    try validateAll(std.testing.allocator, &doc, &list);
    var blocking: usize = 0;
    var omitted: usize = 0;
    for (list.items.items) |it| {
        if (it.group != .export_dbc) continue;
        if (it.blocking) blocking += 1 else omitted += 1;
    }
    try std.testing.expect(blocking >= 1);
    try std.testing.expect(omitted >= 1);
}

test "selected bus export reviews only that bus and reports DBC name loss" {
    var doc = can_dbz.model.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.buses.append(doc.allocator(), .{ .name = "can0" });
    try doc.buses.append(doc.allocator(), .{ .name = "can1" });
    var list = List.init(std.testing.allocator);
    defer list.deinit();

    try validateDbcExport(std.testing.allocator, &doc, &list, "can1");

    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    try std.testing.expect(!list.items.items[0].blocking);
    try std.testing.expect(std.mem.indexOf(u8, list.items.items[0].text, "bus name") != null);
}

test "selected bus export blocks unknown bus names once" {
    var doc = can_dbz.model.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.buses.append(doc.allocator(), .{ .name = "can0" });
    var list = List.init(std.testing.allocator);
    defer list.deinit();

    try validateDbcExport(std.testing.allocator, &doc, &list, "missing");

    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    try std.testing.expect(list.items.items[0].blocking);
    try std.testing.expect(std.mem.indexOf(u8, list.items.items[0].text, "selected DBC export bus is not defined") != null);
}
