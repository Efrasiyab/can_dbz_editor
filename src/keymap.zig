const std = @import("std");

/// Actions that can be bound to a key chord. Navigation keys (arrows, Enter, Esc, Tab) are fixed in the UI.
pub const Action = enum {
    quit,
    new_file,
    open,
    save,
    save_as,
    export_dbc,
    undo,
    redo,
    help,
    pane_next,
    pane_prev,
    focus_filter,
    toggle_diag,
    validate,
    tab_next,
    tab_prev,
    move_signal,
    payload_test,
    command,
    menu,
    add,
    delete,
    duplicate,
    form_apply,
    form_discard,
    // Reachable through commands only; no default chord.
    add_bus,
    add_node,
    compact,
    toggle_dbc_mode,
    // Emitted by fixed navigation keys.
    up,
    down,
    left,
    right,
    top,
    bottom,
    edit,
};

pub const Kind = enum { char, function, insert, delete };

/// One key press: a character, a function key number, or Insert/Delete, with modifiers.
pub const Chord = struct {
    kind: Kind,
    /// Character code for `.char`, 1..12 for `.function`, unused otherwise.
    n: u21 = 0,
    ctrl: bool = false,
    shift: bool = false,

    pub fn eql(a: Chord, b: Chord) bool {
        return a.kind == b.kind and a.n == b.n and a.ctrl == b.ctrl and a.shift == b.shift;
    }

    /// Writes text such as `Ctrl+O`, `Shift+F2` or `Insert` into `buf`.
    pub fn describe(self: Chord, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.ctrl) w.writeAll("Ctrl+") catch {};
        if (self.shift) w.writeAll("Shift+") catch {};
        switch (self.kind) {
            .char => {
                var tmp: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(std.ascii.toUpper(@intCast(@min(self.n, 127))), &tmp) catch 0;
                w.writeAll(tmp[0..len]) catch {};
            },
            .function => w.print("F{d}", .{self.n}) catch {},
            .insert => w.writeAll("Insert") catch {},
            .delete => w.writeAll("Delete") catch {},
        }
        return w.buffered();
    }

    /// Parses `ctrl+o`, `shift+f2`, `f5`, `insert`, `delete` or a single character.
    pub fn parse(text: []const u8) ?Chord {
        var c: Chord = .{ .kind = .char };
        var rest = std.mem.trim(u8, text, " \t");
        while (true) {
            if (std.ascii.startsWithIgnoreCase(rest, "ctrl+")) {
                c.ctrl = true;
                rest = rest[5..];
            } else if (std.ascii.startsWithIgnoreCase(rest, "shift+")) {
                c.shift = true;
                rest = rest[6..];
            } else break;
        }
        if (std.ascii.eqlIgnoreCase(rest, "insert")) return .{ .kind = .insert, .ctrl = c.ctrl, .shift = c.shift };
        if (std.ascii.eqlIgnoreCase(rest, "delete")) return .{ .kind = .delete, .ctrl = c.ctrl, .shift = c.shift };
        if (rest.len >= 2 and (rest[0] == 'f' or rest[0] == 'F')) {
            const n = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
            if (n < 1 or n > 12) return null;
            c.kind = .function;
            c.n = n;
            return c;
        }
        const view = std.unicode.Utf8View.init(rest) catch return null;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return null;
        if (it.nextCodepoint() != null) return null;
        c.n = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
        return c;
    }
};

pub const Binding = [2]?Chord;

fn ch(c: u8) Chord {
    return .{ .kind = .char, .n = c, .ctrl = true };
}

fn f(n: u8) Chord {
    return .{ .kind = .function, .n = n };
}

const none: Binding = .{ null, null };

