//! Payload bit geometry using DBC sawtooth numbering. Independent of the UI toolkit.
const std = @import("std");
const can_dbz = @import("can_dbz");

const model = can_dbz.model;

/// Walks the absolute payload bit indices a signal occupies, most significant bit first for Motorola.
pub const BitIter = struct {
    order: model.ByteOrder,
    pos: u32,
    remaining: u32,

    pub fn init(sig: *const model.Signal) BitIter {
        return .{ .order = sig.byte_order, .pos = sig.start_bit, .remaining = sig.bit_length };
    }

    pub fn next(self: *BitIter) ?u32 {
        if (self.remaining == 0) return null;
        const cur = self.pos;
        self.remaining -= 1;
        self.pos = switch (self.order) {
            .little_endian => cur + 1,
            .big_endian => if (cur % 8 == 0) cur + 15 else cur - 1,
        };
        return cur;
    }
};

pub const no_owner: u16 = std.math.maxInt(u16);

pub const Cell = struct {
    owner: u16 = no_owner,
    collision: bool = false,
};

pub const MuxFilter = struct {
    selector: []const u8,
    value: i128,
};

pub const Occupancy = struct {
    cells: []Cell,
    /// Signals with bits beyond the payload, as indices into the message's signal list.
    out_of_bounds: std.ArrayListUnmanaged(u16) = .empty,

    pub fn deinit(self: *Occupancy, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        self.out_of_bounds.deinit(gpa);
    }
};

/// True when the two signals can never be active in the same frame because a shared selector's ranges are disjoint.
pub fn exclusive(a: *const model.Signal, b: *const model.Signal) bool {
    for (a.when.items) |ca| {
        for (b.when.items) |cb| {
            if (std.mem.eql(u8, ca.selector, cb.selector) and !rangesOverlap(ca.ranges.items, cb.ranges.items)) return true;
        }
    }
    return false;
}

/// Unparseable or empty ranges count as overlapping, so doubtful cases are reported rather than hidden.
fn rangesOverlap(x: []const model.RawRange, y: []const model.RawRange) bool {
    if (x.len == 0 or y.len == 0) return true;
    for (x) |rx| {
        for (y) |ry| {
            const xlo = std.fmt.parseInt(i128, rx.minimum, 10) catch return true;
            const xhi = std.fmt.parseInt(i128, rx.maximum, 10) catch return true;
            const ylo = std.fmt.parseInt(i128, ry.minimum, 10) catch return true;
            const yhi = std.fmt.parseInt(i128, ry.maximum, 10) catch return true;
            if (xlo <= yhi and ylo <= xhi) return true;
        }
    }
    return false;
}

/// One cell per payload bit. A collision is two signals on one bit that can be active together.
pub fn occupancy(gpa: std.mem.Allocator, msg: *const model.Message) !Occupancy {
    return occupancyForMuxValues(gpa, msg, &.{});
}

pub fn occupancyForMuxValue(gpa: std.mem.Allocator, msg: *const model.Message, selector: []const u8, value: i128) !Occupancy {
    const filter: MuxFilter = .{ .selector = selector, .value = value };
    return occupancyForMuxValues(gpa, msg, &.{filter});
}

pub fn occupancyForMuxValues(gpa: std.mem.Allocator, msg: *const model.Message, filters: []const MuxFilter) !Occupancy {
    const cells = try gpa.alloc(Cell, @as(usize, msg.length) * 8);
    @memset(cells, .{});
    var occ: Occupancy = .{ .cells = cells };
    errdefer occ.deinit(gpa);
    for (msg.signals.items, 0..) |*sig, si| {
        if (!matchesMuxValues(sig, filters)) continue;
        var it = BitIter.init(sig);
        var outside = false;
        while (it.next()) |bit| {
            if (bit >= cells.len) {
                outside = true;
                continue;
            }
            const cell = &cells[bit];
            if (cell.owner == no_owner) {
                cell.owner = @intCast(si);
            } else {
                const other = &msg.signals.items[cell.owner];
                if (!exclusive(sig, other)) cell.collision = true;
            }
        }
        if (outside) try occ.out_of_bounds.append(gpa, @intCast(si));
    }
    return occ;
}

/// Keeps common signals and signals whose condition on `selector` contains `value`.
/// Malformed or empty ranges remain visible so uncertain data is never hidden.
pub fn matchesMuxValue(sig: *const model.Signal, selector: []const u8, value: i128) bool {
    const filter: MuxFilter = .{ .selector = selector, .value = value };
    return matchesMuxValues(sig, &.{filter});
}

