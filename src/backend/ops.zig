const std = @import("std");
const can_dbz = @import("can_dbz");

const model = can_dbz.model;

pub const Error = error{
    DuplicateName,
    EmptyName,
    InvalidId,
    InvalidNumber,
    InvalidValue,
    UnknownBus,
    OutOfMemory,
};

pub const MessageField = enum {
    name,
    id,
    extended,
    frame,
    length,
    description,
    transmitters,
    receivers,
};

pub const SignalField = enum {
    name,
    start_bit,
    bit_length,
    byte_order,
    signal_type,
    factor,
    offset,
    minimum,
    maximum,
    unit,
    description,
    receivers,
    is_multiplexer,
    choices,
    value_table,
    when,
};

pub const NodeField = enum { name, description };

pub fn addBus(doc: *model.Document, name_in: []const u8) Error!usize {
    const name = std.mem.trim(u8, name_in, " ");
    if (name.len == 0) return error.EmptyName;
    for (doc.buses.items) |b| {
        if (std.mem.eql(u8, b.name, name)) return error.DuplicateName;
    }
    const a = doc.allocator();
    try doc.buses.append(a, .{ .name = try a.dupe(u8, name) });
    return doc.buses.items.len - 1;
}

/// Appends a classic 8-byte message with the lowest free standard ID >= 0x100 on the bus.
pub fn addMessage(doc: *model.Document, bus: []const u8, name_in: []const u8) Error!usize {
    const name = std.mem.trim(u8, name_in, " ");
    if (name.len == 0) return error.EmptyName;
    if (findBus(doc, bus) == null) return error.UnknownBus;
    if (findMessage(doc, bus, name) != null) return error.DuplicateName;

    var id: u32 = 0x100;
    while (idInUse(doc, bus, id, false)) id += 1;

    const a = doc.allocator();
    try doc.messages.append(a, .{
        .name = try a.dupe(u8, name),
        .bus = try a.dupe(u8, bus),
        .id = try formatId(a, id),
        .extended = false,
        .frame = .classic,
        .length = 8,
    });
    return doc.messages.items.len - 1;
}

pub fn deleteMessage(doc: *model.Document, index: usize) void {
    _ = doc.messages.orderedRemove(index);
}

fn cloneSignal(a: std.mem.Allocator, s: model.Signal) std.mem.Allocator.Error!model.Signal {
    var c = s;
    c.receivers = try s.receivers.clone(a);
    c.choices = try s.choices.clone(a);
    c.attributes = try s.attributes.clone(a);
    var when: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    for (s.when.items) |cond| {
        var cc = cond;
        cc.ranges = try cond.ranges.clone(a);
        try when.append(a, cc);
    }
    c.when = when;
    return c;
}

fn copyName(a: std.mem.Allocator, base: []const u8, taken: anytype, ctx: anytype) std.mem.Allocator.Error![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = if (n == 1)
            try std.fmt.allocPrint(a, "{s}_copy", .{base})
        else
            try std.fmt.allocPrint(a, "{s}_copy{d}", .{ base, n });
        if (!taken(ctx, name)) return name;
    }
}

fn signalTaken(msg: *const model.Message, name: []const u8) bool {
    return findSignal(msg, name) != null;
}

/// Copies a signal under a new name, placed after the last little-endian signal so it does not overlap.
pub fn duplicateSignal(doc: *model.Document, msg_index: usize, sig_index: usize) Error!usize {
    const a = doc.allocator();
    const msg = &doc.messages.items[msg_index];
    var copy = try cloneSignal(a, msg.signals.items[sig_index]);
    copy.name = try copyName(a, copy.name, signalTaken, msg);
    var start: u16 = 0;
    for (msg.signals.items) |s| {
        if (s.byte_order == .little_endian) start = @max(start, s.start_bit + s.bit_length);
    }
    copy.start_bit = start;
    copy.byte_order = .little_endian;
    try msg.signals.append(a, copy);
    return msg.signals.items.len - 1;
}