const defaults = std.enums.directEnumArray(Action, Binding, 0, .{
    .quit = .{ ch('q'), null },
    .new_file = .{ ch('n'), null },
    .open = .{ ch('o'), null },
    .save = .{ ch('s'), null },
    .save_as = none,
    .export_dbc = .{ ch('e'), null },
    .undo = .{ ch('z'), null },
    .redo = .{ ch('y'), null },
    .help = .{ f(1), null },
    .pane_next = .{ f(2), null },
    .pane_prev = .{ .{ .kind = .function, .n = 2, .shift = true }, null },
    .focus_filter = .{ f(3), ch('f') },
    .toggle_diag = .{ f(4), null },
    .validate = .{ f(5), null },
    .tab_next = .{ f(6), null },
    .tab_prev = .{ .{ .kind = .function, .n = 6, .shift = true }, null },
    .move_signal = .{ f(7), null },
    .payload_test = none,
    .command = .{ f(9), ch('p') },
    .menu = .{ f(10), null },
    .add = .{ .{ .kind = .insert }, null },
    .delete = .{ .{ .kind = .delete }, null },
    .duplicate = .{ ch('d'), null },
    .form_apply = .{ f(11), null },
    .form_discard = .{ f(12), null },
    .add_bus = none,
    .add_node = none,
    .compact = none,
    .toggle_dbc_mode = none,
    .up = none,
    .down = none,
    .left = none,
    .right = none,
    .top = none,
    .bottom = none,
    .edit = none,
});

pub const Keymap = struct {
    bindings: [defaults.len]Binding = defaults,

    pub fn lookup(self: *const Keymap, chord: Chord) ?Action {
        for (self.bindings, 0..) |b, i| {
            for (b) |maybe| {
                if (maybe) |bound| {
                    if (bound.eql(chord)) return @fromBackingInt(@intCast(i));
                }
            }
        }
        return null;
    }

    /// First bound chord, for help and hints.
    pub fn primary(self: *const Keymap, action: Action) ?Chord {
        return self.bindings[@backingInt(action)][0];
    }

    /// Applies lines of `action = chord[, chord]`; `#` starts a comment, bad lines are skipped.
    /// Returns the number of lines that were ignored.
    pub fn applyConfig(self: *Keymap, text: []const u8) usize {
        var bad: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                bad += 1;
                continue;
            };
            const name = std.mem.trim(u8, line[0..eq], " \t");
            const action = std.meta.stringToEnum(Action, name) orelse {
                bad += 1;
                continue;
            };
            var binding: Binding = none;
            var n: usize = 0;
            var ok = true;
            var parts = std.mem.splitScalar(u8, line[eq + 1 ..], ',');
            while (parts.next()) |part| {
                if (n == binding.len) {
                    ok = false;
                    break;
                }
                binding[n] = Chord.parse(part) orelse {
                    ok = false;
                    break;
                };
                n += 1;
            }
            if (!ok or n == 0) {
                bad += 1;
                continue;
            }
            self.bindings[@backingInt(action)] = binding;
        }
        return bad;
    }
};

test "default chords resolve to actions" {
    const km: Keymap = .{};
    try std.testing.expectEqual(Action.save, km.lookup(.{ .kind = .char, .n = 's', .ctrl = true }).?);
    try std.testing.expectEqual(Action.pane_prev, km.lookup(.{ .kind = .function, .n = 2, .shift = true }).?);
    try std.testing.expectEqual(Action.command, km.lookup(.{ .kind = .char, .n = 'p', .ctrl = true }).?);
    try std.testing.expect(km.lookup(.{ .kind = .char, .n = 's' }) == null);
}

test "config rebinds actions and reports bad lines" {
    var km: Keymap = .{};
    const bad = km.applyConfig("quit = ctrl+w\n# comment\nbogus = f1\nhelp = f12, ctrl+h\nsave = nope+x\n");
    try std.testing.expectEqual(@as(usize, 2), bad);
    try std.testing.expectEqual(Action.quit, km.lookup(.{ .kind = .char, .n = 'w', .ctrl = true }).?);
    try std.testing.expect(km.lookup(.{ .kind = .char, .n = 'q', .ctrl = true }) == null);
    try std.testing.expectEqual(Action.help, km.lookup(.{ .kind = .char, .n = 'h', .ctrl = true }).?);
}

test "chords describe themselves" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+O", (Chord{ .kind = .char, .n = 'o', .ctrl = true }).describe(&buf));
    try std.testing.expectEqualStrings("Shift+F2", (Chord{ .kind = .function, .n = 2, .shift = true }).describe(&buf));
}