pub fn matchesMuxValues(sig: *const model.Signal, filters: []const MuxFilter) bool {
    for (sig.when.items) |condition| {
        var selected_value: ?i128 = null;
        for (filters) |filter| {
            if (std.mem.eql(u8, condition.selector, filter.selector)) {
                selected_value = filter.value;
                break;
            }
        }
        const value = selected_value orelse continue;
        if (condition.ranges.items.len == 0) continue;
        var matches = false;
        var uncertain = false;
        for (condition.ranges.items) |range| {
            const minimum = std.fmt.parseInt(i128, range.minimum, 10) catch {
                uncertain = true;
                break;
            };
            const maximum = std.fmt.parseInt(i128, range.maximum, 10) catch {
                uncertain = true;
                break;
            };
            if (minimum > maximum) {
                uncertain = true;
                break;
            }
            if (minimum <= value and value <= maximum) matches = true;
        }
        if (uncertain) continue;
        if (!matches) return false;
    }
    return true;
}

/// Lowest and highest payload byte a signal touches, or null when the signal has no bits.
pub fn byteSpan(sig: *const model.Signal) ?struct { first: u32, last: u32 } {
    var it = BitIter.init(sig);
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var any = false;
    while (it.next()) |bit| {
        any = true;
        lo = @min(lo, bit / 8);
        hi = @max(hi, bit / 8);
    }
    return if (any) .{ .first = lo, .last = hi } else null;
}

/// Short stable marker for the n-th signal: A-Z, a-z, 0-9, then '*'.
pub fn marker(index: usize) u8 {
    const set = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    return if (index < set.len) set[index] else '*';
}

fn testSignal(order: model.ByteOrder, start: u16, len: u16) model.Signal {
    return .{ .name = "S", .start_bit = start, .bit_length = len, .byte_order = order, .signal_type = .unsigned };
}

fn collect(sig: *const model.Signal, out: []u32) []u32 {
    var it = BitIter.init(sig);
    var n: usize = 0;
    while (it.next()) |b| : (n += 1) out[n] = b;
    return out[0..n];
}

test "Intel aligned signal" {
    const s = testSignal(.little_endian, 8, 16);
    var buf: [64]u32 = undefined;
    const bits = collect(&s, &buf);
    try std.testing.expectEqual(@as(usize, 16), bits.len);
    try std.testing.expectEqual(@as(u32, 8), bits[0]);
    try std.testing.expectEqual(@as(u32, 23), bits[15]);
}

test "Motorola start 3 width 12 crosses into the next byte" {
    const s = testSignal(.big_endian, 3, 12);
    var buf: [64]u32 = undefined;
    const expected = [_]u32{ 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8 };
    try std.testing.expectEqualSlices(u32, &expected, collect(&s, &buf));
}

test "Motorola start 7 width 16 covers two bytes" {
    const s = testSignal(.big_endian, 7, 16);
    var buf: [64]u32 = undefined;
    const bits = collect(&s, &buf);
    try std.testing.expectEqual(@as(u32, 7), bits[0]);
    try std.testing.expectEqual(@as(u32, 0), bits[7]);
    try std.testing.expectEqual(@as(u32, 15), bits[8]);
    try std.testing.expectEqual(@as(u32, 8), bits[15]);
}

test "Intel 64-bit signal at start 1 spans nine bytes" {
    const s = testSignal(.little_endian, 1, 64);
    const span = byteSpan(&s).?;
    try std.testing.expectEqual(@as(u32, 0), span.first);
    try std.testing.expectEqual(@as(u32, 8), span.last);
}

test "occupancy marks owners, collisions and out-of-bounds signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: model.Message = .{ .name = "M", .bus = "can0", .id = "0x1", .extended = false, .frame = .classic, .length = 2 };
    try msg.signals.append(a, testSignal(.little_endian, 0, 8));
    try msg.signals.append(a, testSignal(.little_endian, 4, 8));
    try msg.signals.append(a, testSignal(.little_endian, 12, 8));
    var occ = try occupancy(std.testing.allocator, &msg);
    defer occ.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), occ.cells[0].owner);
    try std.testing.expect(occ.cells[4].collision);
    try std.testing.expectEqual(@as(u16, 1), occ.cells[8].owner);
    try std.testing.expectEqual(@as(u16, 2), occ.cells[15].owner);
    try std.testing.expectEqual(@as(usize, 1), occ.out_of_bounds.items.len);
    try std.testing.expectEqual(@as(u16, 2), occ.out_of_bounds.items[0]);
}

fn muxSignal(a: std.mem.Allocator, selector: []const u8, lo: []const u8, hi: []const u8) !model.Signal {
    var s = testSignal(.little_endian, 8, 16);
    var cond: model.MuxCondition = .{ .selector = selector };
    try cond.ranges.append(a, .{ .minimum = lo, .maximum = hi });
    try s.when.append(a, cond);
    return s;
}