const MsgTaken = struct { doc: *const model.Document, bus: []const u8 };

fn messageTaken(ctx: MsgTaken, name: []const u8) bool {
    return findMessage(ctx.doc, ctx.bus, name) != null;
}

/// Copies a message and its signals under a new name and the next free ID on its bus.
pub fn duplicateMessage(doc: *model.Document, index: usize) Error!usize {
    const a = doc.allocator();
    const src = doc.messages.items[index];
    var copy = src;
    copy.name = try copyName(a, src.name, messageTaken, MsgTaken{ .doc = doc, .bus = src.bus });
    copy.transmitters = try src.transmitters.clone(a);
    copy.receivers = try src.receivers.clone(a);
    copy.attributes = try src.attributes.clone(a);
    var sigs: std.ArrayListUnmanaged(model.Signal) = .empty;
    for (src.signals.items) |s| try sigs.append(a, try cloneSignal(a, s));
    copy.signals = sigs;
    var id: u32 = (parseId(src.id) orelse 0x100) + 1;
    while (idInUse(doc, src.bus, id, src.extended)) id += 1;
    copy.id = try formatId(a, id);
    try doc.messages.append(a, copy);
    return doc.messages.items.len - 1;
}

pub fn addSignal(doc: *model.Document, msg_index: usize, name_in: []const u8) Error!usize {
    const name = std.mem.trim(u8, name_in, " ");
    if (name.len == 0) return error.EmptyName;
    const msg = &doc.messages.items[msg_index];
    if (findSignal(msg, name) != null) return error.DuplicateName;

    // Place after the last signal's end so the new signal does not overlap by default.
    var start: u16 = 0;
    for (msg.signals.items) |s| {
        if (s.byte_order == .little_endian) start = @max(start, s.start_bit + s.bit_length);
    }
    const a = doc.allocator();
    try msg.signals.append(a, .{
        .name = try a.dupe(u8, name),
        .start_bit = start,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .minimum = "0",
        .maximum = "255",
    });
    return msg.signals.items.len - 1;
}

pub fn deleteSignal(doc: *model.Document, msg_index: usize, sig_index: usize) void {
    _ = doc.messages.items[msg_index].signals.orderedRemove(sig_index);
}

pub fn setMessageField(doc: *model.Document, index: usize, field: MessageField, text_in: []const u8) Error!void {
    const text = std.mem.trim(u8, text_in, " ");
    const a = doc.allocator();
    const msg = &doc.messages.items[index];
    switch (field) {
        .name => {
            if (text.len == 0) return error.EmptyName;
            if (!std.mem.eql(u8, text, msg.name)) {
                if (findMessage(doc, msg.bus, text) != null) return error.DuplicateName;
            }
            msg.name = try a.dupe(u8, text);
        },
        .id => {
            const id = parseId(text) orelse return error.InvalidId;
            msg.id = try formatId(a, id);
        },
        .extended => msg.extended = try parseBool(text),
        .frame => msg.frame = std.meta.stringToEnum(model.FrameKind, text) orelse return error.InvalidValue,
        .length => msg.length = std.fmt.parseInt(u16, text, 10) catch return error.InvalidNumber,
        .description => msg.description = try optString(a, text),
        .transmitters => try setNodeList(doc, &msg.transmitters, text),
        .receivers => try setNodeList(doc, &msg.receivers, text),
    }
}

