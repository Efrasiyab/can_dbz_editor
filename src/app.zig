const std = @import("std");
const can_dbz = @import("can_dbz");
const cio = @import("backend/io.zig");
const vd = @import("backend/validate.zig");
const ops = @import("backend/ops.zig");

pub const Document = can_dbz.model.Document;

const max_undo = 200;
/// Idle ticks after the last edit before validation runs.
pub const validate_delay_ticks = 3;

pub const Pos = struct { msg: usize, sig: ?usize = null };

/// Snapshot taken before an edit, with the revision it restores.
const Entry = struct { bytes: []u8, rev: u64 };

/// Size and modification time of the file as last read or written by this session.
pub const Stamp = struct { size: u64, mtime: i96 };

fn stampOf(io: std.Io, path: []const u8) ?Stamp {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    doc: Document,
    /// File the document was loaded from.
    path: ?[]u8 = null,
    format: cio.Format = .can_json,
    dbc_mode: cio.DbcMode = .strict,
    /// CAN JSON destination; null until the user picks one.
    save_path: ?[]u8 = null,
    /// Current and last-saved revision; the document is clean exactly when they match.
    rev: u64 = 0,
    next_rev: u64 = 0,
    saved_rev: u64 = 0,
    /// Fingerprint of `path` at the last open or save; null for files this session has not touched.
    stamp: ?Stamp = null,
    /// Raw DBC bytes the current document may borrow from; dropped once the document is replaced.
    doc_source: ?[]u8 = null,
    diags: vd.List,
    undo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    redo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    validate_countdown: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !App {
        var doc = Document.init(gpa);
        errdefer doc.deinit();
        _ = try ops.addBus(&doc, "can0");
        return .{ .gpa = gpa, .io = io, .doc = doc, .diags = .init(gpa) };
    }

    pub fn deinit(self: *App) void {
        self.doc.deinit();
        self.dropSource();
        self.clearStacks();
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.diags.deinit();
        if (self.path) |p| self.gpa.free(p);
        if (self.save_path) |p| self.gpa.free(p);
    }

    fn dropSource(self: *App) void {
        if (self.doc_source) |s| self.gpa.free(s);
        self.doc_source = null;
    }

    fn clearStacks(self: *App) void {
        for (self.undo_stack.items) |e| self.gpa.free(e.bytes);
        for (self.redo_stack.items) |e| self.gpa.free(e.bytes);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    fn replaceStr(self: *App, slot: *?[]u8, value: ?[]const u8) !void {
        const new = if (value) |v| try self.gpa.dupe(u8, v) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = new;
    }

    pub fn open(self: *App, path: []const u8) !void {
        self.diags.clearGroup(.parse);
        var loaded = try cio.open(self.gpa, self.io, path, null, self.dbc_mode, &self.diags);
        errdefer loaded.doc.deinit();
        try self.replaceStr(&self.path, path);
        try self.replaceStr(&self.save_path, if (loaded.format == .can_json) path else null);
        self.doc.deinit();
        self.dropSource();
        self.doc = loaded.doc;
        self.doc_source = loaded.source;
        self.format = loaded.format;
        self.rev = 0;
        self.next_rev = 0;
        self.saved_rev = 0;
        self.stamp = stampOf(self.io, path);
        self.clearStacks();
        try self.revalidate();
    }

    /// Replaces the document with an empty one that has a single bus and no file.
    pub fn reset(self: *App) !void {
        var doc = Document.init(self.gpa);
        errdefer doc.deinit();
        _ = try ops.addBus(&doc, "can0");
        self.doc.deinit();
        self.dropSource();
        self.doc = doc;
        try self.replaceStr(&self.path, null);
        try self.replaceStr(&self.save_path, null);
        self.format = .can_json;
        self.rev = 0;
        self.next_rev = 0;
        self.saved_rev = 0;
        self.stamp = null;
        self.clearStacks();
        try self.revalidate();
    }

    /// Suggested destination for Save: the current file, else a new CAN JSON file.
    pub fn defaultSavePath(self: *App) ![]u8 {
        if (self.path) |p| return self.gpa.dupe(u8, p);
        return self.gpa.dupe(u8, "untitled.can.json");
    }

    pub fn defaultExportPath(self: *App) ![]u8 {
        if (self.save_path) |p| return cio.siblingPath(self.gpa, p, ".dbc");
        if (self.path) |p| return cio.siblingPath(self.gpa, p, ".dbc");
        return self.gpa.dupe(u8, "untitled.dbc");
    }

    pub fn isDirty(self: *const App) bool {
        return self.rev != self.saved_rev;
    }

    /// Writes in the format given by the extension (.dbc or CAN JSON) and makes `path` the current file.
    /// Fails with error.ExternalChange when the file was modified outside this session since it was opened or saved.
    pub fn save(self: *App, path: []const u8) !void {
        if (self.stamp) |s| {
            const same_file = if (self.path) |p| std.mem.eql(u8, p, path) else false;
            if (same_file) {
                const now = stampOf(self.io, path) orelse return error.ExternalChange;
                if (now.size != s.size or now.mtime != s.mtime) return error.ExternalChange;
            }
        }
        try self.saveForce(path);
    }

    /// Like `save` but skips the external-change check.
    pub fn saveForce(self: *App, path: []const u8) !void {
        const fmt = cio.detectFormat(path) orelse .can_json;
        switch (fmt) {
            .can_json => try cio.saveCanJson(self.gpa, self.io, &self.doc, path),
            .dbc => try cio.exportDbc(self.gpa, self.io, &self.doc, path),
        }
        try self.replaceStr(&self.path, path);
        if (fmt == .can_json) try self.replaceStr(&self.save_path, path);
        self.format = fmt;
        self.saved_rev = self.rev;
        self.stamp = stampOf(self.io, path);
    }

    pub fn exportDbc(self: *App, path: []const u8) !void {
        try cio.exportDbc(self.gpa, self.io, &self.doc, path);
    }

    pub fn exportDbcForBus(self: *App, bus_name: []const u8, path: []const u8) !void {
        try cio.exportDbcForBus(self.gpa, self.io, &self.doc, bus_name, path);
    }

    pub fn revalidate(self: *App) !void {
        self.validate_countdown = 0;
        try vd.validateAll(self.gpa, &self.doc, &self.diags);
    }

    pub fn revalidateDbcExport(self: *App, bus_name: []const u8) !void {
        self.validate_countdown = 0;
        try vd.validateDbcExport(self.gpa, &self.doc, &self.diags, bus_name);
    }

    /// Called on every UI tick; runs debounced validation.
    pub fn tick(self: *App) !void {
        if (self.validate_countdown == 0) return;
        self.validate_countdown -= 1;
        if (self.validate_countdown == 0) try self.revalidate();
    }

    // Edit transaction: beginEdit -> mutate -> endEdit (or cancelEdit when the mutation failed).
    pub fn beginEdit(self: *App) !void {
        const snap = try can_dbz.formats.can_json.write(self.gpa, &self.doc);
        errdefer self.gpa.free(snap);
        if (self.undo_stack.items.len >= max_undo) self.gpa.free(self.undo_stack.orderedRemove(0).bytes);
        try self.undo_stack.append(self.gpa, .{ .bytes = snap, .rev = self.rev });
    }

    /// Restores the document from the snapshot taken by `beginEdit` and drops it.
    pub fn abortEdit(self: *App) !void {
        const e = self.undo_stack.pop() orelse return;
        defer self.gpa.free(e.bytes);
        const restored = try can_dbz.formats.can_json.parse(self.gpa, e.bytes);
        self.doc.deinit();
        self.dropSource();
        self.doc = restored;
    }

    pub fn cancelEdit(self: *App) void {
        if (self.undo_stack.pop()) |e| self.gpa.free(e.bytes);
    }

    pub fn endEdit(self: *App) void {
        for (self.redo_stack.items) |e| self.gpa.free(e.bytes);
        self.redo_stack.clearRetainingCapacity();
        self.next_rev += 1;
        self.rev = self.next_rev;
        self.validate_countdown = validate_delay_ticks;
    }

    pub fn undo(self: *App) !bool {
        return self.step(&self.undo_stack, &self.redo_stack);
    }

    pub fn redo(self: *App) !bool {
        return self.step(&self.redo_stack, &self.undo_stack);
    }

    fn step(self: *App, from: *std.ArrayListUnmanaged(Entry), to: *std.ArrayListUnmanaged(Entry)) !bool {
        if (from.items.len == 0) return false;
        const current = try can_dbz.formats.can_json.write(self.gpa, &self.doc);
        errdefer self.gpa.free(current);
        const target = from.items[from.items.len - 1];
        var restored = try can_dbz.formats.can_json.parse(self.gpa, target.bytes);
        errdefer restored.deinit();
        try to.append(self.gpa, .{ .bytes = current, .rev = self.rev });
        self.gpa.free(from.pop().?.bytes);
        self.doc.deinit();
        self.dropSource();
        self.doc = restored;
        self.rev = target.rev;
        try self.revalidate();
        return true;
    }

    /// Round-trips through CAN JSON to release arena memory left by edits.
    pub fn compact(self: *App) !void {
        const bytes = try can_dbz.formats.can_json.write(self.gpa, &self.doc);
        defer self.gpa.free(bytes);
        const fresh = try can_dbz.formats.can_json.parse(self.gpa, bytes);
        self.doc.deinit();
        self.dropSource();
        self.doc = fresh;
    }

    pub fn itemCount(self: *const App) usize {
        var n: usize = 0;
        for (self.doc.messages.items) |m| n += 1 + m.signals.items.len;
        return n;
    }

    fn posAt(self: *const App, flat: usize) Pos {
        var left = flat;
        for (self.doc.messages.items, 0..) |m, i| {
            if (left == 0) return .{ .msg = i };
            left -= 1;
            if (left < m.signals.items.len) return .{ .msg = i, .sig = left };
            left -= m.signals.items.len;
        }
        unreachable;
    }

    fn flatOf(self: *const App, pos: Pos) usize {
        var n: usize = 0;
        for (self.doc.messages.items[0..pos.msg]) |m| n += 1 + m.signals.items.len;
        return n + if (pos.sig) |s| s + 1 else 0;
    }

    /// Next/previous message or signal matching name or frame ID, wrapping around.
    pub fn search(self: *const App, query: []const u8, from: ?Pos, forward: bool) ?Pos {
        const total = self.itemCount();
        if (total == 0 or query.len == 0) return null;
        const start: usize = if (from) |p| self.flatOf(p) else if (forward) total - 1 else 0;
        var k: usize = 1;
        while (k <= total) : (k += 1) {
            const idx = if (forward) (start + k) % total else (start + total - (k % total)) % total;
            const pos = self.posAt(idx);
            if (self.matches(pos, query)) return pos;
        }
        return null;
    }

    fn matches(self: *const App, pos: Pos, query: []const u8) bool {
        const msg = self.doc.messages.items[pos.msg];
        if (pos.sig) |s| return std.ascii.findIgnoreCase(msg.signals.items[s].name, query) != null;
        if (std.ascii.findIgnoreCase(msg.name, query) != null) return true;
        if (std.ascii.findIgnoreCase(msg.id, query) != null) return true;
        const id = ops.parseId(msg.id) orelse return false;
        var buf: [16]u8 = undefined;
        const dec = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return false;
        return std.mem.indexOf(u8, dec, query) != null;
    }
};

test "search finds signals and wraps" {
    var app = try App.init(std.testing.allocator, undefined);
    defer app.deinit();
    const m = try ops.addMessage(&app.doc, "can0", "Engine");
    _ = try ops.addSignal(&app.doc, m, "Rpm");
    const p = app.search("rpm", null, true).?;
    try std.testing.expectEqual(@as(?usize, 0), p.sig);
    try std.testing.expectEqual(p, app.search("rpm", p, true).?);
    try std.testing.expect(app.search("zzz", null, true) == null);
}

test "undo and redo restore the document" {
    var app = try App.init(std.testing.allocator, undefined);
    defer app.deinit();
    try app.beginEdit();
    _ = try ops.addMessage(&app.doc, "can0", "A");
    app.endEdit();
    try std.testing.expect(try app.undo());
    try std.testing.expectEqual(@as(usize, 0), app.doc.messages.items.len);
    try std.testing.expect(try app.redo());
    try std.testing.expectEqual(@as(usize, 1), app.doc.messages.items.len);
}

test "undoing to the saved revision makes the document clean" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const path = ".zig-cache/app-test-clean.can.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try app.save(path);
    try std.testing.expect(!app.isDirty());
    try app.beginEdit();
    _ = try ops.addMessage(&app.doc, "can0", "A");
    app.endEdit();
    try std.testing.expect(app.isDirty());
    try std.testing.expect(try app.undo());
    try std.testing.expect(!app.isDirty());
    try std.testing.expect(try app.redo());
    try std.testing.expect(app.isDirty());
}

test "a new edit after undo does not reuse the saved revision" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.beginEdit();
    _ = try ops.addMessage(&app.doc, "can0", "A");
    app.endEdit();
    app.saved_rev = app.rev;
    try std.testing.expect(try app.undo());
    try app.beginEdit();
    _ = try ops.addMessage(&app.doc, "can0", "B");
    app.endEdit();
    try std.testing.expect(app.isDirty());
}

test "save refuses to overwrite a file changed outside the session" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const path = ".zig-cache/app-test-external.can.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try app.save(path);
    try cio.atomicWrite(std.testing.allocator, std.testing.io, path, "{\"changed\":true,\"padding\":\"xxxxxxxxxxxxxxxxxxxxxxxx\"}");
    try std.testing.expectError(error.ExternalChange, app.save(path));
    try app.saveForce(path);
    try app.save(path);
}
