//! Local payload decoding for one message. Pure data in, display strings out; no document mutation.
const std = @import("std");
const can_dbz = @import("can_dbz");
const ops = @import("../backend/ops.zig");

const model = can_dbz.model;

pub const Row = struct {
    name: []const u8,
    /// "active", "inactive" or "error".
    state: []const u8,
    raw: []const u8,
    physical: []const u8,
    unit: []const u8,
    choice: []const u8,
};

pub const Result = struct {
    expected: usize,
    have: usize,
    rows: []const Row = &.{},
    /// Why no rows are shown, if that is the case.
    note: ?[]const u8 = null,
};

/// Decodes `text` (hex bytes separated by spaces) against message `msg_index`. Strings are allocated from `a`.
pub fn decode(gpa: std.mem.Allocator, a: std.mem.Allocator, doc: *const model.Document, msg_index: usize, text: []const u8) !Result {
    const msg = &doc.messages.items[msg_index];
    const expected: usize = msg.length;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |tok| {
        if (tok.len % 2 != 0) return .{ .expected = expected, .have = bytes.items.len, .note = "each byte needs two hex digits" };
        var i: usize = 0;
        while (i < tok.len) : (i += 2) {
            const b = std.fmt.parseInt(u8, tok[i .. i + 2], 16) catch
                return .{ .expected = expected, .have = bytes.items.len, .note = "invalid hex digit" };
            try bytes.append(a, b);
        }
    }
    const have = bytes.items.len;
    if (have != expected) {
        return .{ .expected = expected, .have = have, .note = try std.fmt.allocPrint(a, "need exactly {d} bytes", .{expected}) };
    }

    var db = can_dbz.compile.compile(doc, gpa) catch |e| {
        const why = if (e == error.InvalidDocument) "document has validation errors" else @errorName(e);
        return .{ .expected = expected, .have = have, .note = try std.fmt.allocPrint(a, "decode unavailable: {s}", .{why}) };
    };
    defer db.deinit();
    const id = ops.parseId(msg.id) orelse return .{ .expected = expected, .have = have, .note = "decode unavailable: invalid frame ID" };
    const handle = db.findMessage(msg.bus, id, msg.extended) orelse
        return .{ .expected = expected, .have = have, .note = "decode unavailable: message not in compiled database" };

    const n = msg.signals.items.len;
    const values = try a.alloc(can_dbz.codec.RawValue, n);
    const active = try a.alloc(bool, n);
    const scratch = try a.alloc(u8, n);
    db.decodeRaw(handle, bytes.items, values, active, scratch) catch |e| {
        const why = if (e == error.UnknownMuxValue) "unknown multiplexer selector value" else @errorName(e);
        return .{ .expected = expected, .have = have, .note = try std.fmt.allocPrint(a, "decode failed: {s}", .{why}) };
    };

    const rows = try a.alloc(Row, n);
    for (msg.signals.items, 0..) |sig, i| {
        rows[i] = .{ .name = sig.name, .state = "inactive", .raw = "", .physical = "", .unit = sig.unit orelse "", .choice = "" };
        if (!active[i]) continue;
        rows[i].state = "active";
        rows[i].raw = try rawText(a, values[i]);
        if (db.decodeSignalPhysical(handle, i, bytes.items)) |phys| {
            rows[i].physical = try physicalText(a, phys);
        } else |e| {
            rows[i].state = "error";
            rows[i].physical = @errorName(e);
        }
        if (db.choiceLabel(handle, i, values[i]) catch null) |label| rows[i].choice = label;
    }
    return .{ .expected = expected, .have = have, .rows = rows };
}

fn rawText(a: std.mem.Allocator, v: can_dbz.codec.RawValue) ![]const u8 {
    return switch (v) {
        .unsigned => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .signed => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .float32 => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .float64 => |x| std.fmt.allocPrint(a, "{d}", .{x}),
    };
}

/// Approximate display value with trailing zeros removed.
fn physicalText(a: std.mem.Allocator, v: f64) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{d:.6}", .{v});
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

const battery_json =
    \\{"format":"can-db","format_version":1,"buses":[{"name":"can0"}],"messages":[{"name":"BatteryStatus","bus":"can0","id":"0x180",
    \\"extended":false,"frame":"classic","length":8,"signals":[
    \\{"name":"Voltage","start_bit":0,"bit_length":16,"byte_order":"little_endian","type":"unsigned","factor":"0.01","unit":"V"},
    \\{"name":"Current","start_bit":16,"bit_length":16,"byte_order":"little_endian","type":"signed","factor":"0.1","unit":"A"},
    \\{"name":"SOC","start_bit":32,"bit_length":8,"byte_order":"little_endian","type":"unsigned","factor":"1","unit":"%"},
    \\{"name":"Enabled","start_bit":40,"bit_length":1,"byte_order":"little_endian","type":"unsigned","factor":"1"}]}]}
;

test "BatteryStatus fixture decodes to the documented values" {
    var doc = try can_dbz.formats.can_json.parse(std.testing.allocator, battery_json);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try decode(std.testing.allocator, arena.allocator(), &doc, 0, "C0 12 9C FF 50 01 00 00");
    try std.testing.expect(r.note == null);
    try std.testing.expectEqual(@as(usize, 4), r.rows.len);
    try std.testing.expectEqualStrings("4800", r.rows[0].raw);
    try std.testing.expectEqualStrings("48", r.rows[0].physical);
    try std.testing.expectEqualStrings("-100", r.rows[1].raw);
    try std.testing.expectEqualStrings("-10", r.rows[1].physical);
    try std.testing.expectEqualStrings("80", r.rows[2].physical);
    try std.testing.expectEqualStrings("1", r.rows[3].raw);
}

test "payload length and syntax problems produce notes, not rows" {
    var doc = try can_dbz.formats.can_json.parse(std.testing.allocator, battery_json);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const short = try decode(std.testing.allocator, a, &doc, 0, "C0 12");
    try std.testing.expectEqual(@as(usize, 2), short.have);
    try std.testing.expect(short.note != null and short.rows.len == 0);
    const odd = try decode(std.testing.allocator, a, &doc, 0, "C0 1");
    try std.testing.expectEqualStrings("each byte needs two hex digits", odd.note.?);
    const bad = try decode(std.testing.allocator, a, &doc, 0, "ZZ");
    try std.testing.expectEqualStrings("invalid hex digit", bad.note.?);
}