pub fn setSignalField(doc: *model.Document, msg_index: usize, sig_index: usize, field: SignalField, text_in: []const u8) Error!void {
    const text = std.mem.trim(u8, text_in, " ");
    const a = doc.allocator();
    const msg = &doc.messages.items[msg_index];
    const sig = &msg.signals.items[sig_index];
    switch (field) {
        .name => {
            if (text.len == 0) return error.EmptyName;
            if (!std.mem.eql(u8, text, sig.name)) {
                if (findSignal(msg, text) != null) return error.DuplicateName;
            }
            const old = sig.name;
            const new = try a.dupe(u8, text);
            for (msg.signals.items) |*other| {
                for (other.when.items) |*cond| {
                    if (std.mem.eql(u8, cond.selector, old)) cond.selector = new;
                }
            }
            sig.name = new;
        },
        .start_bit => sig.start_bit = std.fmt.parseInt(u16, text, 10) catch return error.InvalidNumber,
        .bit_length => sig.bit_length = std.fmt.parseInt(u16, text, 10) catch return error.InvalidNumber,
        .byte_order => sig.byte_order = std.meta.stringToEnum(model.ByteOrder, text) orelse return error.InvalidValue,
        .signal_type => sig.signal_type = std.meta.stringToEnum(model.SignalType, text) orelse return error.InvalidValue,
        .factor => sig.factor = try decimal(a, text),
        .offset => sig.offset = try decimal(a, text),
        .minimum => sig.minimum = if (text.len == 0) null else try decimal(a, text),
        .maximum => sig.maximum = if (text.len == 0) null else try decimal(a, text),
        .unit => sig.unit = try optString(a, text),
        .description => sig.description = try optString(a, text),
        .receivers => try setNodeList(doc, &sig.receivers, text),
        .is_multiplexer => sig.is_multiplexer = try parseBool(text),
        .choices => try setChoices(doc, &sig.choices, text),
        .value_table => {
            if (text.len == 0) {
                sig.value_table = null;
            } else {
                for (doc.value_tables.items) |vt| {
                    if (std.mem.eql(u8, vt.name, text)) {
                        sig.value_table = try a.dupe(u8, text);
                        return;
                    }
                }
                return error.InvalidValue;
            }
        },
        .when => try setMuxConditions(doc, &sig.when, text),
    }
}

/// Formats conditions as `Selector=1,2..4; Other=3`.
pub fn formatMuxConditions(a: std.mem.Allocator, conditions: []const model.MuxCondition) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (conditions, 0..) |condition, ci| {
        if (ci > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, condition.selector);
        try out.append(a, '=');
        for (condition.ranges.items, 0..) |range, ri| {
            if (ri > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, range.minimum);
            if (!std.mem.eql(u8, range.minimum, range.maximum)) {
                try out.appendSlice(a, "..");
                try out.appendSlice(a, range.maximum);
            }
        }
    }
    return out.toOwnedSlice(a);
}

fn setMuxConditions(doc: *model.Document, list: *std.ArrayListUnmanaged(model.MuxCondition), text: []const u8) Error!void {
    const a = doc.allocator();
    var parsed: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    if (text.len == 0) {
        list.* = .empty;
        return;
    }
    var clauses = std.mem.splitScalar(u8, text, ';');
    while (clauses.next()) |raw_clause| {
        const clause = std.mem.trim(u8, raw_clause, " \t");
        if (clause.len == 0) return error.InvalidValue;
        const eq = std.mem.indexOfScalar(u8, clause, '=') orelse return error.InvalidValue;
        const selector = std.mem.trim(u8, clause[0..eq], " \t");
        const range_text = std.mem.trim(u8, clause[eq + 1 ..], " \t");
        if (selector.len == 0 or range_text.len == 0) return error.InvalidValue;
        for (parsed.items) |existing| {
            if (std.mem.eql(u8, existing.selector, selector)) return error.InvalidValue;
        }

        var condition: model.MuxCondition = .{ .selector = try a.dupe(u8, selector) };
        var ranges = std.mem.splitScalar(u8, range_text, ',');
        while (ranges.next()) |raw_range| {
            const range = std.mem.trim(u8, raw_range, " \t");
            if (range.len == 0) return error.InvalidValue;
            const dots = std.mem.indexOf(u8, range, "..");
            const low_text = std.mem.trim(u8, if (dots) |i| range[0..i] else range, " \t");
            const high_text = if (dots) |i| std.mem.trim(u8, range[i + 2 ..], " \t") else low_text;
            const low = std.fmt.parseInt(i128, low_text, 10) catch return error.InvalidNumber;
            const high = std.fmt.parseInt(i128, high_text, 10) catch return error.InvalidNumber;
            if (low > high) return error.InvalidValue;
            try condition.ranges.append(a, .{
                .minimum = try a.dupe(u8, low_text),
                .maximum = try a.dupe(u8, high_text),
            });
        }
        if (condition.ranges.items.len == 0) return error.InvalidValue;
        try parsed.append(a, condition);
    }
    list.* = parsed;
}