test "mutually exclusive mux branches do not collide, overlapping ones do" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: model.Message = .{ .name = "M", .bus = "can0", .id = "0x1", .extended = false, .frame = .classic, .length = 4 };
    try msg.signals.append(a, testSignal(.little_endian, 0, 8));
    try msg.signals.append(a, try muxSignal(a, "Page", "1", "1"));
    try msg.signals.append(a, try muxSignal(a, "Page", "2", "2"));
    var occ = try occupancy(std.testing.allocator, &msg);
    try std.testing.expect(!occ.cells[8].collision);
    occ.deinit(std.testing.allocator);

    try msg.signals.append(a, try muxSignal(a, "Page", "1", "3"));
    occ = try occupancy(std.testing.allocator, &msg);
    defer occ.deinit(std.testing.allocator);
    try std.testing.expect(occ.cells[8].collision);
}

test "mux value occupancy hides other branches and rebuilds shared bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: model.Message = .{ .name = "M", .bus = "can0", .id = "0x1", .extended = false, .frame = .classic, .length = 4 };
    var selector = testSignal(.little_endian, 0, 8);
    selector.name = "Page";
    selector.is_multiplexer = true;
    try msg.signals.append(a, selector);
    var page_one = testSignal(.little_endian, 8, 8);
    page_one.name = "A";
    try page_one.when.append(a, .{ .selector = "Page", .ranges = try rangeList(a, "1", "1") });
    try msg.signals.append(a, page_one);
    var page_two = testSignal(.little_endian, 8, 8);
    page_two.name = "B";
    try page_two.when.append(a, .{ .selector = "Page", .ranges = try rangeList(a, "2", "2") });
    try msg.signals.append(a, page_two);
    try msg.signals.append(a, testSignal(.little_endian, 16, 8));

    var occ = try occupancyForMuxValue(std.testing.allocator, &msg, "Page", 1);
    defer occ.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), occ.cells[8].owner);
    try std.testing.expect(!occ.cells[8].collision);
    try std.testing.expectEqual(@as(u16, 3), occ.cells[16].owner);
    try std.testing.expect(matchesMuxValue(&msg.signals.items[1], "Page", 1));
    try std.testing.expect(!matchesMuxValue(&msg.signals.items[2], "Page", 1));
}

test "nested mux filters require every selected condition to match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: model.Message = .{ .name = "M", .bus = "can0", .id = "0x1", .extended = false, .frame = .classic, .length = 4 };
    var page = testSignal(.little_endian, 0, 8);
    page.name = "Page";
    page.is_multiplexer = true;
    try msg.signals.append(a, page);
    var mode = testSignal(.little_endian, 1, 2);
    mode.name = "Mode";
    mode.is_multiplexer = true;
    try mode.when.append(a, .{ .selector = "Page", .ranges = try rangeList(a, "1", "1") });
    try msg.signals.append(a, mode);
    inline for (.{
        .{ "Selected", "2", "1" },
        .{ "OtherMode", "3", "1" },
        .{ "OtherPage", "2", "2" },
    }) |definition| {
        var signal = testSignal(.little_endian, 8, 8);
        signal.name = definition[0];
        try signal.when.append(a, .{ .selector = "Page", .ranges = try rangeList(a, definition[2], definition[2]) });
        try signal.when.append(a, .{ .selector = "Mode", .ranges = try rangeList(a, definition[1], definition[1]) });
        try msg.signals.append(a, signal);
    }

    const filters = [_]MuxFilter{
        .{ .selector = "Page", .value = 1 },
        .{ .selector = "Mode", .value = 2 },
    };
    var occ = try occupancyForMuxValues(std.testing.allocator, &msg, &filters);
    defer occ.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 2), occ.cells[8].owner);
    try std.testing.expect(!occ.cells[8].collision);
    try std.testing.expect(matchesMuxValues(&msg.signals.items[2], &filters));
    try std.testing.expect(!matchesMuxValues(&msg.signals.items[3], &filters));
    try std.testing.expect(!matchesMuxValues(&msg.signals.items[4], &filters));
}

fn rangeList(a: std.mem.Allocator, minimum: []const u8, maximum: []const u8) !std.ArrayListUnmanaged(model.RawRange) {
    var ranges: std.ArrayListUnmanaged(model.RawRange) = .empty;
    try ranges.append(a, .{ .minimum = minimum, .maximum = maximum });
    return ranges;
}

test "a common signal overlapping a branch signal is a collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: model.Message = .{ .name = "M", .bus = "can0", .id = "0x1", .extended = false, .frame = .classic, .length = 4 };
    try msg.signals.append(a, testSignal(.little_endian, 8, 8));
    try msg.signals.append(a, try muxSignal(a, "Page", "1", "1"));
    var occ = try occupancy(std.testing.allocator, &msg);
    defer occ.deinit(std.testing.allocator);
    try std.testing.expect(occ.cells[8].collision);
}