/// Formats choices as `raw=label, raw=label`.
pub fn formatChoices(a: std.mem.Allocator, choices: []const model.Choice) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (choices, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, c.raw);
        try out.append(a, '=');
        try out.appendSlice(a, c.label);
    }
    return out.items;
}

fn setChoices(doc: *model.Document, list: *std.ArrayListUnmanaged(model.Choice), text: []const u8) Error!void {
    const a = doc.allocator();
    var parsed: std.ArrayListUnmanaged(model.Choice) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidValue;
        const raw = std.mem.trim(u8, part[0..eq], " ");
        const label = std.mem.trim(u8, part[eq + 1 ..], " ");
        if (label.len == 0) return error.InvalidValue;
        _ = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidNumber;
        for (parsed.items) |c| {
            if (std.mem.eql(u8, c.raw, raw)) return error.InvalidValue;
        }
        try parsed.append(a, .{ .raw = try a.dupe(u8, raw), .label = try a.dupe(u8, label) });
    }
    list.* = parsed;
}

pub const TableField = enum { name, choices };

pub fn findTable(doc: *const model.Document, name: []const u8) ?usize {
    for (doc.value_tables.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) return i;
    }
    return null;
}

pub fn addValueTable(doc: *model.Document, name_in: []const u8) Error!usize {
    const name = std.mem.trim(u8, name_in, " ");
    if (name.len == 0) return error.EmptyName;
    if (findTable(doc, name) != null) return error.DuplicateName;
    const a = doc.allocator();
    try doc.value_tables.append(a, .{ .name = try a.dupe(u8, name) });
    return doc.value_tables.items.len - 1;
}

/// Removes the table and clears signal references to it.
pub fn deleteValueTable(doc: *model.Document, index: usize) void {
    const name = doc.value_tables.items[index].name;
    _ = doc.value_tables.orderedRemove(index);
    for (doc.messages.items) |*m| {
        for (m.signals.items) |*s| {
            if (s.value_table) |vt| {
                if (std.mem.eql(u8, vt, name)) s.value_table = null;
            }
        }
    }
}

pub fn setTableField(doc: *model.Document, index: usize, field: TableField, text_in: []const u8) Error!void {
    const text = std.mem.trim(u8, text_in, " ");
    const table = &doc.value_tables.items[index];
    switch (field) {
        .name => {
            if (text.len == 0) return error.EmptyName;
            if (!std.mem.eql(u8, text, table.name)) {
                if (findTable(doc, text) != null) return error.DuplicateName;
            }
            const old = table.name;
            const new = try doc.allocator().dupe(u8, text);
            table.name = new;
            for (doc.messages.items) |*m| {
                for (m.signals.items) |*s| {
                    if (s.value_table) |vt| {
                        if (std.mem.eql(u8, vt, old)) s.value_table = new;
                    }
                }
            }
        },
        .choices => try setChoices(doc, &table.choices, text),
    }
}

pub fn findNode(doc: *const model.Document, name: []const u8) ?usize {
    for (doc.nodes.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return i;
    }
    return null;
}

pub fn addNode(doc: *model.Document, name_in: []const u8) Error!usize {
    const name = std.mem.trim(u8, name_in, " ");
    if (name.len == 0) return error.EmptyName;
    if (findNode(doc, name) != null) return error.DuplicateName;
    const a = doc.allocator();
    try doc.nodes.append(a, .{ .name = try a.dupe(u8, name) });
    return doc.nodes.items.len - 1;
}

/// Removes the node and every transmitter/receiver reference to it.
pub fn deleteNode(doc: *model.Document, index: usize) void {
    const name = doc.nodes.items[index].name;
    _ = doc.nodes.orderedRemove(index);
    for (doc.messages.items) |*m| {
        removeName(&m.transmitters, name);
        removeName(&m.receivers, name);
        for (m.signals.items) |*s| removeName(&s.receivers, name);
    }
}

fn removeName(list: *std.ArrayListUnmanaged([]const u8), name: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], name)) _ = list.orderedRemove(i) else i += 1;
    }
}

fn renameIn(list: *std.ArrayListUnmanaged([]const u8), old: []const u8, new: []const u8) void {
    for (list.items) |*n| {
        if (std.mem.eql(u8, n.*, old)) n.* = new;
    }
}

pub fn setNodeField(doc: *model.Document, index: usize, field: NodeField, text_in: []const u8) Error!void {
    const text = std.mem.trim(u8, text_in, " ");
    const a = doc.allocator();
    const node = &doc.nodes.items[index];
    switch (field) {
        .name => {
            if (text.len == 0) return error.EmptyName;
            if (!std.mem.eql(u8, text, node.name)) {
                if (findNode(doc, text) != null) return error.DuplicateName;
            }
            const old = node.name;
            const new = try a.dupe(u8, text);
            node.name = new;
            for (doc.messages.items) |*m| {
                renameIn(&m.transmitters, old, new);
                renameIn(&m.receivers, old, new);
                for (m.signals.items) |*s| renameIn(&s.receivers, old, new);
            }
        },
        .description => node.description = try optString(a, text),
    }
}

pub fn findBus(doc: *const model.Document, name: []const u8) ?usize {
    for (doc.buses.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.name, name)) return i;
    }
    return null;
}

pub fn findMessage(doc: *const model.Document, bus: []const u8, name: []const u8) ?usize {
    for (doc.messages.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.bus, bus) and std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

pub fn findSignal(msg: *const model.Message, name: []const u8) ?usize {
    for (msg.signals.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return i;
    }
    return null;
}

pub fn parseId(text: []const u8) ?u32 {
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return std.fmt.parseInt(u32, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn idInUse(doc: *const model.Document, bus: []const u8, id: u32, extended: bool) bool {
    for (doc.messages.items) |m| {
        if (m.extended == extended and std.mem.eql(u8, m.bus, bus) and parseId(m.id) == id) return true;
    }
    return false;
}

fn formatId(a: std.mem.Allocator, id: u32) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "0x{X}", .{id});
}

fn parseBool(text: []const u8) Error!bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidValue;
}

fn optString(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (text.len == 0) null else try a.dupe(u8, text);
}

fn decimal(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    const v = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
    if (!std.math.isFinite(v)) return error.InvalidNumber;
    return try a.dupe(u8, text);
}

fn setNodeList(doc: *model.Document, list: *std.ArrayListUnmanaged([]const u8), text: []const u8) Error!void {
    const a = doc.allocator();
    list.clearRetainingCapacity();
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const owned = try a.dupe(u8, name);
        try ensureNode(doc, owned);
        try list.append(a, owned);
    }
}

fn ensureNode(doc: *model.Document, name: []const u8) std.mem.Allocator.Error!void {
    for (doc.nodes.items) |n| {
        if (std.mem.eql(u8, n.name, name)) return;
    }
    try doc.nodes.append(doc.allocator(), .{ .name = name });
}

test "add, edit and delete" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    _ = try addBus(&doc, "can0");
    const m = try addMessage(&doc, "can0", "Engine");
    try std.testing.expectEqualStrings("0x100", doc.messages.items[m].id);
    try setMessageField(&doc, m, .id, "0x200");
    const s = try addSignal(&doc, m, "Rpm");
    try setSignalField(&doc, m, s, .bit_length, "16");
    try std.testing.expectError(error.DuplicateName, addSignal(&doc, m, "Rpm"));
    try std.testing.expectError(error.InvalidNumber, setSignalField(&doc, m, s, .factor, "x"));
    try setMessageField(&doc, m, .transmitters, "ECU, GW");
    try std.testing.expectEqual(@as(usize, 2), doc.nodes.items.len);
    try setSignalField(&doc, m, s, .choices, "0=Off, 1=On");
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[m].signals.items[s].choices.items.len);
    try std.testing.expectError(error.InvalidValue, setSignalField(&doc, m, s, .choices, "0=A, 0=B"));
    try setNodeField(&doc, 0, .name, "ECU2");
    try std.testing.expectEqualStrings("ECU2", doc.messages.items[m].transmitters.items[0]);
    deleteNode(&doc, 0);
    try std.testing.expectEqual(@as(usize, 1), doc.messages.items[m].transmitters.items.len);
    deleteSignal(&doc, m, s);
    deleteMessage(&doc, m);
    try std.testing.expectEqual(@as(usize, 0), doc.messages.items.len);
}

test "duplicating a signal and a message gives independent copies" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    _ = try addBus(&doc, "can0");
    const m = try addMessage(&doc, "can0", "Engine");
    const s = try addSignal(&doc, m, "Rpm");
    try setSignalField(&doc, m, s, .choices, "0=Off, 1=On");
    const d = try duplicateSignal(&doc, m, s);
    try std.testing.expectEqualStrings("Rpm_copy", doc.messages.items[m].signals.items[d].name);
    try std.testing.expectEqual(@as(u16, 8), doc.messages.items[m].signals.items[d].start_bit);
    try setSignalField(&doc, m, d, .choices, "5=Five");
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[m].signals.items[s].choices.items.len);

    const dm = try duplicateMessage(&doc, m);
    try std.testing.expectEqualStrings("Engine_copy", doc.messages.items[dm].name);
    try std.testing.expectEqualStrings("0x101", doc.messages.items[dm].id);
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[dm].signals.items.len);
}

test "multiplexer conditions round-trip conjunctions and inclusive range alternatives" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    _ = try addBus(&doc, "can0");
    const m = try addMessage(&doc, "can0", "MuxMessage");
    const selector = try addSignal(&doc, m, "Page");
    try setSignalField(&doc, m, selector, .is_multiplexer, "true");
    const other = try addSignal(&doc, m, "Mode");
    try setSignalField(&doc, m, other, .is_multiplexer, "true");
    const target = try addSignal(&doc, m, "Temperature");

    try setSignalField(&doc, m, target, .when, "Page=1, 2..4; Mode=3");
    const sig = &doc.messages.items[m].signals.items[target];
    try std.testing.expectEqual(@as(usize, 2), sig.when.items.len);
    try std.testing.expectEqualStrings("Page", sig.when.items[0].selector);
    try std.testing.expectEqual(@as(usize, 2), sig.when.items[0].ranges.items.len);
    try std.testing.expectEqualStrings("1", sig.when.items[0].ranges.items[0].minimum);
    try std.testing.expectEqualStrings("1", sig.when.items[0].ranges.items[0].maximum);
    try std.testing.expectEqualStrings("2", sig.when.items[0].ranges.items[1].minimum);
    try std.testing.expectEqualStrings("4", sig.when.items[0].ranges.items[1].maximum);
    const formatted = try formatMuxConditions(std.testing.allocator, sig.when.items);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("Page=1, 2..4; Mode=3", formatted);

    try std.testing.expectError(error.InvalidNumber, setSignalField(&doc, m, target, .when, "Page=1..x"));
    try std.testing.expectError(error.InvalidValue, setSignalField(&doc, m, target, .when, "Page=4..2"));
    try std.testing.expectError(error.InvalidValue, setSignalField(&doc, m, target, .when, "Page=1; Page=2"));
    try std.testing.expectError(error.InvalidValue, setSignalField(&doc, m, target, .when, "Page=1,"));
    try std.testing.expectError(error.InvalidValue, setSignalField(&doc, m, target, .when, "Page=1;"));
    try setSignalField(&doc, m, target, .when, "");
    try std.testing.expectEqual(@as(usize, 0), sig.when.items.len);
}
