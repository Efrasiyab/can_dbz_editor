const std = @import("std");
const zz = @import("zigzag");
const can_dbz = @import("can_dbz");
const app_mod = @import("app.zig");
const ops = @import("backend/ops.zig");
const cio = @import("backend/io.zig");
const vd = @import("backend/validate.zig");
const keymap_mod = @import("keymap.zig");
const layout = @import("domain/layout.zig");
const payload = @import("domain/payload.zig");

const App = app_mod.App;
const Action = keymap_mod.Action;
const Alloc = std.mem.Allocator;

const RowKind = enum { category, bus, message, signal, node, table, attr, meta };
const Tab = enum { messages, nodes, tables, attributes, metadata };
const tab_titles = [_][]const u8{ "Messages", "Nodes", "Value tables", "Attributes", "Metadata" };
const meta_labels = [_][]const u8{ "document name", "description", "dbc version", "extensions" };
const Row = struct {
    kind: RowKind,
    bus: usize,
    msg: usize = 0,
    sig: usize = 0,
    node: usize = 0,
    table: usize = 0,
    /// Attribute definition or metadata entry index.
    idx: usize = 0,
    cat: Tab = .messages,

    fn same(a: Row, b: Row) bool {
        return a.kind == b.kind and a.msg == b.msg and a.sig == b.sig and (a.kind != .bus or a.bus == b.bus) and
            (a.kind != .node or a.node == b.node) and (a.kind != .table or a.table == b.table) and
            (a.kind != .attr and a.kind != .meta or a.idx == b.idx) and (a.kind != .category or a.cat == b.cat);
    }
};

const Focus = enum { tree, filter, map, table, payload, details, diags };
const WsTab = enum { layout, payload, mux };
const ws_titles = [_][]const u8{ "Layout", "Payload test", "Multiplexing" };
const Mode = enum { normal, input, confirm, help, review, place, menu, draft_prompt, palette, welcome };

const PalRun = union(enum) { action: Action, category: Tab, ws: WsTab };
const PalEntry = struct { label: []const u8, run: PalRun };
const welcome_items = [_][]const u8{ "Open a file", "New file", "Quit" };

const MenuEntry = struct { label: []const u8, action: Action };
const Menu = struct { title: []const u8, entries: []const MenuEntry };
const menus = [_]Menu{
    .{ .title = "File", .entries = &.{
        .{ .label = "New", .action = .new_file },
        .{ .label = "Open...", .action = .open },
        .{ .label = "Save", .action = .save },
        .{ .label = "Save as...", .action = .save_as },
        .{ .label = "Export DBC...", .action = .export_dbc },
        .{ .label = "Quit", .action = .quit },
    } },
    .{ .title = "Edit", .entries = &.{
        .{ .label = "Undo", .action = .undo },
        .{ .label = "Redo", .action = .redo },
        .{ .label = "New item", .action = .add },
        .{ .label = "Duplicate", .action = .duplicate },
        .{ .label = "Delete", .action = .delete },
        .{ .label = "Move or resize signal", .action = .move_signal },
        .{ .label = "Apply form edits", .action = .form_apply },
        .{ .label = "Discard form edits", .action = .form_discard },
    } },
    .{ .title = "View", .entries = &.{
        .{ .label = "Filter browser", .action = .focus_filter },
        .{ .label = "Next pane", .action = .pane_next },
        .{ .label = "Previous pane", .action = .pane_prev },
        .{ .label = "Next workspace tab", .action = .tab_next },
        .{ .label = "Previous workspace tab", .action = .tab_prev },
        .{ .label = "Problems drawer", .action = .toggle_diag },
    } },
    .{ .title = "Tools", .entries = &.{
        .{ .label = "Validate now", .action = .validate },
        .{ .label = "Payload test", .action = .payload_test },
        .{ .label = "Command line", .action = .command },
        .{ .label = "Compact document", .action = .compact },
        .{ .label = "Toggle DBC import mode", .action = .toggle_dbc_mode },
    } },
    .{ .title = "Help", .entries = &.{
        .{ .label = "Keys and commands", .action = .help },
    } },
};
const Purpose = enum { open, save_as, export_dbc, search, command, add_bus, add_message, add_signal, add_node, add_table, rename, edit_field, new_path, new_type };
const ConfirmKind = enum { quit, delete, open, create, overwrite, new };

const FieldTag = union(enum) { m: ops.MessageField, s: ops.SignalField, n: ops.NodeField, t: ops.TableField, ro };
const FieldKind = enum { text, cycle, readonly };
const Group = enum { definition, conversion, choices, multiplexing, metadata };
const group_titles = [_][]const u8{ "Definition", "Conversion", "Choices", "Multiplexing", "Metadata" };

fn enumNames(comptime E: type) [std.meta.fieldNames(E).len][]const u8 {
    var out: [std.meta.fieldNames(E).len][]const u8 = undefined;
    inline for (std.meta.fieldNames(E), 0..) |n, i| out[i] = n;
    return out;
}

const bool_opts = [_][]const u8{ "false", "true" };
const frame_opts = enumNames(can_dbz.model.FrameKind);
const order_opts = enumNames(can_dbz.model.ByteOrder);
const type_opts = enumNames(can_dbz.model.SignalType);

const Field = struct {
    label: []const u8,
    value: []const u8,
    tag: FieldTag = .ro,
    kind: FieldKind = .readonly,
    next: []const u8 = "",
    group: Group = .definition,
    /// Allowed values for cycle fields.
    options: []const []const u8 = &.{},
};

/// An uncommitted change to one inspector field, kept until Apply or Discard.
const Draft = struct { idx: usize, text: []u8, err: ?[]u8 };
const VField = struct { idx: usize, f: Field };

const SelStyle = enum { none, sel, dim };

const signal_fg = [_][]const u8{ "\x1b[1;91m", "\x1b[1;92m", "\x1b[1;93m", "\x1b[1;94m", "\x1b[1;95m", "\x1b[1;96m", "\x1b[1;31m", "\x1b[1;32m" };
const signal_selected_bg = [_][]const u8{ "\x1b[30;101;1m", "\x1b[30;102;1m", "\x1b[30;103;1m", "\x1b[97;44;1m", "\x1b[30;105;1m", "\x1b[30;106;1m", "\x1b[97;41;1m", "\x1b[97;42;1m" };

/// When set, selection is shown with text markers instead of colors or video attributes.
pub var plain = false;

pub const Model = struct {
    app: App,
    keymap: keymap_mod.Keymap = .{},

    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// The expanded browser category; exactly one is open at a time.
    tab: Tab = .messages,
    /// Selected workspace tab for the message under the cursor.
    ws_tab: WsTab = .layout,
    /// Browser filter text; see `matchesFilter`.
    filter_buf: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,
    /// 0 selects the message itself, n selects signal n-1 of the browser's message.
    sel_sig: usize = 0,
    /// Absolute payload bit under the map cursor.
    map_bit: u32 = 0,
    focus: Focus = .tree,
    field_cursor: usize = 0,
    diag_cursor: usize = 0,
    show_diag: bool = false,

    mode: Mode = .normal,
    input_buf: std.ArrayListUnmanaged(u8) = .empty,
    input_purpose: Purpose = .command,
    input_label: []const u8 = "",
    input_row: Row = .{ .kind = .bus, .bus = 0 },
    input_tag: FieldTag = .ro,
    /// Start bit for a signal created from the map; cleared after use.
    anchor_bit: ?u32 = null,
    /// Set while a rejected edit keeps its text open; the status line shows the reason.
    draft_retained: bool = false,
    review_scroll: usize = 0,
    menu_idx: usize = 0,
    menu_item: usize = 0,
    /// Inspector tab and uncommitted field edits for `form_row`.
    insp_group: Group = .definition,
    drafts: std.ArrayListUnmanaged(Draft) = .empty,
    form_row: ?Row = null,
    editing: bool = false,
    edit_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Key that was blocked by unsaved form edits; replayed after Apply or Discard.
    pending_key: ?zz.KeyEvent = null,
    /// Menu or palette action blocked by unapplied form edits; run after Apply or Discard.
    pending_action: ?Action = null,
    pending_mouse: ?zz.MouseEvent = null,
    /// Terminal size from the last event, needed to map mouse positions to widgets.
    term_w: u16 = 0,
    term_h: u16 = 0,
    palette_buf: std.ArrayListUnmanaged(u8) = .empty,
    palette_cursor: usize = 0,
    welcome_item: usize = 0,
    /// File queued by `doOpen`; loaded on the next tick so the Loading message can be drawn first.
    pending_open: ?[]u8 = null,
    /// Hex text for the payload test; kept between openings and never part of the document.
    payload_buf: std.ArrayListUnmanaged(u8) = .empty,
    payload_scroll: usize = 0,
    /// Candidate placement of the selected signal while in placement mode.
    place_start: u16 = 0,
    place_len: u16 = 1,

    confirm_kind: ConfirmKind = .quit,
    confirm_text: ?[]u8 = null,
    confirm_path: ?[]u8 = null,
    confirm_row: Row = .{ .kind = .bus, .bus = 0 },

    status: ?[]u8 = null,
    last_search: ?[]u8 = null,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, _: *zz.Context) !zz.Cmd(Msg) {
        try self.rebuildRows();
        self.selectFirstMessage();
        self.show_diag = self.app.diags.count(.@"error") > 0;
        return zz.Cmd(Msg).everyMs(100);
    }

    fn selectFirstMessage(self: *Model) void {
        for (self.rows.items, 0..) |row, i| {
            if (row.kind == .message) {
                self.cursor = i;
                self.sel_sig = 0;
                self.map_bit = 0;
                return;
            }
        }
    }

    pub fn deinit(self: *Model) void {
        self.rows.deinit(self.app.gpa);
        self.clearDrafts();
        self.drafts.deinit(self.app.gpa);
        self.edit_buf.deinit(self.app.gpa);
        self.palette_buf.deinit(self.app.gpa);
        if (self.pending_open) |p| self.app.gpa.free(p);
        self.filter_buf.deinit(self.app.gpa);
        self.input_buf.deinit(self.app.gpa);
        self.payload_buf.deinit(self.app.gpa);
        const gpa = self.app.gpa;
        if (self.confirm_text) |s| gpa.free(s);
        if (self.confirm_path) |s| gpa.free(s);
        if (self.status) |s| gpa.free(s);
        if (self.last_search) |s| gpa.free(s);
        self.app.deinit();
    }

    pub fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) !void {
        const new = try std.fmt.allocPrint(self.app.gpa, fmt, args);
        if (self.status) |old| self.app.gpa.free(old);
        self.status = new;
    }

    // ---- rows / selection -------------------------------------------------

    /// Every whitespace-separated token must match: `bus:NAME`, `frame:classic|fd`, or a name/ID fragment.
    fn matchesFilter(self: *const Model, m: can_dbz.model.Message) bool {
        var it = std.mem.tokenizeAny(u8, self.filter_buf.items, " \t");
        while (it.next()) |tok| {
            if (std.ascii.startsWithIgnoreCase(tok, "bus:")) {
                if (!std.ascii.eqlIgnoreCase(m.bus, tok[4..])) return false;
            } else if (std.ascii.startsWithIgnoreCase(tok, "frame:")) {
                if (!std.ascii.eqlIgnoreCase(@tagName(m.frame), tok[6..])) return false;
            } else {
                const frag = if (std.ascii.startsWithIgnoreCase(tok, "0x")) tok[2..] else tok;
                if (std.ascii.findIgnoreCase(m.name, tok) != null) continue;
                if (frag.len > 0 and std.ascii.findIgnoreCase(m.id[2..], frag) != null) continue;
                return false;
            }
        }
        return true;
    }

    fn nameMatches(self: *const Model, name: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, self.filter_buf.items, " \t");
        while (it.next()) |tok| {
            if (std.ascii.findIgnoreCase(name, tok) == null) return false;
        }
        return true;
    }

    fn categoryCount(self: *const Model, cat: Tab) usize {
        const doc = &self.app.doc;
        return switch (cat) {
            .messages => doc.messages.items.len,
            .nodes => doc.nodes.items.len,
            .tables => doc.value_tables.items.len,
            .attributes => doc.attribute_definitions.items.len,
            .metadata => meta_labels.len,
        };
    }

    fn rebuildRows(self: *Model) !void {
        const gpa = self.app.gpa;
        self.rows.clearRetainingCapacity();
        const doc = &self.app.doc;
        inline for (comptime std.meta.fieldNames(Tab)) |fname| {
            const cat: Tab = @field(Tab, fname);
            try self.rows.append(gpa, .{ .kind = .category, .bus = 0, .cat = cat });
            if (cat == self.tab) switch (cat) {
                .messages => for (doc.buses.items, 0..) |bus, bi| {
                    const first = self.rows.items.len;
                    try self.rows.append(gpa, .{ .kind = .bus, .bus = bi });
                    for (doc.messages.items, 0..) |m, mi| {
                        if (!std.mem.eql(u8, m.bus, bus.name) or !self.matchesFilter(m)) continue;
                        try self.rows.append(gpa, .{ .kind = .message, .bus = bi, .msg = mi });
                    }
                    if (self.rows.items.len == first + 1 and self.filter_buf.items.len > 0) _ = self.rows.pop();
                },
                .nodes => for (doc.nodes.items, 0..) |n, ni| {
                    if (self.nameMatches(n.name)) try self.rows.append(gpa, .{ .kind = .node, .bus = 0, .node = ni });
                },
                .tables => for (doc.value_tables.items, 0..) |t, ti| {
                    if (self.nameMatches(t.name)) try self.rows.append(gpa, .{ .kind = .table, .bus = 0, .table = ti });
                },
                .attributes => for (doc.attribute_definitions.items, 0..) |d, ai| {
                    if (self.nameMatches(d.name)) try self.rows.append(gpa, .{ .kind = .attr, .bus = 0, .idx = ai });
                },
                .metadata => for (meta_labels, 0..) |_, mi| try self.rows.append(gpa, .{ .kind = .meta, .bus = 0, .idx = mi }),
            };
        }
        if (self.rows.items.len == 0) self.cursor = 0 else self.cursor = @min(self.cursor, self.rows.items.len - 1);
        self.clampSel();
    }

    fn clampSel(self: *Model) void {
        const r = self.browserRow() orelse {
            self.sel_sig = 0;
            return;
        };
        if (r.kind != .message) {
            self.sel_sig = 0;
            return;
        }
        self.sel_sig = @min(self.sel_sig, self.app.doc.messages.items[r.msg].signals.items.len);
    }

    /// Selects a message-table entry (0 = message) and moves the map cursor to its start bit.
    fn selectSig(self: *Model, sel: usize) void {
        self.sel_sig = sel;
        self.clampSel();
        const r = self.browserRow() orelse return;
        if (r.kind == .message and self.sel_sig > 0) {
            self.map_bit = self.app.doc.messages.items[r.msg].signals.items[self.sel_sig - 1].start_bit;
        }
        self.field_cursor = 0;
    }

    fn switchTab(self: *Model, tab: Tab) !void {
        try self.expandCategory(tab);
        self.focus = .tree;
    }

    /// Opens `cat`, closes the others and leaves the cursor on its header.
    fn expandCategory(self: *Model, cat: Tab) !void {
        self.tab = cat;
        self.sel_sig = 0;
        self.map_bit = 0;
        self.field_cursor = 0;
        try self.rebuildRows();
        self.selectRow(.{ .kind = .category, .bus = 0, .cat = cat });
    }

    fn onFilterKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const gpa = self.app.gpa;
        switch (k.key) {
            .escape => {
                self.filter_buf.clearRetainingCapacity();
                self.focus = .tree;
            },
            .tab => self.stepFocus(if (k.modifiers.shift) -1 else 1),
            .enter, .down => self.focus = .tree,
            .backspace => {
                while (self.filter_buf.items.len > 0) {
                    const b = self.filter_buf.pop().?;
                    if (b & 0xC0 != 0x80) break;
                }
            },
            .space => try self.filter_buf.append(gpa, ' '),
            .paste => |s| for (s) |b| if (b >= 0x20) try self.filter_buf.append(gpa, b),
            .char => |c| {
                if (k.modifiers.ctrl) {
                    if (c == 'u') self.filter_buf.clearRetainingCapacity();
                    return .none;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return .none;
                try self.filter_buf.appendSlice(gpa, buf[0..n]);
            },
            else => return .none,
        }
        try self.rebuildRows();
        return .none;
    }

    fn browserRow(self: *const Model) ?Row {
        if (self.cursor >= self.rows.items.len) return null;
        return self.rows.items[self.cursor];
    }

    /// The row the inspector shows and edits act on: the selected signal when a workspace pane has focus.
    fn curRow(self: *const Model) ?Row {
        const r = self.browserRow() orelse return null;
        if (r.kind == .message and self.sel_sig > 0 and self.focus != .tree) {
            return .{ .kind = .signal, .bus = r.bus, .msg = r.msg, .sig = self.sel_sig - 1 };
        }
        return r;
    }

    fn selectRow(self: *Model, target: Row) void {
        for (self.rows.items, 0..) |r, i| {
            if (r.same(target)) {
                self.cursor = i;
                return;
            }
        }
    }

    fn selectPos(self: *Model, pos: app_mod.Pos) !void {
        const msg = self.app.doc.messages.items[pos.msg];
        const bus = ops.findBus(&self.app.doc, msg.bus) orelse return;
        self.tab = .messages;
        try self.rebuildRows();
        self.selectRow(.{ .kind = .message, .bus = bus, .msg = pos.msg });
        self.selectSig(if (pos.sig) |s| s + 1 else 0);
        self.focus = if (pos.sig != null) .table else .tree;
    }

    fn afterDocChange(self: *Model) !void {
        try self.rebuildRows();
        self.field_cursor = 0;
    }

    /// Frame identity plus signal name; survives undo/redo, which replace the whole document.
    const SelKey = struct {
        bus: []u8,
        id: u32,
        extended: bool,
        sig: ?[]u8,

        fn deinit(k: SelKey, gpa: Alloc) void {
            gpa.free(k.bus);
            if (k.sig) |s| gpa.free(s);
        }
    };

    fn captureKey(self: *const Model) !?SelKey {
        const r = self.browserRow() orelse return null;
        if (self.tab != .messages or r.kind != .message) return null;
        const m = self.app.doc.messages.items[r.msg];
        const id = ops.parseId(m.id) orelse return null;
        const gpa = self.app.gpa;
        const bus = try gpa.dupe(u8, m.bus);
        errdefer gpa.free(bus);
        const sig: ?[]u8 = if (self.sel_sig > 0) try gpa.dupe(u8, m.signals.items[self.sel_sig - 1].name) else null;
        return .{ .bus = bus, .id = id, .extended = m.extended, .sig = sig };
    }

    fn restoreKey(self: *Model, k: SelKey) void {
        const doc = &self.app.doc;
        for (doc.messages.items, 0..) |m, mi| {
            if (m.extended != k.extended or !std.mem.eql(u8, m.bus, k.bus)) continue;
            if (ops.parseId(m.id) != k.id) continue;
            const bi = ops.findBus(doc, m.bus) orelse return;
            self.selectRow(.{ .kind = .message, .bus = bi, .msg = mi });
            self.sel_sig = if (k.sig) |n| (if (ops.findSignal(&m, n)) |si| si + 1 else 0) else 0;
            self.clampSel();
            return;
        }
    }

    fn stepHistory(self: *Model, redo: bool) !void {
        self.clearDrafts();
        const key = try self.captureKey();
        defer if (key) |k| k.deinit(self.app.gpa);
        const moved = if (redo) try self.app.redo() else try self.app.undo();
        if (!moved) return self.setStatus("{s}", .{if (redo) "Nothing to redo" else "Nothing to undo"});
        try self.afterDocChange();
        if (key) |k| self.restoreKey(k);
        try self.setStatus("{s}", .{if (redo) "Redone" else "Undone"});
    }

    // ---- field model ------------------------------------------------------

    fn joined(a: Alloc, items: []const []const u8) ![]const u8 {
        return std.mem.join(a, ", ", items);
    }

    fn nextOf(comptime E: type, cur: E) []const u8 {
        const n = std.meta.fieldNames(E).len;
        return @tagName(@as(E, @fromBackingInt(@intCast((@as(usize, @backingInt(cur)) + 1) % n))));
    }

    fn boolNext(v: bool) []const u8 {
        return if (v) "false" else "true";
    }

    fn attrValueText(a: Alloc, v: can_dbz.model.AttributeValue) ![]const u8 {
        return switch (v) {
            .integer, .hex, .float, .string => |s| s,
            .enum_index => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        };
    }

    fn fieldsFor(self: *const Model, a: Alloc, row: Row) ![]Field {
        var list: std.ArrayListUnmanaged(Field) = .empty;
        const doc = &self.app.doc;
        switch (row.kind) {
            .category => {
                try list.append(a, .{ .label = "category", .value = tab_titles[@backingInt(row.cat)] });
                try list.append(a, .{ .label = "items", .value = try std.fmt.allocPrint(a, "{d}", .{self.categoryCount(row.cat)}) });
            },
            .attr => {
                const d = doc.attribute_definitions.items[row.idx];
                try list.append(a, .{ .label = "name", .value = d.name });
                try list.append(a, .{ .label = "scope", .value = @tagName(d.scope) });
                try list.append(a, .{ .label = "type", .value = @tagName(d.value_type) });
                try list.append(a, .{ .label = "minimum", .value = d.minimum orelse "" });
                try list.append(a, .{ .label = "maximum", .value = d.maximum orelse "" });
                try list.append(a, .{ .label = "default", .value = if (d.default) |v| try attrValueText(a, v) else "" });
            },
            .meta => {
                const value: []const u8 = switch (row.idx) {
                    0 => doc.name orelse "",
                    1 => doc.description orelse "",
                    2 => blk: {
                        const meta = doc.dbc orelse break :blk "";
                        if (meta != .object) break :blk "";
                        const v = meta.object.get("version") orelse break :blk "";
                        break :blk if (v == .string) v.string else "";
                    },
                    else => if (doc.extensions != null) "present" else "none",
                };
                try list.append(a, .{ .label = meta_labels[row.idx], .value = value });
            },
            .table => {
                const t = doc.value_tables.items[row.table];
                try list.append(a, .{ .label = "name", .value = t.name, .tag = .{ .t = .name }, .kind = .text });
                try list.append(a, .{ .label = "choices", .value = try ops.formatChoices(a, t.choices.items), .tag = .{ .t = .choices }, .kind = .text });
            },
            .node => {
                const n = doc.nodes.items[row.node];
                try list.append(a, .{ .label = "name", .value = n.name, .tag = .{ .n = .name }, .kind = .text });
                try list.append(a, .{ .label = "description", .value = n.description orelse "", .tag = .{ .n = .description }, .kind = .text });
            },
            .bus => {
                const b = doc.buses.items[row.bus];
                try list.append(a, .{ .label = "name", .value = b.name });
                try list.append(a, .{ .label = "nominal_bitrate", .value = try optNum(a, b.nominal_bitrate) });
                try list.append(a, .{ .label = "data_bitrate", .value = try optNum(a, b.data_bitrate) });
                try list.append(a, .{ .label = "protocol", .value = b.protocol orelse "" });
            },
            .message => {
                const m = doc.messages.items[row.msg];
                inline for (comptime std.meta.fieldNames(ops.MessageField), 0..) |fname, fi| {
                    const tag: ops.MessageField = @fromBackingInt(@intCast(fi));
                    var fld: Field = .{ .label = fname, .value = "", .tag = .{ .m = tag }, .kind = .text };
                    switch (tag) {
                        .name => fld.value = m.name,
                        .id => fld.value = m.id,
                        .extended => {
                            fld.value = boolNext(!m.extended);
                            fld.value = if (m.extended) "true" else "false";
                            fld.kind = .cycle;
                            fld.next = boolNext(m.extended);
                        },
                        .frame => {
                            fld.value = @tagName(m.frame);
                            fld.kind = .cycle;
                            fld.next = nextOf(can_dbz.model.FrameKind, m.frame);
                        },
                        .length => fld.value = try std.fmt.allocPrint(a, "{d}", .{m.length}),
                        .description => fld.value = m.description orelse "",
                        .transmitters => fld.value = try joined(a, m.transmitters.items),
                        .receivers => fld.value = try joined(a, m.receivers.items),
                    }
                    try list.append(a, fld);
                }
                try list.append(a, .{ .label = "signals", .value = try std.fmt.allocPrint(a, "{d}", .{m.signals.items.len}) });
            },
            .signal => {
                const s = doc.messages.items[row.msg].signals.items[row.sig];
                inline for (comptime std.meta.fieldNames(ops.SignalField), 0..) |fname, fi| {
                    const tag: ops.SignalField = @fromBackingInt(@intCast(fi));
                    var fld: Field = .{ .label = fname, .value = "", .tag = .{ .s = tag }, .kind = .text };
                    switch (tag) {
                        .name => fld.value = s.name,
                        .start_bit => fld.value = try std.fmt.allocPrint(a, "{d}", .{s.start_bit}),
                        .bit_length => fld.value = try std.fmt.allocPrint(a, "{d}", .{s.bit_length}),
                        .byte_order => {
                            fld.value = @tagName(s.byte_order);
                            fld.kind = .cycle;
                            fld.next = nextOf(can_dbz.model.ByteOrder, s.byte_order);
                        },
                        .signal_type => {
                            fld.value = @tagName(s.signal_type);
                            fld.kind = .cycle;
                            fld.next = nextOf(can_dbz.model.SignalType, s.signal_type);
                        },
                        .factor => fld.value = s.factor,
                        .offset => fld.value = s.offset,
                        .minimum => fld.value = s.minimum orelse "",
                        .maximum => fld.value = s.maximum orelse "",
                        .unit => fld.value = s.unit orelse "",
                        .description => fld.value = s.description orelse "",
                        .receivers => fld.value = try joined(a, s.receivers.items),
                        .is_multiplexer => {
                            fld.value = if (s.is_multiplexer) "true" else "false";
                            fld.kind = .cycle;
                            fld.next = boolNext(s.is_multiplexer);
                        },
                        .choices => fld.value = try ops.formatChoices(a, s.choices.items),
                        .value_table => fld.value = s.value_table orelse "",
                        .when => {
                            fld.label = "conditions";
                            fld.group = .multiplexing;
                            fld.value = try ops.formatMuxConditions(a, s.when.items);
                        },
                    }
                    try list.append(a, fld);
                }
            },
        }
        return list.items;
    }

    fn optNum(a: Alloc, v: ?u32) ![]const u8 {
        return if (v) |n| std.fmt.allocPrint(a, "{d}", .{n}) else "";
    }

    fn fieldCount(self: *const Model, row: Row) usize {
        _ = self;
        return switch (row.kind) {
            .bus => 4,
            .message => std.meta.fieldNames(ops.MessageField).len + 1,
            .signal => std.meta.fieldNames(ops.SignalField).len + 1,
            .node, .table, .category, .meta => 2,
            .attr => 6,
        };
    }

    // ---- inspector form ---------------------------------------------------

    fn groupOf(f: Field) Group {
        switch (f.tag) {
            .s => |t| return switch (t) {
                .signal_type, .factor, .offset, .minimum, .maximum, .unit => .conversion,
                .choices, .value_table => .choices,
                .when => .multiplexing,
                .is_multiplexer => .multiplexing,
                .receivers => .metadata,
                .description => .metadata,
                else => .definition,
            },
            .m => |t| return if (t == .description) .metadata else .definition,
            .n => |t| return if (t == .description) .metadata else .definition,
            .t => |t| return if (t == .choices) .choices else .definition,
            .ro => return if (std.mem.eql(u8, f.label, "mux conditions")) .multiplexing else .definition,
        }
    }

    fn formFields(self: *const Model, a: Alloc, row: Row) ![]Field {
        const fs = try self.fieldsFor(a, row);
        for (fs) |*f| {
            f.group = groupOf(f.*);
            f.options = switch (f.tag) {
                .m => |t| switch (t) {
                    .extended => &bool_opts,
                    .frame => &frame_opts,
                    else => &.{},
                },
                .s => |t| switch (t) {
                    .byte_order => &order_opts,
                    .signal_type => &type_opts,
                    .is_multiplexer => &bool_opts,
                    else => &.{},
                },
                else => &.{},
            };
        }
        return fs;
    }

    fn presentGroups(fs: []const Field) [5]bool {
        var present: [5]bool = @splat(false);
        present[0] = true;
        for (fs) |f| present[@backingInt(f.group)] = true;
        return present;
    }

    fn activeGroup(self: *const Model, fs: []const Field) Group {
        return if (presentGroups(fs)[@backingInt(self.insp_group)]) self.insp_group else .definition;
    }

    fn visibleFields(self: *const Model, a: Alloc, row: Row) ![]VField {
        const fs = try self.formFields(a, row);
        const grp = self.activeGroup(fs);
        var out: std.ArrayListUnmanaged(VField) = .empty;
        for (fs, 0..) |f, i| {
            if (f.group == grp) try out.append(a, .{ .idx = i, .f = f });
        }
        return out.items;
    }

    fn formMatches(self: *const Model, row: Row) bool {
        return if (self.form_row) |fr| fr.same(row) else false;
    }

    fn draftAt(self: *const Model, idx: usize) ?*const Draft {
        for (self.drafts.items) |*d| {
            if (d.idx == idx) return d;
        }
        return null;
    }

    fn removeDraft(self: *Model, idx: usize) void {
        var i: usize = 0;
        while (i < self.drafts.items.len) {
            if (self.drafts.items[i].idx == idx) {
                const d = self.drafts.orderedRemove(i);
                self.app.gpa.free(d.text);
                if (d.err) |e| self.app.gpa.free(e);
            } else i += 1;
        }
        if (self.drafts.items.len == 0) self.form_row = null;
    }

    fn clearDrafts(self: *Model) void {
        for (self.drafts.items) |d| {
            self.app.gpa.free(d.text);
            if (d.err) |e| self.app.gpa.free(e);
        }
        self.drafts.clearRetainingCapacity();
        self.form_row = null;
        self.editing = false;
    }

    fn applyOne(self: *Model, row: Row, tag: FieldTag, text: []const u8) ops.Error!void {
        return switch (tag) {
            .m => |f| ops.setMessageField(&self.app.doc, row.msg, f, text),
            .s => |f| ops.setSignalField(&self.app.doc, row.msg, row.sig, f, text),
            .n => |f| ops.setNodeField(&self.app.doc, row.node, f, text),
            .t => |f| ops.setTableField(&self.app.doc, row.table, f, text),
            .ro => {},
        };
    }

    /// Applies the edit to a scratch copy of the document and reports why it would be refused, if it would.
    fn trial(self: *Model, row: Row, tag: FieldTag, text: []const u8) !?[]u8 {
        if (tag == .ro) return null;
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const before = try self.check(arena.allocator());
        try self.app.beginEdit();
        var why: ?[]const u8 = null;
        if (self.applyOne(row, tag, text)) |_| {
            const after = try self.check(arena.allocator());
            if (after.errors > before.errors) why = after.last orelse "would make the document invalid";
        } else |e| why = errText(e);
        try self.app.abortEdit();
        return if (why) |m| try self.app.gpa.dupe(u8, m) else null;
    }

    /// Records `text` as the draft for field `idx`; a value equal to the current one removes the draft.
    fn setDraft(self: *Model, row: Row, idx: usize, f: Field, text: []const u8) !void {
        const gpa = self.app.gpa;
        if (self.form_row) |fr| {
            if (!fr.same(row)) self.clearDrafts();
        }
        self.removeDraft(idx);
        if (std.mem.eql(u8, text, f.value)) return;
        const owned = try gpa.dupe(u8, text);
        errdefer gpa.free(owned);
        const tag = f.tag;
        const err = try self.trial(row, tag, owned);
        errdefer if (err) |e| gpa.free(e);
        try self.drafts.append(gpa, .{ .idx = idx, .text = owned, .err = err });
        self.form_row = row;
    }

    /// Commits every draft as one undoable edit; refuses when any would add validation errors.
    fn applyDrafts(self: *Model) !bool {
        const row = self.form_row orelse return true;
        if (self.drafts.items.len == 0) return true;
        for (self.drafts.items) |d| {
            if (d.err != null) {
                try self.setStatus("Fix the marked fields before applying", .{});
                return false;
            }
        }
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const fs = try self.formFields(arena.allocator(), row);
        const before = try self.check(arena.allocator());
        try self.app.beginEdit();
        for (self.drafts.items) |d| {
            self.applyOne(row, fs[d.idx].tag, d.text) catch |e| {
                try self.app.abortEdit();
                try self.setStatus("Error: {s}", .{errText(e)});
                return false;
            };
        }
        const after = try self.check(arena.allocator());
        if (after.errors > before.errors) {
            try self.setStatus("Rejected: {s}", .{after.last orelse "document would become invalid"});
            try self.app.abortEdit();
            return false;
        }
        self.app.endEdit();
        const n = self.drafts.items.len;
        self.clearDrafts();
        try self.setStatus("Applied {d} field(s)", .{n});
        return true;
    }

    fn displayText(self: *const Model, row: Row, vf: VField) []const u8 {
        if (self.formMatches(row)) {
            if (self.draftAt(vf.idx)) |d| return d.text;
        }
        return vf.f.value;
    }

    fn shiftGroup(self: *Model, row: Row, dir: isize) !void {
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const fs = try self.formFields(arena.allocator(), row);
        const present = presentGroups(fs);
        var g: isize = @intCast(@backingInt(self.activeGroup(fs)));
        var tries: usize = 0;
        while (tries < present.len) : (tries += 1) {
            g = @mod(g + dir, @as(isize, present.len));
            if (present[@intCast(g)]) break;
        }
        self.insp_group = @fromBackingInt(@intCast(g));
        self.field_cursor = 0;
    }

    fn activateField(self: *Model, row: Row, vfs: []const VField) !void {
        const n = vfs.len;
        if (self.field_cursor == n) {
            _ = try self.applyDrafts();
            return;
        }
        if (self.field_cursor == n + 1) {
            self.clearDrafts();
            try self.setStatus("Draft discarded", .{});
            return;
        }
        if (self.field_cursor > n) return;
        const vf = vfs[self.field_cursor];
        switch (vf.f.kind) {
            .readonly => try self.setStatus("{s} is read-only", .{vf.f.label}),
            .cycle => {
                const cur = self.displayText(row, vf);
                var i: usize = 0;
                for (vf.f.options, 0..) |o, oi| {
                    if (std.mem.eql(u8, o, cur)) i = oi;
                }
                try self.setDraft(row, vf.idx, vf.f, vf.f.options[(i + 1) % vf.f.options.len]);
            },
            .text => {
                self.edit_buf.clearRetainingCapacity();
                try self.edit_buf.appendSlice(self.app.gpa, self.displayText(row, vf));
                self.editing = true;
            },
        }
    }

    /// Handles form navigation keys; returns false for keys the caller should treat normally.
    fn onFormKey(self: *Model, k: zz.KeyEvent) !bool {
        const row = self.curRow() orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const vfs = try self.visibleFields(arena.allocator(), row);
        const items = vfs.len + 2;
        switch (k.key) {
            .up => self.field_cursor = stepIndex(self.field_cursor, items, -1, null),
            .down => self.field_cursor = stepIndex(self.field_cursor, items, 1, null),
            .home => self.field_cursor = 0,
            .end => self.field_cursor = items - 1,
            .left => try self.shiftGroup(row, -1),
            .right => try self.shiftGroup(row, 1),
            .escape => self.focus = .tree,
            .enter => try self.activateField(row, vfs),
            .delete => if (self.field_cursor < vfs.len) {
                self.removeDraft(vfs[self.field_cursor].idx);
                try self.setStatus("Field reverted", .{});
            },
            else => return false,
        }
        return true;
    }

    fn onEditKey(self: *Model, k: zz.KeyEvent) !void {
        const gpa = self.app.gpa;
        switch (k.key) {
            .escape => self.editing = false,
            .enter => {
                const row = self.curRow() orelse {
                    self.editing = false;
                    return;
                };
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const vfs = try self.visibleFields(arena.allocator(), row);
                self.editing = false;
                if (self.field_cursor >= vfs.len) return;
                const vf = vfs[self.field_cursor];
                const text = try gpa.dupe(u8, std.mem.trim(u8, self.edit_buf.items, " \t"));
                defer gpa.free(text);
                try self.setDraft(row, vf.idx, vf.f, text);
            },
            .backspace => {
                while (self.edit_buf.items.len > 0) {
                    const b = self.edit_buf.pop().?;
                    if (b & 0xC0 != 0x80) break;
                }
            },
            .space => try self.edit_buf.append(gpa, ' '),
            .paste => |s| for (s) |b| if (b >= 0x20) try self.edit_buf.append(gpa, b),
            .char => |c| {
                if (k.modifiers.ctrl) {
                    if (c == 'u') self.edit_buf.clearRetainingCapacity();
                    return;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return;
                try self.edit_buf.appendSlice(gpa, buf[0..n]);
            },
            else => {},
        }
    }

    /// True when `k` would move the selection or replace the document while form edits are pending.
    fn wouldLeave(self: *const Model, k: zz.KeyEvent, action: ?Action) bool {
        if (action) |a| {
            if (actionLeaves(a)) return true;
        }
        const nav = switch (k.key) {
            .up, .down, .home, .end, .page_up, .page_down => true,
            else => false,
        };
        return switch (self.focus) {
            .tree => nav or (k.key == .enter and (if (self.browserRow()) |r| r.kind == .category else false)),
            .map => nav or k.key == .left or k.key == .right,
            .table => nav,
            .diags => k.key == .enter,
            else => false,
        };
    }

    // ---- edits ------------------------------------------------------------

    fn errText(err: anyerror) []const u8 {
        return switch (err) {
            error.DuplicateName => "name already exists",
            error.EmptyName => "name must not be empty",
            error.InvalidId => "invalid frame ID (use 0x.. hex or decimal)",
            error.InvalidNumber => "invalid number",
            error.InvalidValue => "invalid value",
            error.UnknownBus => "unknown bus",
            else => @errorName(err),
        };
    }

    const Check = struct { errors: usize, last: ?[]const u8 };

    fn check(self: *const Model, arena: Alloc) !Check {
        var diags: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
        _ = try can_dbz.validate.validateDocument(&self.app.doc, arena, &diags);
        var res: Check = .{ .errors = 0, .last = null };
        for (diags.items) |d| {
            if (d.severity != .@"error") continue;
            res.errors += 1;
            res.last = d.message;
        }
        return res;
    }

    /// Commits the edit only when it adds no validation errors; returns whether it was applied.
    fn applyTag(self: *Model, row: Row, tag: FieldTag, text: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const before = try self.check(arena.allocator());
        try self.app.beginEdit();
        const r: ops.Error!void = switch (tag) {
            .m => |f| ops.setMessageField(&self.app.doc, row.msg, f, text),
            .s => |f| ops.setSignalField(&self.app.doc, row.msg, row.sig, f, text),
            .n => |f| ops.setNodeField(&self.app.doc, row.node, f, text),
            .t => |f| ops.setTableField(&self.app.doc, row.table, f, text),
            .ro => {},
        };
        r catch |e| {
            try self.app.abortEdit();
            try self.setStatus("Error: {s}", .{errText(e)});
            return false;
        };
        const after = try self.check(arena.allocator());
        if (after.errors > before.errors) {
            const why = after.last orelse "document would become invalid";
            try self.setStatus("Rejected: {s}", .{why});
            try self.app.abortEdit();
            return false;
        }
        self.app.endEdit();
        try self.setStatus("Updated", .{});
        return true;
    }

    fn doAdd(self: *Model, purpose: Purpose, row: Row, name: []const u8) !void {
        defer self.anchor_bit = null;
        try self.app.beginEdit();
        const doc = &self.app.doc;
        var target: ?Row = null;
        const result: ops.Error!void = blk: {
            switch (purpose) {
                .add_bus => {
                    const bi = ops.addBus(doc, name) catch |e| break :blk e;
                    target = .{ .kind = .bus, .bus = bi };
                },
                .add_message => {
                    const bus = doc.buses.items[row.bus];
                    const mi = ops.addMessage(doc, bus.name, name) catch |e| break :blk e;
                    target = .{ .kind = .message, .bus = row.bus, .msg = mi };
                },
                .add_signal => {
                    const si = ops.addSignal(doc, row.msg, name) catch |e| break :blk e;
                    if (self.anchor_bit) |bit| {
                        var buf: [12]u8 = undefined;
                        const txt = std.fmt.bufPrint(&buf, "{d}", .{bit}) catch unreachable;
                        ops.setSignalField(doc, row.msg, si, .start_bit, txt) catch |e| break :blk e;
                    }
                    target = .{ .kind = .signal, .bus = row.bus, .msg = row.msg, .sig = si };
                },
                .add_node => {
                    const ni = ops.addNode(doc, name) catch |e| break :blk e;
                    target = .{ .kind = .node, .bus = 0, .node = ni };
                },
                .add_table => {
                    const ti = ops.addValueTable(doc, name) catch |e| break :blk e;
                    target = .{ .kind = .table, .bus = 0, .table = ti };
                },
                else => unreachable,
            }
        };
        result catch |e| {
            self.app.cancelEdit();
            try self.setStatus("Error: {s}", .{errText(e)});
            return;
        };
        self.app.endEdit();
        self.tab = switch (target.?.kind) {
            .node => .nodes,
            .table => .tables,
            else => .messages,
        };
        try self.rebuildRows();
        if (target.?.kind == .signal) {
            self.selectRow(.{ .kind = .message, .bus = target.?.bus, .msg = target.?.msg });
            self.focus = .table;
            self.selectSig(target.?.sig + 1);
        } else {
            self.selectRow(target.?);
            self.sel_sig = 0;
            self.focus = .tree;
        }
        try self.setStatus("Added {s}", .{name});
    }

    fn doDelete(self: *Model, row: Row) !void {
        try self.app.beginEdit();
        switch (row.kind) {
            .bus, .category, .attr, .meta => unreachable,
            .message => {
                ops.deleteMessage(&self.app.doc, row.msg);
                self.sel_sig = 0;
            },
            .signal => ops.deleteSignal(&self.app.doc, row.msg, row.sig),
            .node => ops.deleteNode(&self.app.doc, row.node),
            .table => ops.deleteValueTable(&self.app.doc, row.table),
        }
        self.app.endEdit();
        try self.rebuildRows();
        if (row.kind == .signal) self.selectSig(row.sig);
        try self.setStatus("Deleted", .{});
    }

    // ---- actions ----------------------------------------------------------

    fn startInput(self: *Model, purpose: Purpose, label: []const u8, prefill: []const u8) !void {
        self.draft_retained = false;
        self.input_buf.clearRetainingCapacity();
        try self.input_buf.appendSlice(self.app.gpa, prefill);
        self.input_purpose = purpose;
        self.input_label = label;
        self.mode = .input;
    }

    fn startConfirm(self: *Model, kind: ConfirmKind, text: []const u8, path: ?[]const u8, row: Row) !void {
        const gpa = self.app.gpa;
        const t = try gpa.dupe(u8, text);
        const p = if (path) |v| try gpa.dupe(u8, v) else null;
        if (self.confirm_text) |s| gpa.free(s);
        if (self.confirm_path) |s| gpa.free(s);
        self.confirm_text = t;
        self.confirm_path = p;
        self.confirm_kind = kind;
        self.confirm_row = row;
        self.mode = .confirm;
    }

    fn actionLeaves(a: Action) bool {
        return switch (a) {
            .open, .new_file, .undo, .redo, .add, .delete, .duplicate, .move_signal, .quit => true,
            else => false,
        };
    }

    /// Runs an action chosen from the menu or palette, asking first when form edits would be lost.
    fn runAction(self: *Model, action: Action) !zz.Cmd(Msg) {
        if (self.drafts.items.len > 0 and !self.editing and actionLeaves(action)) {
            self.pending_action = action;
            self.mode = .draft_prompt;
            return .none;
        }
        return self.do(action);
    }

    fn onDraftPromptKey(self: *Model, k: zz.KeyEvent) anyerror!zz.Cmd(Msg) {
        const replay = self.pending_key;
        const replay_action = self.pending_action;
        const replay_mouse = self.pending_mouse;
        switch (k.key) {
            .escape => {
                self.mode = .normal;
                self.pending_key = null;
                self.pending_action = null;
                self.pending_mouse = null;
                return .none;
            },
            .char => |c| switch (std.ascii.toLower(@intCast(@min(c, 127)))) {
                'a' => {
                    self.mode = .normal;
                    if (!try self.applyDrafts()) {
                        self.pending_key = null;
                        self.pending_action = null;
                        self.pending_mouse = null;
                        return .none;
                    }
                },
                'd' => {
                    self.mode = .normal;
                    self.clearDrafts();
                    try self.setStatus("Draft discarded", .{});
                },
                'c' => {
                    self.mode = .normal;
                    self.pending_key = null;
                    self.pending_action = null;
                    self.pending_mouse = null;
                    return .none;
                },
                else => return .none,
            },
            else => return .none,
        }
        self.pending_key = null;
        self.pending_action = null;
        self.pending_mouse = null;
        if (replay_action) |ac| return self.do(ac);
        if (replay_mouse) |pm| return self.onMouse(pm);
        if (replay) |pk| return self.onKey(pk);
        return .none;
    }

    // ---- mouse ------------------------------------------------------------

    const Hit = union(enum) {
        none,
        menu_title: usize,
        filter,
        browser_row: usize,
        ws_tab: WsTab,
        msg_header,
        map_cell: u32,
        table_row: usize,
        insp_field: usize,
        insp_tab: Group,
        insp_apply,
        insp_discard,
        drawer,
        /// Inside a pane but not on an item; focuses that pane.
        region: Focus,
    };

    fn drawerHeight(self: *const Model, H: usize) usize {
        return if (self.show_diag and self.mode != .help and self.mode != .review and self.mode != .welcome) @min(10, H / 3) else 0;
    }

    fn hitTest(self: *const Model, a: Alloc, x: usize, y: usize) !Hit {
        const W: usize = self.term_w;
        const H: usize = self.term_h;
        if (y == 1) {
            var cx: usize = 0;
            for (menus, 0..) |m, i| {
                const wd = m.title.len + 2;
                if (x >= cx and x < cx + wd) return .{ .menu_title = i };
                cx += wd;
            }
            return .none;
        }
        if (y < 2) return .none;
        const diag_h = self.drawerHeight(H);
        const main_h = H -| (5 + diag_h);
        if (y >= 2 + main_h) return if (y < 2 + main_h + diag_h) .drawer else .none;
        const ry = y - 2;
        const lay = self.paneLayout(W, H);
        for (lay.slots[0..lay.n]) |s| {
            if (x < s.x or x >= s.x + s.w) continue;
            const outer_x = x - s.x;
            if (outer_x == 0 or outer_x + 1 >= s.w or ry == 0 or ry + 1 >= main_h) {
                const region: Focus = switch (s.kind) {
                    .browser => .tree,
                    .workspace => switch (self.ws_tab) {
                        .layout => if (self.focus == .table) .table else .map,
                        .payload => .payload,
                        .mux => .table,
                    },
                    .inspector => .details,
                };
                return .{ .region = region };
            }
            const lx = outer_x - 1;
            const inner_y = ry - 1;
            const inner_w = s.w - 2;
            const inner_h = main_h - 2;
            return switch (s.kind) {
                .browser => try self.hitBrowser(a, inner_w, inner_y, inner_h),
                .workspace => self.hitWorkspace(lx, inner_y, inner_w, inner_h, lay.stacked and lay.n > 1),
                .inspector => try self.hitInspector(a, lx, inner_y, inner_w, inner_h),
            };
        }
        return .none;
    }

    fn compactMessages(self: *const Model, a: Alloc) ![]Row {
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (self.app.doc.messages.items, 0..) |m, mi| {
            if (!self.matchesFilter(m)) continue;
            const bi = ops.findBus(&self.app.doc, m.bus) orelse continue;
            try rows.append(a, .{ .kind = .message, .bus = bi, .msg = mi });
        }
        return rows.items;
    }

    fn hitBrowser(self: *const Model, a: Alloc, w: usize, ry: usize, h: usize) !Hit {
        if (w <= 16 and self.tab == .messages) {
            if (ry == 0) return .{ .region = .tree };
            const rows = try self.compactMessages(a);
            const selected = self.browserRow();
            var cursor: usize = 0;
            if (selected) |sel| {
                for (rows, 0..) |r, i| {
                    if (sel.kind == .message and r.msg == sel.msg) cursor = i;
                }
            }
            const list_h = h -| 1;
            const i = topFor(cursor, rows.len, list_h) + ry - 1;
            if (ry - 1 < list_h and i < rows.len) {
                for (self.rows.items, 0..) |r, ri| {
                    if (r.kind == .message and r.msg == rows[i].msg) return .{ .browser_row = ri };
                }
            }
            return .{ .region = .tree };
        }
        if (ry == 0) return .filter;
        const list_h = h -| 1;
        const i = topFor(self.cursor, self.rows.items.len, list_h) + ry - 1;
        if (ry - 1 < list_h and i < self.rows.items.len) return .{ .browser_row = i };
        return .{ .region = .tree };
    }

    fn hitWorkspace(self: *const Model, lx: usize, ry: usize, w: usize, h: usize, both: bool) Hit {
        const msg = self.curMsg() orelse return .none;
        if (ry == 0) {
            var cx: usize = 0;
            for (ws_titles, 0..) |t, i| {
                const wd = t.len + 3;
                if (lx >= cx and lx < cx + wd - 1) return .{ .ws_tab = @fromBackingInt(@intCast(i)) };
                cx += wd;
            }
            return .none;
        }
        if (ry == 1) return .msg_header;
        switch (self.ws_tab) {
            .payload => return .{ .region = .payload },
            .mux => return .none,
            .layout => {},
        }
        const wm = self.wsMetrics(h, both, msg.length);
        if (wm.map_h > 0 and ry >= wm.map_y and ry < wm.map_y + wm.map_h) {
            const rel = ry - wm.map_y;
            if (rel == 0 or msg.length == 0) return .{ .region = .map };
            const mm = mapMetrics(w, wm.map_h, msg.length, self.map_bit);
            const row = rel - 1;
            const byte = mm.top + row;
            if (row >= mm.avail or byte >= msg.length or lx < 4) return .{ .region = .map };
            const col = (lx - 4) / 3;
            if (col >= mm.ncells) return .{ .region = .map };
            return .{ .map_cell = @intCast(byte * 8 + (7 - col)) };
        }
        if (wm.table_h > 0 and ry >= wm.table_y and ry < wm.table_y + wm.table_h) {
            const rel = ry - wm.table_y;
            if (rel == 0) return .{ .region = .table };
            const avail = wm.table_h - 1;
            const sigs = msg.signals.items.len;
            const idx = topFor(self.sel_sig -| 1, sigs, avail) + rel - 1;
            if (rel - 1 < avail and idx < sigs) return .{ .table_row = idx + 1 };
            return .{ .region = .table };
        }
        return .none;
    }

    fn hitInspector(self: *const Model, a: Alloc, lx: usize, ry: usize, w: usize, h: usize) !Hit {
        const row = self.curRow() orelse return .none;
        if (row.kind == .signal) {
            if (ry == 2) {
                const fs = try self.formFields(a, row);
                const present = presentGroups(fs);
                var next = @as(usize, @backingInt(self.activeGroup(fs)));
                var attempts: usize = 0;
                while (attempts < present.len) : (attempts += 1) {
                    next = (next + 1) % present.len;
                    if (present[next]) return .{ .insp_tab = @fromBackingInt(@intCast(next)) };
                }
                return .{ .region = .details };
            }
            const body_h = h -| 5;
            if (ry >= 3 and ry < 3 + body_h) {
                const body = try self.inspectorBody(a, w, row);
                const li = topFor(body.sel_line, body.dl.len, body_h) + ry - 3;
                if (li < body.dl.len) {
                    if (body.dl[li].item) |it| return .{ .insp_field = it };
                }
                return .{ .region = .details };
            }
            if (ry + 1 == h) {
                if (lx >= 2 and lx < 9) return .insp_apply;
                if (lx >= 11 and lx < 20) return .insp_discard;
            }
            return .{ .region = .details };
        }
        if (ry == 1 and w >= 48) {
            const fs = try self.formFields(a, row);
            const present = presentGroups(fs);
            var cx: usize = 0;
            for (group_titles, 0..) |t, gi| {
                if (!present[gi]) continue;
                const wd = t.len + 3;
                if (lx >= cx and lx < cx + wd - 1) return .{ .insp_tab = @fromBackingInt(@intCast(gi)) };
                cx += wd;
            }
            return .{ .region = .details };
        }
        const body_h = h -| 4;
        if (ry >= 2 and ry < 2 + body_h) {
            const body = try self.inspectorBody(a, w, row);
            const li = topFor(body.sel_line, body.dl.len, body_h) + ry - 2;
            if (li < body.dl.len) {
                if (body.dl[li].item) |it| return .{ .insp_field = it };
            }
            return .{ .region = .details };
        }
        if (ry + 1 == h) {
            if (lx >= 2 and lx < 9) return .insp_apply;
            if (lx >= 11 and lx < 20) return .insp_discard;
        }
        return .{ .region = .details };
    }

    fn onMouse(self: *Model, m: zz.MouseEvent) anyerror!zz.Cmd(Msg) {
        const W: usize = self.term_w;
        const H: usize = self.term_h;
        if (m.event_type != .press or W < 60 or H < 18) return .none;
        const wheel: isize = switch (m.button) {
            .wheel_up => -1,
            .wheel_down => 1,
            else => 0,
        };
        if (m.button != .left and wheel == 0) return .none;
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const x: usize = m.x;
        const y: usize = m.y;
        switch (self.mode) {
            .help => {
                self.mode = .normal;
                return .none;
            },
            .menu => return self.mouseMenu(a, x, y),
            .palette => return self.mousePalette(a, x, y),
            .welcome => return self.mouseWelcome(x, y),
            .normal => {},
            else => return .none,
        }
        if (self.editing) return .none;
        const hit = try self.hitTest(a, x, y);

        if (wheel != 0) {
            const target: Focus = switch (hit) {
                .filter, .browser_row => .tree,
                .map_cell => .map,
                .table_row, .msg_header => .table,
                .insp_field, .insp_tab, .insp_apply, .insp_discard => .details,
                .drawer => .diags,
                .region => |f| f,
                else => return .none,
            };
            if (self.drafts.items.len > 0 and (target == .tree or target == .map or target == .table)) return .none;
            if (target == .payload) {
                self.payload_scroll = if (wheel < 0) self.payload_scroll -| 1 else self.payload_scroll + 1;
                return .none;
            }
            self.focus = target;
            try self.move(wheel, null);
            return .none;
        }

        const leaves = switch (hit) {
            .browser_row, .map_cell, .table_row, .msg_header => true,
            else => false,
        };
        if (leaves and self.drafts.items.len > 0) {
            self.pending_mouse = m;
            self.mode = .draft_prompt;
            return .none;
        }
        switch (hit) {
            .none => {},
            .menu_title => |i| {
                self.mode = .menu;
                self.menu_idx = i;
                self.menu_item = 0;
            },
            .filter => self.focus = .filter,
            .browser_row => |i| {
                const r = self.rows.items[i];
                self.cursor = i;
                self.focus = .tree;
                self.sel_sig = 0;
                self.map_bit = 0;
                self.field_cursor = 0;
                if (r.kind == .category) try self.expandCategory(r.cat);
            },
            .ws_tab => |t| self.setWsTab(t),
            .msg_header => {
                self.focus = if (self.ws_tab == .layout) .table else .tree;
                self.selectSig(0);
            },
            .map_cell => |bit| {
                self.focus = .map;
                self.map_bit = bit;
                if (self.curMsg()) |msg| self.syncFromMap(msg);
            },
            .table_row => |s| {
                self.focus = .table;
                self.selectSig(s);
            },
            .insp_field => |vi| {
                self.focus = .details;
                if (vi == self.field_cursor) _ = try self.onFormKey(.{ .key = .enter }) else self.field_cursor = vi;
            },
            .insp_tab => |g| {
                self.focus = .details;
                self.insp_group = g;
                self.field_cursor = 0;
            },
            .insp_apply => {
                self.focus = .details;
                _ = try self.applyDrafts();
            },
            .insp_discard => {
                self.focus = .details;
                self.clearDrafts();
                try self.setStatus("Draft discarded", .{});
            },
            .drawer => self.focus = .diags,
            .region => |f| self.focus = f,
        }
        return .none;
    }

    fn mouseMenu(self: *Model, a: Alloc, x: usize, y: usize) !zz.Cmd(Msg) {
        if (y == 1) {
            var cx: usize = 0;
            for (menus, 0..) |m, i| {
                const wd = m.title.len + 2;
                if (x >= cx and x < cx + wd) {
                    self.menu_idx = i;
                    self.menu_item = 0;
                    return .none;
                }
                cx += wd;
            }
        }
        const box = try self.menuBox(a);
        const entries = menus[self.menu_idx].entries;
        self.mode = .normal;
        if (x >= box.x and x < box.x + box.width and y >= 3 and y < 3 + entries.len) {
            return self.runAction(entries[y - 3].action);
        }
        return .none;
    }

    fn mousePalette(self: *Model, a: Alloc, x: usize, y: usize) !zz.Cmd(Msg) {
        const H: usize = self.term_h;
        const total_h = (H -| (5 + self.drawerHeight(H))) + self.drawerHeight(H);
        const box = try self.paletteBox(a, self.term_w, total_h);
        const inside = x >= box.x and x < box.x + box.width;
        if (inside and y >= 4 and !std.mem.startsWith(u8, self.palette_buf.items, ":")) {
            const matches = try self.paletteEntries(a);
            const rows = @min(matches.len, @max(total_h -| 8, 3));
            const idx = topFor(self.palette_cursor, matches.len, rows) + (y - 4);
            if (y - 4 < rows and idx < matches.len) {
                self.palette_cursor = idx;
                return self.onPaletteKey(.{ .key = .enter });
            }
            return .none;
        }
        if (!inside or y < 2) self.mode = .normal;
        return .none;
    }

    fn mouseWelcome(self: *Model, x: usize, y: usize) !zz.Cmd(Msg) {
        if (x < 44 and y >= 7 and y < 7 + welcome_items.len) {
            self.welcome_item = y - 7;
            return self.onWelcomeKey(.{ .key = .enter });
        }
        return .none;
    }

    // ---- overlays: menu and palette ---------------------------------------

    /// Index just past the escape sequence that starts at `i`.
    fn escEnd(s: []const u8, i: usize) usize {
        var j = i + 1;
        if (j < s.len and s[j] == '[') {
            j += 1;
            while (j < s.len and (s[j] < 0x40 or s[j] > 0x7e)) j += 1;
            if (j < s.len) j += 1;
        }
        return j;
    }

    /// Replaces `tw` visible columns of `base` starting at column `x` with `top`.
    fn overlay(a: Alloc, base: []const u8, x: usize, top: []const u8, tw: usize) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        var col: usize = 0;
        while (i < base.len and col < x) {
            if (base[i] == 0x1b) {
                const e = escEnd(base, i);
                try out.appendSlice(a, base[i..e]);
                i = e;
            } else {
                const n = @min(std.unicode.utf8ByteSequenceLength(base[i]) catch 1, base.len - i);
                try out.appendSlice(a, base[i .. i + n]);
                i += n;
                col += 1;
            }
        }
        while (col < x) : (col += 1) try out.append(a, ' ');
        try out.appendSlice(a, "\x1b[0m");
        try out.appendSlice(a, top);
        var skipped: usize = 0;
        while (i < base.len and skipped < tw) {
            if (base[i] == 0x1b) {
                i = escEnd(base, i);
            } else {
                i += @min(std.unicode.utf8ByteSequenceLength(base[i]) catch 1, base.len - i);
                skipped += 1;
            }
        }
        try out.appendSlice(a, base[i..]);
        return out.items;
    }

    const Box = struct { x: usize, lines: []const []const u8, width: usize };

    /// Wraps pre-fitted body lines (each `width - 2` columns) in an ASCII border.
    fn boxed(a: Alloc, width: usize, body: []const []const u8) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var top: std.ArrayListUnmanaged(u8) = .empty;
        const left = if (plain) "+" else "┌";
        const right = if (plain) "+" else "┐";
        const horizontal = if (plain) "-" else "─";
        const vertical = if (plain) "|" else "│";
        if (!plain) try top.appendSlice(a, "\x1b[36m");
        try top.appendSlice(a, left);
        for (0..width - 2) |_| try top.appendSlice(a, horizontal);
        try top.appendSlice(a, right);
        if (!plain) try top.appendSlice(a, "\x1b[0m");
        try out.append(a, top.items);
        for (body) |l| {
            var row: std.ArrayListUnmanaged(u8) = .empty;
            if (!plain) try row.appendSlice(a, "\x1b[36m");
            try row.appendSlice(a, vertical);
            try row.appendSlice(a, l);
            try row.appendSlice(a, vertical);
            if (!plain) try row.appendSlice(a, "\x1b[0m");
            try out.append(a, row.items);
        }
        var bottom: std.ArrayListUnmanaged(u8) = .empty;
        if (!plain) try bottom.appendSlice(a, "\x1b[36m");
        try bottom.appendSlice(a, if (plain) "+" else "└");
        for (0..width - 2) |_| try bottom.appendSlice(a, horizontal);
        try bottom.appendSlice(a, if (plain) "+" else "┘");
        if (!plain) try bottom.appendSlice(a, "\x1b[0m");
        try out.append(a, bottom.items);
        return out.items;
    }

    fn menuBox(self: *const Model, a: Alloc) !Box {
        const width: usize = 38;
        var x: usize = 0;
        for (menus[0..self.menu_idx]) |m| x += m.title.len + 2;
        var body: std.ArrayListUnmanaged([]const u8) = .empty;
        for (menus[self.menu_idx].entries, 0..) |e, i| {
            const chord = if (self.keymap.primary(e.action)) |c| blk: {
                const buf = try a.alloc(u8, 24);
                break :blk c.describe(buf);
            } else "";
            const text = try fit(a, try std.fmt.allocPrint(a, " {s}{s}", .{ try fit(a, e.label, 24), chord }), width - 2);
            try body.append(a, try styled(a, text, if (i == self.menu_item) .sel else .none));
        }
        return .{ .x = x, .lines = try boxed(a, width, body.items), .width = width };
    }

    fn paletteEntries(self: *const Model, a: Alloc) ![]PalEntry {
        var all: std.ArrayListUnmanaged(PalEntry) = .empty;
        for (menus) |m| {
            for (m.entries) |e| try all.append(a, .{ .label = try std.fmt.allocPrint(a, "{s}: {s}", .{ m.title, e.label }), .run = .{ .action = e.action } });
        }
        try all.append(a, .{ .label = "Edit: Add bus...", .run = .{ .action = .add_bus } });
        try all.append(a, .{ .label = "Edit: Add node...", .run = .{ .action = .add_node } });
        inline for (comptime std.meta.fieldNames(Tab)) |fname| {
            const cat: Tab = @field(Tab, fname);
            try all.append(a, .{ .label = try std.fmt.allocPrint(a, "Go to: {s}", .{tab_titles[@backingInt(cat)]}), .run = .{ .category = cat } });
        }
        inline for (comptime std.meta.fieldNames(WsTab)) |fname| {
            const t: WsTab = @field(WsTab, fname);
            try all.append(a, .{ .label = try std.fmt.allocPrint(a, "Workspace: {s}", .{ws_titles[@backingInt(t)]}), .run = .{ .ws = t } });
        }
        var out: std.ArrayListUnmanaged(PalEntry) = .empty;
        for (all.items) |e| {
            var it = std.mem.tokenizeAny(u8, self.palette_buf.items, " \t");
            var ok = !std.mem.startsWith(u8, self.palette_buf.items, ":");
            while (ok) {
                const tok = it.next() orelse break;
                if (std.ascii.findIgnoreCase(e.label, tok) == null) ok = false;
            }
            if (ok) try out.append(a, e);
        }
        return out.items;
    }

    fn paletteBox(self: *const Model, a: Alloc, total_w: usize, total_h: usize) !Box {
        const width: usize = @min(total_w -| 4, 64);
        const inner = width - 2;
        const matches = try self.paletteEntries(a);
        var body: std.ArrayListUnmanaged([]const u8) = .empty;
        try body.append(a, try fit(a, try std.fmt.allocPrint(a, " > {s}_", .{self.palette_buf.items}), inner));
        if (std.mem.startsWith(u8, self.palette_buf.items, ":")) {
            try body.append(a, try fit(a, " Enter runs the command line (see Help)", inner));
        } else {
            const rows = @min(matches.len, @max(total_h -| 8, 3));
            const top = topFor(self.palette_cursor, matches.len, rows);
            for (matches[top .. top + rows], top..) |e, i| {
                const chord: []const u8 = switch (e.run) {
                    .action => |ac| if (self.keymap.primary(ac)) |c| blk: {
                        const buf = try a.alloc(u8, 24);
                        break :blk c.describe(buf);
                    } else "",
                    else => "",
                };
                const text = try fit(a, try std.fmt.allocPrint(a, " {s}{s}", .{ try fit(a, e.label, inner -| 14), chord }), inner);
                try body.append(a, try styled(a, text, if (i == self.palette_cursor) .sel else .none));
            }
            if (matches.len == 0) try body.append(a, try fit(a, " (no matching command)", inner));
        }
        return .{ .x = (total_w - width) / 2, .lines = try boxed(a, width, body.items), .width = width };
    }

    fn onPaletteKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const gpa = self.app.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        switch (k.key) {
            .escape => self.mode = .normal,
            .up, .down => {
                const n = (try self.paletteEntries(arena.allocator())).len;
                self.palette_cursor = stepIndex(self.palette_cursor, n, if (k.key == .up) -1 else 1, null);
            },
            .enter => {
                if (std.mem.startsWith(u8, self.palette_buf.items, ":")) {
                    const text = try gpa.dupe(u8, std.mem.trim(u8, self.palette_buf.items[1..], " \t"));
                    defer gpa.free(text);
                    self.mode = .normal;
                    return self.runCommand(text);
                }
                const matches = try self.paletteEntries(arena.allocator());
                if (self.palette_cursor >= matches.len) return .none;
                const run = matches[self.palette_cursor].run;
                self.mode = .normal;
                switch (run) {
                    .action => |ac| return self.runAction(ac),
                    .category => |c| {
                        try self.expandCategory(c);
                        self.focus = .tree;
                    },
                    .ws => |t| self.setWsTab(t),
                }
            },
            .backspace => {
                while (self.palette_buf.items.len > 0) {
                    const b = self.palette_buf.pop().?;
                    if (b & 0xC0 != 0x80) break;
                }
                self.palette_cursor = 0;
            },
            .space => {
                try self.palette_buf.append(gpa, ' ');
                self.palette_cursor = 0;
            },
            .paste => |s| {
                for (s) |b| if (b >= 0x20) try self.palette_buf.append(gpa, b);
                self.palette_cursor = 0;
            },
            .char => |c| {
                if (k.modifiers.ctrl) {
                    if (c == 'u') self.palette_buf.clearRetainingCapacity();
                    self.palette_cursor = 0;
                    return .none;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return .none;
                try self.palette_buf.appendSlice(gpa, buf[0..n]);
                self.palette_cursor = 0;
            },
            else => {},
        }
        return .none;
    }

    // ---- welcome screen and loading --------------------------------------

    fn onWelcomeKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        if (chordOf(k)) |c| {
            if (self.keymap.lookup(c)) |a| switch (a) {
                .open, .new_file, .quit, .help, .command, .menu => {
                    self.mode = .normal;
                    return self.runAction(a);
                },
                else => {},
            };
        }
        switch (k.key) {
            .up => self.welcome_item = (self.welcome_item + welcome_items.len - 1) % welcome_items.len,
            .down => self.welcome_item = (self.welcome_item + 1) % welcome_items.len,
            .escape => self.mode = .normal,
            .enter => {
                self.mode = .normal;
                switch (self.welcome_item) {
                    0 => return self.runAction(.open),
                    1 => try self.startInput(.new_path, "New file path (.can.json or .dbc)", "untitled.can.json"),
                    else => return self.runAction(.quit),
                }
            },
            else => {},
        }
        return .none;
    }

    fn welcomeLines(self: *const Model, a: Alloc, out: *std.ArrayListUnmanaged(u8), h: usize, W: usize) !void {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(a, "");
        try lines.append(a, try fit(a, "  can_dbz_editor", W));
        try lines.append(a, "");
        try lines.append(a, try fit(a, "  No file is open. Choose an action:", W));
        try lines.append(a, "");
        const chords = [_]Action{ .open, .new_file, .quit };
        for (welcome_items, 0..) |label, i| {
            const text = try std.fmt.allocPrint(a, "    {s}   ({s})", .{ label, try self.chordText(a, chords[i]) });
            try lines.append(a, try styled(a, try fit(a, text, @min(W, 44)), if (i == self.welcome_item) .sel else .none));
        }
        try lines.append(a, "");
        try lines.append(a, try fit(a, "  Esc: continue with an empty document", W));
        var i: usize = 0;
        while (i < h) : (i += 1) try pushLine(a, out, if (i < lines.items.len) try fit(a, lines.items[i], W) else try fit(a, "", W));
    }

    fn doOpen(self: *Model, path: []const u8) !void {
        const owned = try self.app.gpa.dupe(u8, path);
        if (self.pending_open) |old| self.app.gpa.free(old);
        self.pending_open = owned;
        try self.setStatus("Loading {s}...", .{path});
    }

    fn loadNow(self: *Model, path: []const u8) !void {
        self.app.open(path) catch |e| {
            self.show_diag = true;
            switch (e) {
                error.ParseFailed => try self.setStatus("Failed to open {s}: see diagnostics", .{path}),
                error.UnknownFormat => try self.setStatus("Unknown file type (expected .dbc or .can.json)", .{}),
                else => try self.setStatus("Failed to open {s}: {s}", .{ path, @errorName(e) }),
            }
            return;
        };
        self.clearDrafts();
        self.sel_sig = 0;
        self.map_bit = 0;
        self.tab = .messages;
        self.cursor = 0;
        self.focus = .tree;
        try self.rebuildRows();
        self.selectFirstMessage();
        self.show_diag = self.app.diags.count(.@"error") > 0;
        try self.setStatus("Opened {s} ({s}{s})", .{
            path,
            @tagName(self.app.format),
            if (self.app.format == .dbc) (if (self.app.dbc_mode == .strict) ", strict" else ", preserve opaque") else "",
        });
    }

    fn requestOpen(self: *Model, path: []const u8) !void {
        if (path.len == 0) return self.setStatus("Error: no file given", .{});
        if (self.app.isDirty()) return self.startConfirm(.open, "Discard unsaved changes and open file?", path, .{ .kind = .bus, .bus = 0 });
        try self.doOpen(path);
    }

    /// Startup screen when no file was given.
    pub fn promptCreate(self: *Model) !void {
        self.welcome_item = 0;
        self.mode = .welcome;
    }

    fn createFile(self: *Model, path: []const u8) !void {
        if (cio.detectFormat(path) == null) return self.setStatus("Unknown file type", .{});
        if (std.Io.Dir.cwd().access(self.app.io, path, .{})) |_| {
            return self.setStatus("{s} already exists", .{path});
        } else |_| {}
        self.app.save(path) catch |e| return self.setStatus("Create failed: {s}", .{@errorName(e)});
        try self.doOpen(path);
    }

    fn doSave(self: *Model, path: []const u8) !void {
        return self.saveWith(path, false);
    }

    fn saveWith(self: *Model, path: []const u8, force: bool) !void {
        if (path.len == 0) return self.setStatus("Error: no path given", .{});
        const result = if (force) self.app.saveForce(path) else self.app.save(path);
        result catch |e| switch (e) {
            error.ExternalChange => return self.startConfirm(.overwrite, "File changed on disk since it was opened or saved. Overwrite it?", path, .{ .kind = .bus, .bus = 0 }),
            error.UnsupportedConstruct => {
                try self.app.revalidate();
                self.show_diag = true;
                return self.setStatus("Cannot save as DBC: the document uses features DBC cannot express (see diagnostics). Save as .can.json to keep everything.", .{});
            },
            else => return self.setStatus("Save failed: {s}", .{@errorName(e)}),
        };
        try self.setStatus("Saved {s}", .{path});
    }

    fn saveCmd(self: *Model) !void {
        const gpa = self.app.gpa;
        const def = try self.app.defaultSavePath();
        defer gpa.free(def);
        if (self.app.path != null) return self.doSave(def);
        try self.startInput(.save_as, "Save to (.can.json or .dbc)", def);
    }

    fn doExport(self: *Model, path: []const u8) !void {
        if (path.len == 0) return self.setStatus("Error: no path given", .{});
        if (cio.detectFormat(path) == .can_json) return self.setStatus("Export writes DBC; use save for CAN JSON", .{});
        if (self.app.format == .dbc and self.app.isDirty() and vd.hasOpaqueStatements(&self.app.doc)) {
            if (self.app.path) |orig| {
                if (std.mem.eql(u8, orig, path)) return self.setStatus("Refusing to overwrite the original DBC: edits may break its opaque statements. Choose another path.", .{});
            }
        }
        self.app.exportDbc(path) catch |e| switch (e) {
            error.UnsupportedConstruct => {
                try self.app.revalidate();
                self.show_diag = true;
                return self.setStatus("Export blocked: document is not representable as DBC (see diagnostics)", .{});
            },
            else => return self.setStatus("Export failed: {s}", .{@errorName(e)}),
        };
        try self.setStatus("Exported {s}", .{path});
    }

    fn exportCmd(self: *Model) !void {
        try self.app.revalidate();
        var items: usize = 0;
        for (self.app.diags.items.items) |d| {
            if (d.group == .export_dbc) items += 1;
        }
        if (items > 0 or vd.hasOpaqueStatements(&self.app.doc)) {
            self.review_scroll = 0;
            self.mode = .review;
            return;
        }
        try self.startExportPath();
    }

    fn startExportPath(self: *Model) !void {
        const def = try self.app.defaultExportPath();
        defer self.app.gpa.free(def);
        try self.startInput(.export_dbc, "Export DBC to", def);
    }

    fn reviewBlocked(self: *const Model) bool {
        for (self.app.diags.items.items) |d| {
            if (d.group == .export_dbc and d.blocking) return true;
        }
        return false;
    }

    fn startPlacement(self: *Model) !void {
        const msg = self.curMsg() orelse return self.setStatus("Select a signal first", .{});
        if (self.tab != .messages or self.sel_sig == 0 or self.focus == .tree) return self.setStatus("Select a signal in the map or table first", .{});
        const s = msg.signals.items[self.sel_sig - 1];
        self.place_start = s.start_bit;
        self.place_len = s.bit_length;
        self.mode = .place;
    }

    /// Copy of the selected message with the moving signal at its candidate position.
    fn candidate(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message) !*const can_dbz.model.Message {
        const c = try a.create(can_dbz.model.Message);
        c.* = msg.*;
        c.signals = try msg.signals.clone(a);
        const s = &c.signals.items[self.sel_sig - 1];
        s.start_bit = self.place_start;
        s.bit_length = self.place_len;
        return c;
    }

    fn onPlaceKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const msg = self.curMsg() orelse {
            self.mode = .normal;
            return .none;
        };
        const limit: u32 = @as(u32, msg.length) * 8;
        const dx: i32, const dy: i32 = switch (k.key) {
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
            .up => .{ 0, -1 },
            .down => .{ 0, 1 },
            .char => |c| switch (c) {
                'h' => .{ -1, 0 },
                'l' => .{ 1, 0 },
                'k' => .{ 0, -1 },
                'j' => .{ 0, 1 },
                else => .{ 0, 0 },
            },
            else => .{ 0, 0 },
        };
        // Screen-left is toward higher bit numbers within a byte; one row is eight bits.
        if (dx < 0 and self.place_start % 8 < 7 and self.place_start + 1 < limit) self.place_start += 1;
        if (dx > 0 and self.place_start % 8 > 0) self.place_start -= 1;
        if (dy < 0 and self.place_start >= 8) self.place_start -= 8;
        if (dy > 0 and self.place_start + 8 < limit) self.place_start += 8;
        switch (k.key) {
            .escape => {
                self.mode = .normal;
                try self.setStatus("Placement cancelled", .{});
            },
            .enter => try self.commitPlacement(),
            .char => |c| switch (c) {
                '+', '=' => self.place_len = @min(self.place_len + 1, 64),
                '-' => self.place_len = @max(self.place_len -| 1, 1),
                else => {},
            },
            else => {},
        }
        self.map_bit = self.place_start;
        return .none;
    }

    fn commitPlacement(self: *Model) !void {
        const r = self.browserRow() orelse return;
        const row: Row = .{ .kind = .signal, .bus = r.bus, .msg = r.msg, .sig = self.sel_sig - 1 };
        var arena = std.heap.ArenaAllocator.init(self.app.gpa);
        defer arena.deinit();
        const before = try self.check(arena.allocator());
        try self.app.beginEdit();
        var buf: [2][8]u8 = undefined;
        const start_txt = std.fmt.bufPrint(&buf[0], "{d}", .{self.place_start}) catch unreachable;
        const len_txt = std.fmt.bufPrint(&buf[1], "{d}", .{self.place_len}) catch unreachable;
        ops.setSignalField(&self.app.doc, row.msg, row.sig, .start_bit, start_txt) catch |e| {
            try self.app.abortEdit();
            return self.setStatus("Error: {s}", .{errText(e)});
        };
        ops.setSignalField(&self.app.doc, row.msg, row.sig, .bit_length, len_txt) catch |e| {
            try self.app.abortEdit();
            return self.setStatus("Error: {s}", .{errText(e)});
        };
        const after = try self.check(arena.allocator());
        if (after.errors > before.errors) {
            try self.setStatus("Rejected: {s}", .{after.last orelse "placement is invalid"});
            try self.app.abortEdit();
            return;
        }
        self.app.endEdit();
        self.mode = .normal;
        try self.setStatus("Signal placed", .{});
    }

    fn placeStatus(self: *const Model, a: Alloc) ![]const u8 {
        const msg = self.curMsg() orelse return "";
        const cand = try self.candidate(a, msg);
        const occ = try layout.occupancy(a, cand);
        const idx = self.sel_sig - 1;
        var issue: []const u8 = "fits";
        var it = layout.BitIter.init(&cand.signals.items[idx]);
        while (it.next()) |b| {
            if (b < occ.cells.len and occ.cells[b].collision) issue = "COLLIDES";
        }
        for (occ.out_of_bounds.items) |si| {
            if (si == idx) issue = "BEYOND PAYLOAD";
        }
        return std.fmt.allocPrint(a, "Move {s}: start={d} bits={d} [{s}]  arrows move, +/- resize, Enter apply, Esc cancel", .{ cand.signals.items[idx].name, self.place_start, self.place_len, issue });
    }

    fn openPayload(self: *Model) !void {
        if (self.tab != .messages or self.curMsg() == null) return self.setStatus("Select a message first", .{});
        self.payload_scroll = 0;
        self.ws_tab = .payload;
        self.focus = .payload;
    }

    fn firstFocusOf(t: WsTab) Focus {
        return switch (t) {
            .layout => .map,
            .payload => .payload,
            .mux => .tree,
        };
    }

    fn setWsTab(self: *Model, t: WsTab) void {
        self.ws_tab = t;
        self.payload_scroll = 0;
        if (self.focus == .map or self.focus == .table or self.focus == .payload) self.focus = firstFocusOf(t);
    }

    fn onPayloadKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const gpa = self.app.gpa;
        switch (k.key) {
            .escape => self.focus = .tree,
            .tab => self.stepFocus(if (k.modifiers.shift) -1 else 1),
            .backspace => _ = self.payload_buf.pop(),
            .space => try self.payload_buf.append(gpa, ' '),
            .up => self.payload_scroll -|= 1,
            .down => self.payload_scroll += 1,
            .paste => |s| for (s) |b| if (std.ascii.isHex(b) or b == ' ') try self.payload_buf.append(gpa, b),
            .char => |c| {
                if (k.modifiers.ctrl) {
                    if (c == 'u') self.payload_buf.clearRetainingCapacity();
                } else if (c < 128 and std.ascii.isHex(@intCast(c))) {
                    try self.payload_buf.append(gpa, @intCast(c));
                }
            },
            else => {},
        }
        return .none;
    }

    fn paneTabRow(self: *const Model, a: Alloc, w: usize) ![]const u8 {
        var s: std.ArrayListUnmanaged(u8) = .empty;
        for (ws_titles, 0..) |t, i| {
            const active = i == @backingInt(self.ws_tab);
            try appendPrint(a, &s, "{s}{s}{s}", .{ if (active) "[" else " ", t, if (active) "]" else " " });
            try s.append(a, ' ');
        }
        return fit(a, s.items, w);
    }

    fn payloadPane(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message, w: usize, h: usize) !Lines {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        const mi = self.browserRow().?.msg;
        const res = try payload.decode(self.app.gpa, a, &self.app.doc, mi, self.payload_buf.items);
        const cursor: []const u8 = if (self.focus == .payload) "_" else "";
        try lines.append(a, try fit(a, try std.fmt.allocPrint(a, "{s}: {d} bytes; hex bytes separated by spaces, Ctrl+U clears", .{ msg.name, res.expected }), w));
        try lines.append(a, try fit(a, try std.fmt.allocPrint(a, "> {s}{s}   [{d}/{d} bytes]", .{ self.payload_buf.items, cursor, res.have, res.expected }), w));
        try lines.append(a, try fit(a, res.note orelse "", w));
        const wide = w >= 80;
        const head = try std.fmt.allocPrint(a, "{s} {s} {s} {s}{s}", .{
            try fit(a, "Signal", 16),                                                             try fit(a, "State", 8), try fit(a, "Raw", 20), try fit(a, "Physical", 14),
            if (wide) try std.fmt.allocPrint(a, " {s} Choice", .{try fit(a, "Unit", 6)}) else "",
        });
        const first_row = lines.items.len + 1;
        try lines.append(a, try fit(a, head, w));
        for (res.rows) |r| {
            try lines.append(a, try fit(a, try std.fmt.allocPrint(a, "{s} {s} {s} {s}{s}", .{
                try fit(a, r.name, 16),                                                                        try fit(a, r.state, 8), try fit(a, r.raw, 20), try fit(a, r.physical, 14),
                if (wide) try std.fmt.allocPrint(a, " {s} {s}", .{ try fit(a, r.unit, 6), r.choice }) else "",
            }), w));
        }
        const top = @min(self.payload_scroll, res.rows.len -| h -| first_row);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const idx = if (i < first_row) i else first_row + top + (i - first_row);
            if (idx < lines.items.len) try out.append(a, lines.items[idx]);
        }
        return finish(a, &out, w, h);
    }

    fn rangeText(a: Alloc, ranges: []const can_dbz.model.RawRange) ![]const u8 {
        var s: std.ArrayListUnmanaged(u8) = .empty;
        for (ranges, 0..) |r, i| {
            if (i > 0) try s.appendSlice(a, ",");
            if (std.mem.eql(u8, r.minimum, r.maximum)) try s.appendSlice(a, r.minimum) else try appendPrint(a, &s, "{s}..{s}", .{ r.minimum, r.maximum });
        }
        return s.items;
    }

    fn muxPane(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message, w: usize, h: usize) !Lines {
        _ = self;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var any = false;
        for (msg.signals.items) |s| {
            if (s.is_multiplexer) {
                any = true;
                try out.append(a, try fit(a, try std.fmt.allocPrint(a, "Selector: {s}  (start {d}, {d} bits)", .{ s.name, s.start_bit, s.bit_length }), w));
            }
        }
        for (msg.signals.items) |s| {
            if (s.when.items.len == 0) continue;
            any = true;
            var cond: std.ArrayListUnmanaged(u8) = .empty;
            for (s.when.items, 0..) |c, i| {
                if (i > 0) try cond.appendSlice(a, " AND ");
                try appendPrint(a, &cond, "{s} = {s}", .{ c.selector, try rangeText(a, c.ranges.items) });
            }
            try out.append(a, try fit(a, try std.fmt.allocPrint(a, "  {s}: active when {s}", .{ s.name, cond.items }), w));
        }
        if (!any) try out.append(a, try fit(a, "(no multiplexed signals in this message)", w));
        try out.append(a, try fit(a, "", w));
        try out.append(a, try fit(a, "Edit conditions in Inspector > Multiplexing; ranges are inclusive.", w));
        return finish(a, &out, w, h);
    }

    fn onMenuKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const entries = menus[self.menu_idx].entries;
        switch (k.key) {
            .escape, .f10 => self.mode = .normal,
            .left => {
                self.menu_idx = (self.menu_idx + menus.len - 1) % menus.len;
                self.menu_item = 0;
            },
            .right => {
                self.menu_idx = (self.menu_idx + 1) % menus.len;
                self.menu_item = 0;
            },
            .up => self.menu_item = (self.menu_item + entries.len - 1) % entries.len,
            .down => self.menu_item = (self.menu_item + 1) % entries.len,
            .home => self.menu_item = 0,
            .end => self.menu_item = entries.len - 1,
            .enter => {
                const action = entries[self.menu_item].action;
                self.mode = .normal;
                return self.runAction(action);
            },
            else => {},
        }
        return .none;
    }

    fn onReviewKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        switch (k.key) {
            .escape => self.mode = .normal,
            .up => self.review_scroll -|= 1,
            .down => self.review_scroll += 1,
            .enter => if (!self.reviewBlocked()) {
                self.mode = .normal;
                try self.startExportPath();
            },
            .char => |c| switch (c) {
                'q' => self.mode = .normal,
                'k' => self.review_scroll -|= 1,
                'j' => self.review_scroll += 1,
                else => {},
            },
            else => {},
        }
        return .none;
    }

    fn reviewLines(self: *const Model, a: Alloc, out: *std.ArrayListUnmanaged(u8), h: usize, W: usize) !void {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        const blocked = self.reviewBlocked();
        try lines.append(a, "DBC export review");
        try lines.append(a, "");
        inline for (.{ true, false }) |want_blocking| {
            var n: usize = 0;
            for (self.app.diags.items.items) |d| {
                if (d.group == .export_dbc and d.blocking == want_blocking) n += 1;
            }
            if (n > 0) {
                try lines.append(a, if (want_blocking) try std.fmt.allocPrint(a, "Blocked ({d}): fix these before exporting", .{n}) else try std.fmt.allocPrint(a, "Omitted ({d}): NOT written to the DBC file", .{n}));
                for (self.app.diags.items.items) |d| {
                    if (d.group != .export_dbc or d.blocking != want_blocking) continue;
                    const where = if (d.message) |m| try std.fmt.allocPrint(a, " [{s}{s}{s}]", .{ m, if (d.signal != null) "/" else "", d.signal orelse "" }) else "";
                    for (try wrap(a, try std.fmt.allocPrint(a, "{s}{s}", .{ d.text, where }), W -| 4), 0..) |c, ci| {
                        try lines.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ if (ci == 0) "  - " else "    ", c }));
                    }
                }
                try lines.append(a, "");
            }
        }
        if (vd.hasOpaqueStatements(&self.app.doc)) {
            try lines.append(a, "Opaque DBC statements are copied verbatim; references inside them are not checked.");
            try lines.append(a, "");
        }
        try lines.append(a, if (blocked) "Esc: close" else "Enter: choose a new file and export with these omissions   Esc: cancel");

        const top = @min(self.review_scroll, lines.items.len -| h);
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const line = if (top + i < lines.items.len) lines.items[top + i] else "";
            try pushLine(a, out, try fit(a, line, W));
        }
    }

    fn runSearch(self: *Model, forward: bool) !void {
        const q = self.last_search orelse return self.setStatus("No search pattern (use /)", .{});
        var from: ?app_mod.Pos = null;
        if (self.curRow()) |r| switch (r.kind) {
            .bus, .node, .table, .category, .attr, .meta => {},
            .message => from = .{ .msg = r.msg },
            .signal => from = .{ .msg = r.msg, .sig = r.sig },
        };
        if (self.app.search(q, from, forward)) |pos| {
            try self.selectPos(pos);
            try self.setStatus("/{s}", .{q});
        } else try self.setStatus("No match for '{s}'", .{q});
    }

    fn jumpToDiag(self: *Model, index: usize) !void {
        const item = self.app.diags.items.items[self.orderedDiag(index) orelse return];
        const doc = &self.app.doc;
        if (item.message) |mname| {
            for (doc.messages.items, 0..) |m, mi| {
                if (!std.mem.eql(u8, m.name, mname)) continue;
                if (item.bus) |b| if (!std.mem.eql(u8, m.bus, b)) continue;
                const sig: ?usize = if (item.signal) |s| ops.findSignal(&m, s) else null;
                return self.selectPos(.{ .msg = mi, .sig = sig });
            }
        } else if (item.bus) |b| {
            if (ops.findBus(doc, b)) |bi| {
                self.tab = .messages;
                try self.rebuildRows();
                self.selectRow(.{ .kind = .bus, .bus = bi });
                self.focus = .tree;
            }
        }
    }

    /// Index into the diagnostics list of the n-th entry when grouped parse -> validation -> export.
    fn orderedDiag(self: *const Model, n: usize) ?usize {
        var k: usize = 0;
        inline for (.{ vd.Group.parse, vd.Group.validation, vd.Group.export_dbc }) |g| {
            for (self.app.diags.items.items, 0..) |d, i| {
                if (d.group != g) continue;
                if (k == n) return i;
                k += 1;
            }
        }
        return null;
    }

    fn move(self: *Model, delta: isize, to_edge: ?bool) !void {
        switch (self.focus) {
            .filter, .payload => {},
            .tree => {
                if (self.term_w >= 80 and self.term_w < 90 and self.term_h >= 24 and self.tab == .messages) {
                    var arena = std.heap.ArenaAllocator.init(self.app.gpa);
                    defer arena.deinit();
                    const compact = try self.compactMessages(arena.allocator());
                    if (compact.len == 0) return;
                    const current = self.browserRow();
                    var compact_cursor: usize = 0;
                    if (current) |selected| {
                        for (compact, 0..) |r, i| {
                            if (selected.kind == .message and r.msg == selected.msg) compact_cursor = i;
                        }
                    }
                    const next = stepIndex(compact_cursor, compact.len, delta, to_edge);
                    self.selectRow(compact[next]);
                    self.sel_sig = 0;
                    self.map_bit = 0;
                    self.field_cursor = 0;
                    return;
                }
                const n = self.rows.items.len;
                if (n == 0) return;
                self.cursor = stepIndex(self.cursor, n, delta, to_edge);
                self.field_cursor = 0;
                self.sel_sig = 0;
                self.map_bit = 0;
            },
            .map => {
                const msg = self.curMsg() orelse return;
                if (msg.length == 0) return;
                const last: usize = msg.length - 1;
                const byte = stepIndex(@min(self.map_bit / 8, last), last + 1, delta, to_edge);
                self.map_bit = @intCast(byte * 8 + self.map_bit % 8);
                self.syncFromMap(msg);
            },
            .table => {
                const msg = self.curMsg() orelse return;
                self.selectSig(stepIndex(self.sel_sig, msg.signals.items.len + 1, delta, to_edge));
            },
            .details => {
                const row = self.curRow() orelse return;
                var arena = std.heap.ArenaAllocator.init(self.app.gpa);
                defer arena.deinit();
                const n = (try self.visibleFields(arena.allocator(), row)).len + 2;
                self.field_cursor = stepIndex(self.field_cursor, n, delta, to_edge);
            },
            .diags => self.diag_cursor = stepIndex(self.diag_cursor, self.app.diags.items.items.len, delta, to_edge),
        }
    }

    fn stepIndex(cur: usize, n: usize, delta: isize, to_edge: ?bool) usize {
        if (n == 0) return 0;
        if (to_edge) |bottom| return if (bottom) n - 1 else 0;
        const next = @as(isize, @intCast(cur)) + delta;
        return @intCast(std.math.clamp(next, 0, @as(isize, @intCast(n)) - 1));
    }

    fn curMsg(self: *const Model) ?*const can_dbz.model.Message {
        const r = self.browserRow() orelse return null;
        if (r.kind != .message) return null;
        return &self.app.doc.messages.items[r.msg];
    }

    /// Selects the signal owning the cell under the map cursor; unused cells leave the selection alone.
    fn syncFromMap(self: *Model, msg: *const can_dbz.model.Message) void {
        var occ = layout.occupancy(self.app.gpa, msg) catch return;
        defer occ.deinit(self.app.gpa);
        if (self.map_bit >= occ.cells.len) return;
        const owner = occ.cells[self.map_bit].owner;
        if (owner == layout.no_owner) return;
        self.sel_sig = @as(usize, owner) + 1;
        self.field_cursor = 0;
    }

    /// dx < 0 moves left on screen, which is toward higher bit numbers within a byte.
    fn moveMapSideways(self: *Model, dx: i32) void {
        const msg = self.curMsg() orelse return;
        if (msg.length == 0) return;
        const byte = @min(self.map_bit / 8, @as(u32, msg.length) - 1);
        var bit = self.map_bit % 8;
        if (dx < 0 and bit < 7) bit += 1;
        if (dx > 0 and bit > 0) bit -= 1;
        self.map_bit = byte * 8 + bit;
        self.syncFromMap(msg);
    }

    fn stepFocus(self: *Model, dir: isize) void {
        var order: [5]Focus = undefined;
        var n: usize = 0;
        order[n] = .tree;
        n += 1;
        if (self.tab == .messages and self.curMsg() != null) {
            switch (self.ws_tab) {
                .layout => {
                    order[n] = .map;
                    order[n + 1] = .table;
                    n += 2;
                },
                .payload => {
                    order[n] = .payload;
                    n += 1;
                },
                .mux => {},
            }
        }
        order[n] = .details;
        n += 1;
        if (self.show_diag) {
            order[n] = .diags;
            n += 1;
        }
        var idx: usize = 0;
        for (order[0..n], 0..) |f, i| {
            if (f == self.focus) idx = i;
        }
        const next = @mod(@as(isize, @intCast(idx)) + dir, @as(isize, @intCast(n)));
        self.focus = order[@intCast(next)];
    }

    fn cycleFocus(self: *Model) void {
        self.stepFocus(1);
    }

    /// Enter on an occupied cell edits its signal; on an unused cell it starts a signal anchored there.
    fn mapEnter(self: *Model) !void {
        const msg = self.curMsg() orelse return;
        var occ = try layout.occupancy(self.app.gpa, msg);
        defer occ.deinit(self.app.gpa);
        if (self.map_bit >= occ.cells.len) return self.setStatus("Message has no payload bytes", .{});
        if (occ.cells[self.map_bit].owner != layout.no_owner) {
            self.focus = .details;
        } else {
            self.anchor_bit = self.map_bit;
            try self.startInput(.add_signal, "New signal name", "");
        }
    }

    fn entityName(self: *const Model, row: Row) []const u8 {
        return switch (row.kind) {
            .bus => self.app.doc.buses.items[row.bus].name,
            .category => tab_titles[@backingInt(row.cat)],
            .attr => self.app.doc.attribute_definitions.items[row.idx].name,
            .meta => meta_labels[row.idx],
            .message => self.app.doc.messages.items[row.msg].name,
            .signal => self.app.doc.messages.items[row.msg].signals.items[row.sig].name,
            .node => self.app.doc.nodes.items[row.node].name,
            .table => self.app.doc.value_tables.items[row.table].name,
        };
    }

    fn doNew(self: *Model) !void {
        self.clearDrafts();
        try self.app.reset();
        self.tab = .messages;
        self.cursor = 0;
        self.sel_sig = 0;
        self.map_bit = 0;
        self.focus = .tree;
        try self.rebuildRows();
        try self.setStatus("New document", .{});
    }

    fn duplicateSelected(self: *Model) !void {
        const row = self.curRow() orelse return;
        if (row.kind != .message and row.kind != .signal) return self.setStatus("Select a message or signal to duplicate", .{});
        try self.app.beginEdit();
        const doc = &self.app.doc;
        const made: ops.Error!usize = if (row.kind == .signal) ops.duplicateSignal(doc, row.msg, row.sig) else ops.duplicateMessage(doc, row.msg);
        const idx = made catch |e| {
            try self.app.abortEdit();
            return self.setStatus("Error: {s}", .{errText(e)});
        };
        self.app.endEdit();
        try self.rebuildRows();
        if (row.kind == .signal) {
            self.selectSig(idx + 1);
        } else {
            self.selectRow(.{ .kind = .message, .bus = row.bus, .msg = idx });
            self.sel_sig = 0;
        }
        try self.setStatus("Duplicated", .{});
    }

    fn do(self: *Model, action: Action) !zz.Cmd(Msg) {
        const row = self.curRow();
        switch (action) {
            .quit => {
                if (self.app.isDirty()) {
                    try self.startConfirm(.quit, "Unsaved changes. Quit anyway?", null, .{ .kind = .bus, .bus = 0 });
                } else return .quit;
            },
            .up => try self.move(-1, null),
            .down => try self.move(1, null),
            .top => try self.move(0, false),
            .bottom => try self.move(0, true),
            .left => if (self.focus == .map) self.moveMapSideways(-1) else self.stepFocus(-1),
            .right => if (self.focus == .map) self.moveMapSideways(1) else self.stepFocus(1),
            .edit => switch (self.focus) {
                .filter => self.focus = .tree,
                .payload => {},
                .tree => if (row) |r| {
                    if (r.kind == .category) {
                        try self.expandCategory(r.cat);
                    } else if (self.curMsg() != null and self.tab == .messages) {
                        self.focus = .table;
                    } else {
                        self.focus = .details;
                    }
                },
                .map => try self.mapEnter(),
                .table => self.focus = .details,
                .details => {},
                .diags => try self.jumpToDiag(self.diag_cursor),
            },
            .add => switch (if (row) |r| (if (r.kind == .category) r.cat else self.tab) else self.tab) {
                .nodes => try self.startInput(.add_node, "New node name", ""),
                .tables => try self.startInput(.add_table, "New value table name", ""),
                .attributes, .metadata => try self.setStatus("Attributes and metadata are read-only for now", .{}),
                .messages => if (row) |r| switch (r.kind) {
                    .bus, .category => try self.startInput(.add_message, "New message name", ""),
                    else => {
                        self.anchor_bit = null;
                        try self.startInput(.add_signal, "New signal name", "");
                    },
                } else try self.setStatus("Add a bus first (:add bus NAME)", .{}),
            },
            .add_bus => {
                try self.switchTab(.messages);
                try self.startInput(.add_bus, "New bus name", "");
            },
            .add_node => {
                try self.switchTab(.nodes);
                try self.startInput(.add_node, "New node name", "");
            },
            .tab_next => self.setWsTab(@fromBackingInt(@intCast((@backingInt(self.ws_tab) + 1) % ws_titles.len))),
            .tab_prev => self.setWsTab(@fromBackingInt(@intCast((@backingInt(self.ws_tab) + ws_titles.len - 1) % ws_titles.len))),
            .delete => if (row) |r| {
                if (r.kind == .bus or r.kind == .category or r.kind == .attr or r.kind == .meta) {
                    try self.setStatus("Only messages, signals, nodes and value tables can be deleted", .{});
                } else {
                    const txt = try std.fmt.allocPrint(self.app.gpa, "Delete {s} '{s}'?", .{ @tagName(r.kind), self.entityName(r) });
                    defer self.app.gpa.free(txt);
                    try self.startConfirm(.delete, txt, null, r);
                }
            },
            .duplicate => try self.duplicateSelected(),
            .form_apply => _ = try self.applyDrafts(),
            .form_discard => {
                self.clearDrafts();
                try self.setStatus("Draft discarded", .{});
            },
            .new_file => if (self.app.isDirty())
                try self.startConfirm(.new, "Discard unsaved changes and start a new file?", null, .{ .kind = .bus, .bus = 0 })
            else
                try self.doNew(),
            .pane_next => self.stepFocus(1),
            .pane_prev => self.stepFocus(-1),
            .menu => {
                self.mode = .menu;
                self.menu_idx = 0;
                self.menu_item = 0;
            },
            .open => try self.startInput(.open, "Open file", self.app.path orelse ""),
            .save => try self.saveCmd(),
            .save_as => {
                const def = try self.app.defaultSavePath();
                defer self.app.gpa.free(def);
                try self.startInput(.save_as, "Save to (.can.json or .dbc)", def);
            },
            .export_dbc => try self.exportCmd(),
            .validate => {
                try self.app.revalidate();
                const e = self.app.diags.count(.@"error");
                const w = self.app.diags.count(.warning);
                self.show_diag = e + w > 0;
                try self.setStatus("Validation: {d} error(s), {d} warning(s)", .{ e, w });
            },
            .compact => {
                try self.app.compact();
                try self.afterDocChange();
                try self.setStatus("Document compacted", .{});
            },
            .undo => try self.stepHistory(false),
            .redo => try self.stepHistory(true),
            .focus_filter => self.focus = .filter,
            .command => {
                self.palette_buf.clearRetainingCapacity();
                self.palette_cursor = 0;
                self.mode = .palette;
            },
            .toggle_diag => {
                self.show_diag = !self.show_diag;
                if (!self.show_diag and self.focus == .diags) self.focus = .tree;
            },
            .toggle_dbc_mode => {
                self.app.dbc_mode = if (self.app.dbc_mode == .strict) .preserve_opaque else .strict;
                try self.setStatus("DBC import mode: {s} (applies to next open)", .{@tagName(self.app.dbc_mode)});
            },
            .help => self.mode = .help,
            .payload_test => try self.openPayload(),
            .move_signal => try self.startPlacement(),
        }
        return .none;
    }

    fn runCommand(self: *Model, text: []const u8) !zz.Cmd(Msg) {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const cmd = it.next() orelse return .none;
        const rest = std.mem.trim(u8, it.rest(), " \t");
        const eql = std.mem.eql;
        if (eql(u8, cmd, "open") or eql(u8, cmd, "o")) {
            try self.requestOpen(rest);
        } else if (eql(u8, cmd, "save") or eql(u8, cmd, "w")) {
            if (rest.len == 0) try self.saveCmd() else try self.doSave(rest);
        } else if (eql(u8, cmd, "export")) {
            if (rest.len == 0) try self.exportCmd() else try self.doExport(rest);
        } else if (eql(u8, cmd, "validate")) {
            return self.do(.validate);
        } else if (eql(u8, cmd, "compact")) {
            return self.do(.compact);
        } else if (eql(u8, cmd, "undo")) {
            return self.do(.undo);
        } else if (eql(u8, cmd, "redo")) {
            return self.do(.redo);
        } else if (eql(u8, cmd, "help")) {
            return self.do(.help);
        } else if (eql(u8, cmd, "new")) {
            return self.do(.new_file);
        } else if (eql(u8, cmd, "payload")) {
            return self.do(.payload_test);
        } else if (eql(u8, cmd, "move")) {
            return self.do(.move_signal);
        } else if (eql(u8, cmd, "dup") or eql(u8, cmd, "duplicate")) {
            return self.do(.duplicate);
        } else if (eql(u8, cmd, "quit") or eql(u8, cmd, "q")) {
            return self.do(.quit);
        } else if (eql(u8, cmd, "mode")) {
            if (eql(u8, rest, "strict")) {
                self.app.dbc_mode = .strict;
            } else if (eql(u8, rest, "preserve")) {
                self.app.dbc_mode = .preserve_opaque;
            } else return self.setStatusNone("Usage: mode strict|preserve");
            try self.setStatus("DBC import mode: {s} (applies to next open)", .{@tagName(self.app.dbc_mode)});
        } else if (eql(u8, cmd, "add")) {
            var sub = std.mem.tokenizeAny(u8, rest, " \t");
            const kind = sub.next() orelse return self.setStatusNone("Usage: add bus|message|signal|node|table NAME");
            const name = std.mem.trim(u8, sub.rest(), " \t");
            const row = self.curRow() orelse Row{ .kind = .bus, .bus = 0 };
            if (eql(u8, kind, "bus")) {
                try self.doAdd(.add_bus, row, name);
            } else if (eql(u8, kind, "table")) {
                try self.doAdd(.add_table, row, name);
            } else if (eql(u8, kind, "node")) {
                try self.doAdd(.add_node, row, name);
            } else if (eql(u8, kind, "message")) {
                if (self.app.doc.buses.items.len == 0) return self.setStatusNone("Add a bus first");
                try self.doAdd(.add_message, row, name);
            } else if (eql(u8, kind, "signal")) {
                if (row.kind != .message and row.kind != .signal) return self.setStatusNone("Select a message first");
                try self.doAdd(.add_signal, row, name);
            } else return self.setStatusNone("Usage: add bus|message|signal|node|table NAME");
        } else try self.setStatus("Unknown command: {s}", .{cmd});
        return .none;
    }

    fn setStatusNone(self: *Model, text: []const u8) !zz.Cmd(Msg) {
        try self.setStatus("{s}", .{text});
        return .none;
    }

    /// Reopens the input with its text after a rejected edit so the user can fix it or press Esc to discard.
    fn retainDraft(self: *Model) void {
        self.mode = .input;
        self.draft_retained = true;
    }

    fn submitInput(self: *Model) !zz.Cmd(Msg) {
        const gpa = self.app.gpa;
        const text = try gpa.dupe(u8, std.mem.trim(u8, self.input_buf.items, " \t"));
        defer gpa.free(text);
        self.mode = .normal;
        const row = self.input_row;
        switch (self.input_purpose) {
            .open => try self.requestOpen(text),
            .save_as => try self.doSave(text),
            .export_dbc => try self.doExport(text),
            .search => {
                if (text.len == 0) return .none;
                const dup = try gpa.dupe(u8, text);
                if (self.last_search) |s| gpa.free(s);
                self.last_search = dup;
                try self.runSearch(true);
            },
            .command => return self.runCommand(text),
            .add_bus, .add_message, .add_signal, .add_node, .add_table => {
                const cur = self.curRow() orelse Row{ .kind = .bus, .bus = 0 };
                try self.doAdd(self.input_purpose, cur, text);
            },
            .rename => {
                const tag: FieldTag = switch (row.kind) {
                    .message => .{ .m = .name },
                    .node => .{ .n = .name },
                    .table => .{ .t = .name },
                    else => .{ .s = .name },
                };
                if (!try self.applyTag(row, tag, text)) self.retainDraft();
            },
            .edit_field => if (!try self.applyTag(row, self.input_tag, text)) self.retainDraft(),
            .new_path => {
                if (text.len == 0) return .none;
                if (cio.detectFormat(text) != null) {
                    try self.createFile(text);
                } else {
                    const dup = try gpa.dupe(u8, text);
                    if (self.confirm_path) |s| gpa.free(s);
                    self.confirm_path = dup;
                    try self.startInput(.new_type, "File type (can.json or dbc)", "can.json");
                }
            },
            .new_type => {
                const base = self.confirm_path orelse return .none;
                const ext: []const u8 = if (std.mem.eql(u8, text, "dbc")) ".dbc" else if (std.mem.eql(u8, text, "can.json") or std.mem.eql(u8, text, "json")) ".can.json" else {
                    try self.setStatus("Unknown type '{s}' (use can.json or dbc)", .{text});
                    return .none;
                };
                const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, ext });
                defer gpa.free(full);
                try self.createFile(full);
            },
        }
        return .none;
    }

    fn onInputKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        const gpa = self.app.gpa;
        switch (k.key) {
            .escape => self.mode = .normal,
            .enter => return self.submitInput(),
            .backspace => {
                while (self.input_buf.items.len > 0) {
                    const b = self.input_buf.pop().?;
                    if (b & 0xC0 != 0x80) break;
                }
            },
            .space => try self.input_buf.append(gpa, ' '),
            .paste => |s| for (s) |b| if (b >= 0x20 or b >= 0x80) try self.input_buf.append(gpa, b),
            .char => |c| {
                if (k.modifiers.ctrl) {
                    if (c == 'u') self.input_buf.clearRetainingCapacity();
                    if (c == 'c') self.mode = .normal;
                    return .none;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return .none;
                try self.input_buf.appendSlice(gpa, buf[0..n]);
            },
            else => {},
        }
        return .none;
    }

    fn onConfirmKey(self: *Model, k: zz.KeyEvent) !zz.Cmd(Msg) {
        self.mode = .normal;
        const yes = switch (k.key) {
            .char => |c| c == 'y' or c == 'Y',
            else => false,
        };
        if (!yes) return .none;
        switch (self.confirm_kind) {
            .quit => return .quit,
            .create => try self.startInput(.new_path, "New file path (.can.json or .dbc)", "untitled.can.json"),
            .delete => try self.doDelete(self.confirm_row),
            .open => if (self.confirm_path) |p| {
                const gpa = self.app.gpa;
                const copy = try gpa.dupe(u8, p);
                defer gpa.free(copy);
                try self.doOpen(copy);
            },
            .overwrite => if (self.confirm_path) |p| {
                const gpa = self.app.gpa;
                const copy = try gpa.dupe(u8, p);
                defer gpa.free(copy);
                try self.saveWith(copy, true);
            },
            .new => try self.doNew(),
        }
        return .none;
    }

    fn onKey(self: *Model, k: zz.KeyEvent) anyerror!zz.Cmd(Msg) {
        switch (self.mode) {
            .help => {
                self.mode = .normal;
                return .none;
            },
            .confirm => return self.onConfirmKey(k),
            .input => return self.onInputKey(k),
            .review => return self.onReviewKey(k),
            .place => return self.onPlaceKey(k),
            .menu => return self.onMenuKey(k),
            .draft_prompt => return self.onDraftPromptKey(k),
            .palette => return self.onPaletteKey(k),
            .welcome => return self.onWelcomeKey(k),
            .normal => {},
        }
        const chord = chordOf(k);
        const action: ?Action = if (chord) |c| self.keymap.lookup(c) else null;
        if (self.editing) {
            try self.onEditKey(k);
            return .none;
        }
        if (self.drafts.items.len > 0 and self.wouldLeave(k, action)) {
            self.pending_key = k;
            self.mode = .draft_prompt;
            return .none;
        }
        if (self.focus == .details) {
            if (try self.onFormKey(k)) return .none;
        }
        if (action) |a| return self.do(a);
        if (self.focus == .filter) return self.onFilterKey(k);
        if (self.focus == .payload) return self.onPayloadKey(k);
        switch (k.key) {
            .up => return self.do(.up),
            .down => return self.do(.down),
            .left => return self.do(.left),
            .right => return self.do(.right),
            .home => return self.do(.top),
            .end => return self.do(.bottom),
            .page_up => try self.move(-10, null),
            .page_down => try self.move(10, null),
            .enter => return self.do(.edit),
            .tab => self.stepFocus(if (k.modifiers.shift) -1 else 1),
            .escape => {
                if (self.status) |s| self.app.gpa.free(s);
                self.status = null;
            },
            else => {},
        }
        return .none;
    }

    fn chordOf(k: zz.KeyEvent) ?keymap_mod.Chord {
        const m = k.modifiers;
        return switch (k.key) {
            .char => |c| .{ .kind = .char, .n = if (c < 128) std.ascii.toLower(@intCast(c)) else c, .ctrl = m.ctrl },
            .f1 => .{ .kind = .function, .n = 1, .shift = m.shift },
            .f2 => .{ .kind = .function, .n = 2, .shift = m.shift },
            .f3 => .{ .kind = .function, .n = 3, .shift = m.shift },
            .f4 => .{ .kind = .function, .n = 4, .shift = m.shift },
            .f5 => .{ .kind = .function, .n = 5, .shift = m.shift },
            .f6 => .{ .kind = .function, .n = 6, .shift = m.shift },
            .f7 => .{ .kind = .function, .n = 7, .shift = m.shift },
            .f8 => .{ .kind = .function, .n = 8, .shift = m.shift },
            .f9 => .{ .kind = .function, .n = 9, .shift = m.shift },
            .f10 => .{ .kind = .function, .n = 10, .shift = m.shift },
            .f11 => .{ .kind = .function, .n = 11, .shift = m.shift },
            .f12 => .{ .kind = .function, .n = 12, .shift = m.shift },
            .insert => .{ .kind = .insert, .ctrl = m.ctrl, .shift = m.shift },
            .delete => .{ .kind = .delete, .ctrl = m.ctrl, .shift = m.shift },
            else => null,
        };
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) !zz.Cmd(Msg) {
        self.term_w = @intCast(ctx.width);
        self.term_h = @intCast(ctx.height);
        switch (msg) {
            .mouse => |m| return self.onMouse(m),
            .tick => {
                try self.app.tick();
                if (self.pending_open) |p| {
                    self.pending_open = null;
                    defer self.app.gpa.free(p);
                    try self.loadNow(p);
                }
                return .none;
            },
            .key => |k| {
                if (k.event_type == .release) return .none;
                return self.onKey(k);
            },
        }
    }

    // ---- view -------------------------------------------------------------

    fn fit(a: Alloc, s: []const u8, w: usize) ![]const u8 {
        if (w == 0) return "";
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var cols: usize = 0;
        var i: usize = 0;
        var has_style = false;
        while (i < s.len) {
            const b = s[i];
            if (b == 0x1b) {
                const end = escEnd(s, i);
                try out.appendSlice(a, s[i..end]);
                i = end;
                has_style = true;
                continue;
            } else if (cols >= w) {
                if (has_style) try out.appendSlice(a, "\x1b[0m");
                break;
            } else if (b < 0x20) {
                try out.append(a, ' ');
                i += 1;
            } else {
                const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
                const end = @min(i + n, s.len);
                try out.appendSlice(a, s[i..end]);
                i = end;
            }
            cols += 1;
        }
        while (cols < w) : (cols += 1) try out.append(a, ' ');
        return out.items;
    }

    fn styled(a: Alloc, text: []const u8, style: SelStyle) ![]const u8 {
        if (plain) {
            if (style == .none or text.len == 0) return text;
            const n = @min(std.unicode.utf8ByteSequenceLength(text[0]) catch 1, text.len);
            return std.fmt.allocPrint(a, "{c}{s}", .{ @as(u8, if (style == .sel) '>' else '*'), text[n..] });
        }
        return switch (style) {
            .none => text,
            .sel => std.fmt.allocPrint(a, "\x1b[30;46;1m{s}\x1b[0m", .{text}),
            .dim => std.fmt.allocPrint(a, "\x1b[2m{s}\x1b[0m", .{text}),
        };
    }

    fn signalMarker(a: Alloc, signal: usize, marker: u8) ![]const u8 {
        if (plain) return std.fmt.allocPrint(a, "{c}", .{marker});
        return std.fmt.allocPrint(a, "{s}{c}\x1b[39m", .{ signal_fg[signal % signal_fg.len], marker });
    }

    fn signalText(a: Alloc, signal: usize, text: []const u8) ![]const u8 {
        if (plain) return text;
        return std.fmt.allocPrint(a, "{s}{s}\x1b[39m", .{ signal_fg[signal % signal_fg.len], text });
    }

    fn topFor(cursor: usize, n: usize, h: usize) usize {
        if (n <= h) return 0;
        return @min(cursor -| (h / 2), n - h);
    }

    fn treeLine(self: *const Model, a: Alloc, row: Row) ![]const u8 {
        const doc = &self.app.doc;
        return switch (row.kind) {
            .bus => std.fmt.allocPrint(a, "# {s}", .{doc.buses.items[row.bus].name}),
            .category => std.fmt.allocPrint(a, "{s} {s} ({d})", .{ if (row.cat == self.tab) "-" else "+", tab_titles[@backingInt(row.cat)], self.categoryCount(row.cat) }),
            .attr => std.fmt.allocPrint(a, "  {s}", .{doc.attribute_definitions.items[row.idx].name}),
            .meta => std.fmt.allocPrint(a, "  {s}", .{meta_labels[row.idx]}),
            .node => std.fmt.allocPrint(a, "@ {s}", .{doc.nodes.items[row.node].name}),
            .table => std.fmt.allocPrint(a, "= {s} ({d})", .{ doc.value_tables.items[row.table].name, doc.value_tables.items[row.table].choices.items.len }),
            .message => blk: {
                const m = doc.messages.items[row.msg];
                break :blk std.fmt.allocPrint(a, "  {s} {s}", .{ m.id, m.name });
            },
            .signal => blk: {
                const s = doc.messages.items[row.msg].signals.items[row.sig];
                break :blk std.fmt.allocPrint(a, "      {s} [{d}|{d}]", .{ s.name, s.start_bit, s.bit_length });
            },
        };
    }

    fn pushLine(a: Alloc, out: *std.ArrayListUnmanaged(u8), line: []const u8) !void {
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, line);
    }

    /// Splits text into chunks of at most `w` columns, preferring to break at spaces.
    fn wrap(a: Alloc, text: []const u8, w: usize) ![]const []const u8 {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        const width = @max(w, 1);
        var start: usize = 0;
        while (true) {
            var i = start;
            var cols: usize = 0;
            var last_space: ?usize = null;
            while (i < text.len and cols < width) {
                if (text[i] == ' ') last_space = i;
                const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                i = @min(i + n, text.len);
                cols += 1;
            }
            var end = i;
            if (i < text.len and last_space != null and last_space.? > start) end = last_space.?;
            try lines.append(a, text[start..end]);
            start = end;
            if (start < text.len and text[start] == ' ') start += 1;
            if (start >= text.len) break;
        }
        return lines.items;
    }

    const ViewLine = struct { text: []const u8, item: ?usize };
    const indent = "                   ";

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const a = ctx.allocator;
        const W: usize = ctx.width;
        const H: usize = ctx.height;
        var out: std.ArrayListUnmanaged(u8) = .empty;

        const errs = self.app.diags.count(.@"error");
        const warns = self.app.diags.count(.warning);
        const title = try std.fmt.allocPrint(a, " can_dbz_editor  {s}{s}  [{s}]  dbc:{s}  E:{d} W:{d}", .{
            self.app.path orelse self.app.save_path orelse "(new)",
            if (self.app.isDirty()) " *" else "",
            @tagName(self.app.format),
            @tagName(self.app.dbc_mode),
            errs,
            warns,
        });
        try pushLine(a, &out, if (plain) try fit(a, title, W) else try styled(a, try fit(a, title, W), .sel));

        var strip: std.ArrayListUnmanaged(u8) = .empty;
        var vis: usize = 0;
        for (menus, 0..) |m, i| {
            const label = try std.fmt.allocPrint(a, " {s} ", .{m.title});
            const on = self.mode == .menu and i == self.menu_idx;
            try strip.appendSlice(a, try styled(a, label, if (on) .sel else .none));
            vis += label.len;
        }
        const menu_hint = try std.fmt.allocPrint(a, "   {s} menu", .{try self.chordText(a, .menu)});
        try strip.appendSlice(a, menu_hint);
        vis += menu_hint.len;
        while (vis < W) : (vis += 1) try strip.append(a, ' ');
        try pushLine(a, &out, strip.items);

        const diag_h: usize = self.drawerHeight(H);
        const main_h: usize = H -| (2 + 3 + diag_h);

        if (self.mode == .help) {
            try self.helpLines(a, &out, main_h + diag_h, W);
        } else if (self.mode == .review) {
            try self.reviewLines(a, &out, main_h + diag_h, W);
        } else if (self.mode == .welcome) {
            try self.welcomeLines(a, &out, main_h + diag_h, W);
        } else if (W < 60 or H < 18) {
            const msg = try std.fmt.allocPrint(a, "Terminal too small ({d}x{d}); need at least 60x18. Resize to continue.", .{ W, H });
            for (try wrap(a, msg, W)) |l| try pushLine(a, &out, try fit(a, l, W));
        } else {
            var body: std.ArrayListUnmanaged(u8) = .empty;
            try self.mainLines(a, &body, main_h, W, H);
            if (diag_h > 0) try self.diagLines(a, &body, diag_h, W);
            const box: ?Box = switch (self.mode) {
                .menu => try self.menuBox(a),
                .palette => try self.paletteBox(a, W, main_h + diag_h),
                else => null,
            };
            var row: usize = 0;
            var it = std.mem.splitScalar(u8, body.items, '\n');
            while (it.next()) |line| : (row += 1) {
                if (box) |b| {
                    if (row < b.lines.len and b.x + b.width <= W) {
                        try pushLine(a, &out, try overlay(a, line, b.x, b.lines[row], b.width));
                        continue;
                    }
                }
                try pushLine(a, &out, line);
            }
        }

        const focus_name = switch (self.focus) {
            .tree => "Browser",
            .filter => "Filter",
            .map => "Bit map",
            .table => "Signals",
            .payload => "Payload test",
            .details => "Inspector",
            .diags => "Problems",
        };
        const info = try std.fmt.allocPrint(a, " Focus: {s}   Problems: E{d} W{d}   {s}{s}", .{ focus_name, errs, warns, if (self.app.isDirty()) "Unsaved changes" else "Saved", if (self.drafts.items.len > 0) "   Unapplied form edits" else "" });
        try pushLine(a, &out, try fit(a, info, W));
        try pushLine(a, &out, try fit(a, try self.contextHints(a), W));
        try pushLine(a, &out, try tailFit(a, try self.statusLine(a), W));
        return out.items;
    }

    /// Keeps the end of long text (such as an input being typed) visible.
    fn tailFit(a: Alloc, s: []const u8, w: usize) ![]const u8 {
        if (s.len <= w) return fit(a, s, w);
        var start = s.len - (w -| 1);
        while (start < s.len and s[start] & 0xC0 == 0x80) start += 1;
        return fit(a, s[start..], w);
    }

    fn contextHints(self: *const Model, a: Alloc) ![]const u8 {
        switch (self.mode) {
            .input => return " Enter accept   Esc cancel   Ctrl+U clear",
            .confirm => return " y confirms; any other key cancels",
            .review => return " Up/Down scroll   Enter continue (when nothing blocks)   Esc close",
            .place => return " Arrows move   +/- resize   Enter apply   Esc cancel",
            .draft_prompt => return " A apply   D discard   C or Esc cancel",
            .menu => return " Left/Right switch menu   Up/Down choose   Enter run   Esc close",
            .palette => return " Type to filter   Up/Down choose   Enter run   ':' for a command line   Esc close",
            .welcome => return " Up/Down choose   Enter run   Esc continue without a file",
            .help => return " Any key closes help",
            .normal => {},
        }
        const add = try self.chordText(a, .add);
        const del = try self.chordText(a, .delete);
        const dup = try self.chordText(a, .duplicate);
        const pane = try self.chordText(a, .pane_next);
        const tabk = try self.chordText(a, .tab_next);
        const mv = try self.chordText(a, .move_signal);
        return switch (self.focus) {
            .tree => std.fmt.allocPrint(a, " Enter open/expand   {s} new   {s} delete   {s} duplicate   {s} filter   {s} pane", .{ add, del, dup, try self.chordText(a, .focus_filter), pane }),
            .filter => " Type to filter (bus:NAME frame:fd 0x1A0)   Enter keep   Esc clear",
            .map => std.fmt.allocPrint(a, " Arrows move cell   Enter edit or add signal   {s} move   {s} next tab   {s} pane", .{ mv, tabk, pane }),
            .table => std.fmt.allocPrint(a, " Up/Down select   Enter edit   {s} new   {s} delete   {s} duplicate   {s} move", .{ add, del, dup, mv }),
            .payload => std.fmt.allocPrint(a, " Type hex bytes   Ctrl+U clear   Up/Down scroll   {s} next tab   Esc back", .{tabk}),
            .details => if (self.insp_group == .multiplexing)
                " Conditions: Selector=1,2..4; Other=3 (AND clauses use ';', ranges use ',')"
            else if (self.editing)
                " Type the value   Enter keep as draft   Esc cancel   Ctrl+U clear"
            else
                try std.fmt.allocPrint(a, " Up/Down field   Enter edit   Left/Right tab   Delete revert   {s} apply   {s} discard   Esc back", .{ try self.chordText(a, .form_apply), try self.chordText(a, .form_discard) }),
            .diags => " Up/Down choose   Enter jump to item",
        };
    }

    fn chordText(self: *const Model, a: Alloc, action: Action) ![]const u8 {
        const chord = self.keymap.primary(action) orelse return "(unbound)";
        const buf = try a.alloc(u8, 24);
        return chord.describe(buf);
    }

    fn hintLine(self: *const Model, a: Alloc) ![]const u8 {
        return std.fmt.allocPrint(a, " {s} help   {s} command   {s} pane   {s} quit", .{
            try self.chordText(a, .help),
            try self.chordText(a, .command),
            try self.chordText(a, .pane_next),
            try self.chordText(a, .quit),
        });
    }

    fn statusLine(self: *const Model, a: Alloc) ![]const u8 {
        return switch (self.mode) {
            .input => if (self.draft_retained)
                std.fmt.allocPrint(a, "{s}: {s}_   [{s}]", .{ self.input_label, self.input_buf.items, self.status orelse "" })
            else
                std.fmt.allocPrint(a, "{s}{s}{s}_", .{ self.input_label, if (self.input_purpose == .command) "" else ": ", self.input_buf.items }),
            .confirm => std.fmt.allocPrint(a, "{s} (y/n)", .{self.confirm_text orelse ""}),
            .draft_prompt => "Unsaved form edits: (A)pply, (D)iscard or (C)ancel?",
            .place => self.placeStatus(a),
            else => self.status orelse "",
        };
    }

    const Lines = []const []const u8;

    fn appendPrint(a: Alloc, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
    }

    fn blankLines(a: Alloc, w: usize, h: usize) !Lines {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        const blank = try fit(a, "", w);
        var i: usize = 0;
        while (i < h) : (i += 1) try out.append(a, blank);
        return out.items;
    }

    /// Pads or truncates to exactly `h` lines of `w` visible columns.
    fn finish(a: Alloc, list: *std.ArrayListUnmanaged([]const u8), w: usize, h: usize) !Lines {
        const blank = try fit(a, "", w);
        while (list.items.len < h) try list.append(a, blank);
        return list.items[0..h];
    }

    fn paneBrowser(self: *const Model, a: Alloc, w: usize, h: usize) !Lines {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        if (w <= 16 and self.tab == .messages) {
            const rows = try self.compactMessages(a);
            try out.append(a, try fit(a, try std.fmt.allocPrint(a, "Messages ({d})", .{rows.len}), w));
            var cursor: usize = 0;
            var has_selected = false;
            if (self.browserRow()) |selected| {
                for (rows, 0..) |r, i| {
                    if (selected.kind == .message and r.msg == selected.msg) {
                        cursor = i;
                        has_selected = true;
                    }
                }
            }
            const list_h = h -| 1;
            const top = topFor(cursor, rows.len, list_h);
            var i: usize = 0;
            while (i < list_h and top + i < rows.len) : (i += 1) {
                const ri = top + i;
                const row = rows[ri];
                const msg = self.app.doc.messages.items[row.msg];
                const selected_row = has_selected and ri == cursor;
                const mark: u8 = if (self.focus == .tree and selected_row) '>' else ' ';
                const line = try std.fmt.allocPrint(a, "{c}{s} {s}", .{ mark, try fit(a, msg.name, 9), try fit(a, msg.id, 5) });
                try out.append(a, try styled(a, try fit(a, line, w), if (selected_row) (if (self.focus == .tree) .sel else .dim) else .none));
            }
            if (rows.len == 0) try out.append(a, try fit(a, "(no messages)", w));
            return finish(a, &out, w, h);
        }
        const filter_text = if (self.focus == .filter)
            try std.fmt.allocPrint(a, "/ {s}_", .{self.filter_buf.items})
        else if (self.filter_buf.items.len > 0)
            try std.fmt.allocPrint(a, "/ {s}", .{self.filter_buf.items})
        else
            "/ filter (F3)";
        try out.append(a, try styled(a, try fit(a, filter_text, w), if (self.focus == .filter) .sel else .none));

        const list_h = h -| 1;
        const top = topFor(self.cursor, self.rows.items.len, list_h);
        var i: usize = 0;
        while (i < list_h and top + i < self.rows.items.len) : (i += 1) {
            const ti = top + i;
            const txt = try fit(a, try self.treeLine(a, self.rows.items[ti]), w);
            const st: SelStyle = if (ti == self.cursor) (if (self.focus == .tree) .sel else .dim) else .none;
            try out.append(a, try styled(a, txt, st));
        }
        return finish(a, &out, w, h);
    }

    const InspBody = struct { dl: []const ViewLine, sel_line: usize };

    /// Wrapped inspector field lines; shared by drawing and mouse hit testing.
    fn inspectorBody(self: *const Model, a: Alloc, w: usize, row: Row) !InspBody {
        const vfs = try self.visibleFields(a, row);
        var dl: std.ArrayListUnmanaged(ViewLine) = .empty;
        var sel_line: usize = 0;
        if (row.kind == .signal) {
            const signal = self.app.doc.messages.items[row.msg].signals.items[row.sig];
            if (self.insp_group == .choices) {
                const table = signal.value_table;
                try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "Mode: {s} Inline", .{if (table == null) "(*)" else "( )"}), .item = null });
                try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "      {s} Value table", .{if (table != null) "(*)" else "( )"}), .item = null });
                if (table == null) {
                    try dl.append(a, .{ .text = "Raw        Label", .item = null });
                    for (signal.choices.items) |choice| {
                        try dl.append(a, .{ .text = try fit(a, try std.fmt.allocPrint(a, "{s: <10} {s}", .{ choice.raw, choice.label }), w), .item = null });
                    }
                }
            } else if (self.insp_group == .multiplexing) {
                for (vfs, 0..) |vf, vi| {
                    if (std.mem.eql(u8, vf.f.label, "is_multiplexer")) {
                        if (vi == self.field_cursor) sel_line = dl.items.len;
                        try appendInspectorField(self, a, &dl, w, row, vf, vi, "Is selector");
                    }
                }
                if (signal.when.items.len > 0) {
                    try dl.append(a, .{ .text = "Selector       From       To", .item = null });
                    for (signal.when.items) |condition| {
                        for (condition.ranges.items) |range| {
                            const value = try std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ condition.selector, range.minimum, range.maximum });
                            try dl.append(a, .{ .text = try fit(a, value, w), .item = null });
                        }
                    }
                }
                for (vfs, 0..) |vf, vi| {
                    if (!std.mem.eql(u8, vf.f.label, "conditions")) continue;
                    if (vi == self.field_cursor) sel_line = dl.items.len;
                    try appendInspectorField(self, a, &dl, w, row, vf, vi, "Conditions");
                }
            } else {
                for (vfs, 0..) |vf, vi| {
                    if (vi == self.field_cursor) sel_line = dl.items.len;
                    try appendInspectorField(self, a, &dl, w, row, vf, vi, vf.f.label);
                }
                if (self.insp_group == .conversion) {
                    try dl.append(a, .{ .text = "Physical value:", .item = null });
                    try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "physical = raw * {s} + {s}", .{ signal.factor, signal.offset }), .item = null });
                } else if (self.insp_group == .metadata) {
                    try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "Attributes: {d}", .{signal.attributes.items.len}), .item = null });
                    if (signal.attributes.items.len == 0) try dl.append(a, .{ .text = "(none)", .item = null });
                    for (signal.attributes.items) |assignment| {
                        try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}: {s}", .{ assignment.name, try attrValueText(a, assignment.value) }), .item = null });
                    }
                    try dl.append(a, .{ .text = if (signal.extensions != null) "Extensions: present" else "Extensions: none", .item = null });
                    try dl.append(a, .{ .text = if (signal.dbc != null) "DBC metadata: present" else "DBC metadata: none", .item = null });
                }
            }
            if (dl.items.len == 0) try dl.append(a, .{ .text = "(no fields)", .item = null });
            return .{ .dl = dl.items, .sel_line = sel_line };
        }
        for (vfs, 0..) |vf, vi| {
            if (vi == self.field_cursor) sel_line = dl.items.len;
            try appendInspectorField(self, a, &dl, w, row, vf, vi, vf.f.label);
        }
        if (vfs.len == 0) try dl.append(a, .{ .text = "(no fields)", .item = null });
        return .{ .dl = dl.items, .sel_line = sel_line };
    }

    fn appendInspectorField(self: *const Model, a: Alloc, dl: *std.ArrayListUnmanaged(ViewLine), w: usize, row: Row, vf: VField, vi: usize, label: []const u8) !void {
        const draft = if (self.formMatches(row)) self.draftAt(vf.idx) else null;
        const marker: u8 = switch (vf.f.kind) {
            .readonly => ' ',
            .cycle => '~',
            .text => '>',
        };
        const editing_here = self.editing and vi == self.field_cursor and self.focus == .details;
        const is_mux_toggle = switch (vf.f.tag) {
            .s => |tag| tag == .is_multiplexer,
            else => false,
        };
        const value: []const u8 = if (is_mux_toggle)
            if (std.mem.eql(u8, self.displayText(row, vf), "true")) "[x]" else "[ ]"
        else if (editing_here)
            try std.fmt.allocPrint(a, "{s}_", .{self.edit_buf.items})
        else
            self.displayText(row, vf);
        const prefix = try std.fmt.allocPrint(a, "{c}{c} {s}: ", .{ marker, @as(u8, if (draft != null) '*' else ' '), label });
        const body_w = @max(w -| @min(prefix.len, w -| 1), 8);
        for (try wrap(a, value, body_w), 0..) |c, ci| {
            try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}{s}", .{ if (ci == 0) prefix else try fit(a, "", prefix.len), c }), .item = vi });
        }
        if (draft) |d| {
            if (d.err) |e| {
                for (try wrap(a, e, @max(w -| 4, 8))) |c| {
                    try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "  ! {s}", .{c}), .item = vi });
                }
            }
        }
    }

    fn paneInspector(self: *const Model, a: Alloc, w: usize, h: usize) !Lines {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        const row = self.curRow() orelse {
            try out.append(a, try fit(a, "(nothing selected)", w));
            return finish(a, &out, w, h);
        };
        const fs = try self.formFields(a, row);
        const present = presentGroups(fs);
        const grp = self.activeGroup(fs);
        const matches = self.formMatches(row);
        const vfs = try self.visibleFields(a, row);
        const n = vfs.len;
        const signal_row = row.kind == .signal;
        if (signal_row) {
            try out.append(a, try fit(a, "Signal Inspector", w));
            try out.append(a, try fit(a, try std.fmt.allocPrint(a, "SIGNAL: {s}{s}", .{ self.entityName(row), if (matches and self.drafts.items.len > 0) " *" else "" }), w));
            try out.append(a, try fit(a, try std.fmt.allocPrint(a, "Section: [{s} v]", .{group_titles[@backingInt(grp)]}), w));
        } else {
            const title = try std.fmt.allocPrint(a, "{s}: {s}{s}", .{ @tagName(row.kind), self.entityName(row), if (matches and self.drafts.items.len > 0) " *" else "" });
            try out.append(a, try fit(a, title, w));

            var tabs: std.ArrayListUnmanaged(u8) = .empty;
            var shown: usize = 0;
            for (group_titles, 0..) |t, gi| {
                if (!present[gi]) continue;
                shown += 1;
                const active = gi == @backingInt(grp);
                if (w >= 48) {
                    try appendPrint(a, &tabs, "{s}{s}{s} ", .{ if (active) "[" else " ", t, if (active) "]" else " " });
                } else if (active) {
                    try appendPrint(a, &tabs, "[{s}] ", .{t});
                }
            }
            if (w < 48 and shown > 1) try tabs.appendSlice(a, "(Left/Right)");
            try out.append(a, try fit(a, tabs.items, w));
        }

        // Wrapped fields scroll by display line rather than by field.
        const body = try self.inspectorBody(a, w, row);
        const dl = body.dl;
        const sel_line = body.sel_line;

        const header_h: usize = if (signal_row) 3 else 2;
        const body_h = h -| (header_h + 2);
        const dtop = topFor(sel_line, dl.len, body_h);
        var i: usize = 0;
        while (i < body_h and dtop + i < dl.len) : (i += 1) {
            const line = dl[dtop + i];
            const st: SelStyle = if (line.item != null and line.item.? == self.field_cursor) (if (self.focus == .details) .sel else .dim) else .none;
            try out.append(a, try styled(a, try fit(a, line.text, w), st));
        }
        while (out.items.len < header_h + body_h) try out.append(a, try fit(a, "", w));

        const dirty = matches and self.drafts.items.len > 0;
        const blocked = blk: {
            if (!matches) break :blk false;
            for (self.drafts.items) |d| {
                if (d.err != null) break :blk true;
            }
            break :blk false;
        };
        try out.append(a, try fit(a, if (blocked) "  Fix the fields marked ! to apply" else if (dirty) "  Unapplied edits" else "", w));
        const apply_sel = self.focus == .details and self.field_cursor == n;
        const discard_sel = self.focus == .details and self.field_cursor == n + 1;
        var btn: std.ArrayListUnmanaged(u8) = .empty;
        try btn.appendSlice(a, "  ");
        try btn.appendSlice(a, try styled(a, "[Apply]", if (apply_sel) .sel else .none));
        try btn.appendSlice(a, "  ");
        try btn.appendSlice(a, try styled(a, "[Discard]", if (discard_sel) .sel else .none));
        var vis: usize = 2 + 7 + 2 + 9;
        while (vis < w) : (vis += 1) try btn.append(a, ' ');
        try out.append(a, btn.items);
        return finish(a, &out, w, h);
    }

    fn headerLine(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message, w: usize) ![]const u8 {
        const txt = if (w < 44) blk: {
            const suffix = try std.fmt.allocPrint(a, "{s} {s} {d}B", .{ msg.id, if (msg.frame == .fd) "FD" else "Classic", msg.length });
            const name_w = w -| (suffix.len + 1);
            break :blk try std.fmt.allocPrint(a, "{s} {s}", .{ try fit(a, msg.name, name_w), suffix });
        } else try std.fmt.allocPrint(a, "{s} | {s} | {s} | {s} | {d} bytes | {s}", .{
            msg.name,
            msg.id,
            if (msg.extended) "Extended" else "Standard",
            if (msg.frame == .fd) "FD" else "Classic",
            msg.length,
            msg.bus,
        });
        const on = self.sel_sig == 0 and (self.focus == .map or self.focus == .table);
        return styled(a, try fit(a, txt, w), if (on) .sel else .none);
    }

    /// Names of every signal that stores a bit at `bit`, comma separated.
    fn ownersAt(a: Alloc, msg: *const can_dbz.model.Message, bit: u32) ![]const u8 {
        var names: std.ArrayListUnmanaged(u8) = .empty;
        for (msg.signals.items) |*sig| {
            var it = layout.BitIter.init(sig);
            while (it.next()) |b| {
                if (b != bit) continue;
                if (names.items.len > 0) try names.appendSlice(a, ", ");
                try names.appendSlice(a, sig.name);
                break;
            }
        }
        return names.items;
    }

    fn paneMap(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message, w: usize, h: usize) !Lines {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        const nbytes: usize = msg.length;
        if (nbytes == 0) {
            try out.append(a, try fit(a, "(0-byte payload: nothing to map)", w));
            return finish(a, &out, w, h);
        }
        const occ = try layout.occupancy(a, msg);
        const mm = mapMetrics(w, h, nbytes, self.map_bit);
        const detail = mm.detail;
        const avail = mm.avail;
        const top = mm.top;
        const ncells = mm.ncells;

        var hdr: std.ArrayListUnmanaged(u8) = .empty;
        try hdr.appendSlice(a, "    ");
        var k: usize = 0;
        while (k < ncells) : (k += 1) try appendPrint(a, &hdr, " {d} ", .{7 - k});
        if (nbytes > avail) try appendPrint(a, &hdr, " B{d}-{d}/{d}", .{ top, @min(top + avail, nbytes) - 1, nbytes });
        try out.append(a, try fit(a, hdr.items, w));

        var row: usize = 0;
        while (row < avail and top + row < nbytes) : (row += 1) {
            const byte = top + row;
            var line: std.ArrayListUnmanaged(u8) = .empty;
            try appendPrint(a, &line, "B{d:0>2} ", .{byte});
            var c: usize = 0;
            while (c < ncells) : (c += 1) {
                const abs: u32 = @intCast(byte * 8 + (7 - c));
                const cell = occ.cells[abs];
                const ch: u8 = if (cell.collision) '!' else if (cell.owner == layout.no_owner) '.' else layout.marker(cell.owner);
                const at_cursor = self.focus == .map and abs == self.map_bit;
                const selected = cell.owner != layout.no_owner and @as(usize, cell.owner) + 1 == self.sel_sig;
                const txt = if (at_cursor) [3]u8{ '[', ch, ']' } else if (selected and plain) [3]u8{ '(', ch, ')' } else [3]u8{ ' ', ch, ' ' };
                const unused = cell.owner == layout.no_owner and !cell.collision;
                if (!plain) try line.appendSlice(a, if (cell.collision) "\x1b[97;41;1m" else if (at_cursor) "\x1b[30;47;1m" else if (selected) signal_selected_bg[@as(usize, cell.owner) % signal_selected_bg.len] else if (unused) "\x1b[2;37m" else signal_fg[@as(usize, cell.owner) % signal_fg.len]);
                try line.appendSlice(a, &txt);
                if (!plain) try line.appendSlice(a, "\x1b[0m");
            }
            var vis: usize = 4 + 3 * ncells;
            while (vis < w) : (vis += 1) try line.append(a, ' ');
            try out.append(a, line.items);
        }
        while (out.items.len < 1 + avail) try out.append(a, try fit(a, "", w));

        if (detail > 0) {
            const sel_txt = if (self.sel_sig > 0) blk: {
                const s = msg.signals.items[self.sel_sig - 1];
                break :blk try std.fmt.allocPrint(a, "{s} {s}  S={d} W={d} {s} {s}", .{
                    try signalMarker(a, self.sel_sig - 1, layout.marker(self.sel_sig - 1)), try signalText(a, self.sel_sig - 1, s.name), s.start_bit, s.bit_length,
                    if (s.byte_order == .little_endian) "Intel" else "Motorola",            @tagName(s.signal_type),
                });
            } else "(message selected)";
            try out.append(a, try fit(a, sel_txt, w));
            const bit: u32 = @min(self.map_bit, @as(u32, @intCast(occ.cells.len)) - 1);
            const cell = occ.cells[bit];
            const what = if (cell.collision)
                try std.fmt.allocPrint(a, "COLLISION {s}", .{try ownersAt(a, msg, bit)})
            else if (cell.owner == layout.no_owner)
                "unused"
            else
                try std.fmt.allocPrint(a, "{s} {s}", .{ try signalMarker(a, cell.owner, layout.marker(cell.owner)), try signalText(a, cell.owner, msg.signals.items[cell.owner].name) });
            try out.append(a, try fit(a, try std.fmt.allocPrint(a, "bit {d} (B{d}.{d}): {s}", .{ bit, bit / 8, bit % 8, what }), w));
            if (detail == 3) {
                var unused: usize = 0;
                for (occ.cells) |cell_| {
                    if (cell_.owner == layout.no_owner) unused += 1;
                }
                var extra: std.ArrayListUnmanaged(u8) = .empty;
                if (occ.out_of_bounds.items.len > 0) {
                    try extra.appendSlice(a, "! beyond payload: ");
                    for (occ.out_of_bounds.items, 0..) |si, n| {
                        if (n > 0) try extra.appendSlice(a, ", ");
                        try extra.appendSlice(a, msg.signals.items[si].name);
                    }
                } else try appendPrint(a, &extra, "{d} unused bits", .{unused});
                try out.append(a, try fit(a, extra.items, w));
            }
        }
        return finish(a, &out, w, h);
    }

    fn paneTable(self: *const Model, a: Alloc, msg: *const can_dbz.model.Message, w: usize, h: usize) !Lines {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        const full = w >= 50;
        const name_w: usize = if (full) 16 else @max(w -| 23, 5);
        const end_w: usize = if (full) 5 else 3;
        const start_w: usize = if (full) 5 else 4;
        const length_w: usize = if (full) 6 else 3;
        const order_w: usize = if (full) 8 else 3;
        const note_w: usize = if (full) w -| 47 else 3;
        const head = try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s} {s} {s}", .{
            try fit(a, "#", 1),
            try fit(a, "Signal", name_w),
            try fit(a, "Start", start_w),
            try fit(a, if (full) "Length" else "Len", length_w),
            try fit(a, "End", end_w),
            try fit(a, if (full) "Order" else "Ord", order_w),
            try fit(a, if (full) "Notes" else "Nts", note_w),
        });
        try out.append(a, try fit(a, head, w));
        const avail = h -| 1;
        const sigs = msg.signals.items;
        if (sigs.len == 0 and avail > 0) try out.append(a, try fit(a, "(no signals: Enter on a map cell, or press a)", w));
        const top = topFor(self.sel_sig -| 1, sigs.len, avail);
        var i: usize = 0;
        while (i < avail and top + i < sigs.len) : (i += 1) {
            const si = top + i;
            const s = sigs[si];
            var bit_iter = layout.BitIter.init(&s);
            var end_bit: ?u32 = null;
            while (bit_iter.next()) |bit| end_bit = bit;
            const start = try std.fmt.allocPrint(a, "{d}", .{s.start_bit});
            const length = try std.fmt.allocPrint(a, "{d}", .{s.bit_length});
            const end = if (end_bit) |bit| try std.fmt.allocPrint(a, "{d}", .{bit}) else "-";
            const order = if (s.byte_order == .little_endian) "Intel" else "Motorola";
            const note = s.unit orelse "-";
            const text = try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s} {s} {s}", .{
                try fit(a, try signalMarker(a, si, layout.marker(si)), 1),
                try fit(a, try signalText(a, si, s.name), name_w),
                try fit(a, start, start_w),
                try fit(a, length, length_w),
                try fit(a, end, end_w),
                try fit(a, order, order_w),
                try fit(a, note, note_w),
            });
            const st: SelStyle = if (self.sel_sig == si + 1) (if (self.focus == .table) .sel else .dim) else .none;
            try out.append(a, try styled(a, try fit(a, text, w), st));
        }
        return finish(a, &out, w, h);
    }

    const MapMetrics = struct { detail: usize, avail: usize, top: usize, ncells: usize };

    fn mapMetrics(w: usize, h: usize, nbytes: usize, map_bit: u32) MapMetrics {
        const detail: usize = if (h >= 9) 3 else if (h >= 6) 2 else 0;
        const avail = @max(h -| (1 + detail), 1);
        const cur_byte = @min(map_bit / 8, nbytes -| 1);
        return .{ .detail = detail, .avail = avail, .top = topFor(cur_byte, nbytes, avail), .ncells = @min(8, (w -| 4) / 3) };
    }

    const WsMetrics = struct { map_y: usize = 0, map_h: usize = 0, table_y: usize = 0, table_h: usize = 0 };

    /// Row offsets inside the workspace pane (rows 0 and 1 are the tab row and message header).
    fn wsMetrics(self: *const Model, h: usize, both: bool, nbytes: usize) WsMetrics {
        const rest = h -| 2;
        if (self.ws_tab != .layout) return .{};
        if (both and rest >= 12) {
            const map_h = @min(@min(4 + nbytes, @max(12, rest * 2 / 5)), rest - 4);
            return .{ .map_y = 2, .map_h = map_h, .table_y = 2 + map_h, .table_h = rest - map_h };
        }
        if (self.focus == .table) return .{ .table_y = 2, .table_h = rest };
        return .{ .map_y = 2, .map_h = rest };
    }

    const PaneKind = enum { browser, workspace, inspector };
    const PaneSlot = struct { kind: PaneKind, x: usize, w: usize };
    const PaneLayout = struct { slots: [3]PaneSlot, n: usize, stacked: bool };

    fn paneLayout(self: *const Model, W: usize, H: usize) PaneLayout {
        var p: PaneLayout = .{ .slots = undefined, .n = 0, .stacked = H >= 30 };
        const has_ws = self.tab == .messages and self.curMsg() != null;
        const add = struct {
            fn f(l: *PaneLayout, kind: PaneKind, x: usize, w: usize) void {
                l.slots[l.n] = .{ .kind = kind, .x = x, .w = w };
                l.n += 1;
            }
        }.f;
        if (W >= 110) {
            const lw: usize = if (W >= 140) 28 else 22;
            const iw: usize = if (W >= 140) 40 else 32;
            add(&p, .browser, 0, lw);
            if (has_ws) {
                const ww = W - lw - iw - 2;
                add(&p, .workspace, lw + 1, ww);
                add(&p, .inspector, lw + ww + 2, iw);
            } else {
                add(&p, .inspector, lw + 1, W - lw - 1);
            }
        } else if (W >= 90) {
            const lw: usize = 24;
            add(&p, .browser, 0, lw);
            add(&p, if (has_ws and self.focus != .details) .workspace else .inspector, lw + 1, W - lw - 1);
        } else if (W >= 80 and H >= 24) {
            const lw: usize = 16;
            const iw: usize = 27;
            add(&p, .browser, 0, lw);
            if (has_ws) {
                const ww = W - lw - iw - 2;
                add(&p, .workspace, lw + 1, ww);
                add(&p, .inspector, lw + ww + 2, iw);
            } else {
                add(&p, .inspector, lw + 1, W - lw - 1);
            }
        } else {
            const kind: PaneKind = switch (self.focus) {
                .map, .table, .payload => if (has_ws) .workspace else .browser,
                .details => .inspector,
                .tree, .filter, .diags => .browser,
            };
            add(&p, kind, 0, W);
        }
        return p;
    }

    fn paneFrame(self: *const Model, a: Alloc, kind: PaneKind, w: usize, h: usize, content: Lines) !Lines {
        if (w < 3 or h < 3) return content;
        const double = kind == .workspace and !plain;
        const top_left = if (plain) "+" else if (double) "╔" else "┌";
        const top_right = if (plain) "+" else if (double) "╗" else "┐";
        const bottom_left = if (plain) "+" else if (double) "╚" else "└";
        const bottom_right = if (plain) "+" else if (double) "╝" else "┘";
        const horizontal = if (plain) "-" else if (double) "═" else "─";
        const vertical = if (plain) "|" else if (double) "║" else "│";
        const title: []const u8 = switch (kind) {
            .browser => " Browser ",
            .workspace => switch (self.ws_tab) {
                .layout => " Layout + Signals ",
                .payload => " Payload test ",
                .mux => " Multiplexing ",
            },
            .inspector => " Signal Inspector ",
        };
        const label = title[0..@min(title.len, w - 2)];
        const spare = w - 2 - label.len;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var top: std.ArrayListUnmanaged(u8) = .empty;
        if (!plain) try top.appendSlice(a, "\x1b[38;5;110m");
        try top.appendSlice(a, top_left);
        for (0..spare / 2) |_| try top.appendSlice(a, horizontal);
        try top.appendSlice(a, label);
        for (0..spare - spare / 2) |_| try top.appendSlice(a, horizontal);
        try top.appendSlice(a, top_right);
        if (!plain) try top.appendSlice(a, "\x1b[0m");
        try out.append(a, top.items);

        for (content, 0..) |line, i| {
            var framed: std.ArrayListUnmanaged(u8) = .empty;
            if (!plain) try framed.appendSlice(a, "\x1b[38;5;110m");
            try framed.appendSlice(a, vertical);
            try framed.appendSlice(a, line);
            try framed.appendSlice(a, vertical);
            if (!plain) try framed.appendSlice(a, "\x1b[0m");
            try out.append(a, framed.items);
            if (i + 1 == h - 2) break;
        }

        var bottom: std.ArrayListUnmanaged(u8) = .empty;
        if (!plain) try bottom.appendSlice(a, "\x1b[38;5;110m");
        try bottom.appendSlice(a, bottom_left);
        for (0..w - 2) |_| try bottom.appendSlice(a, horizontal);
        try bottom.appendSlice(a, bottom_right);
        if (!plain) try bottom.appendSlice(a, "\x1b[0m");
        try out.append(a, bottom.items);
        return out.items;
    }

    fn paneWorkspace(self: *const Model, a: Alloc, w: usize, h: usize, both: bool) !Lines {
        const msg = self.curMsg() orelse return blankLines(a, w, h);
        const shown = if (self.mode == .place and self.sel_sig > 0) try self.candidate(a, msg) else msg;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        try out.append(a, try self.paneTabRow(a, w));
        try out.append(a, try self.headerLine(a, shown, w));
        const rest = h -| 2;
        const wm = self.wsMetrics(h, both, shown.length);
        switch (self.ws_tab) {
            .payload => try out.appendSlice(a, try self.payloadPane(a, shown, w, rest)),
            .mux => try out.appendSlice(a, try self.muxPane(a, shown, w, rest)),
            .layout => {
                if (wm.map_h > 0) try out.appendSlice(a, try self.paneMap(a, shown, w, wm.map_h));
                if (wm.table_h > 0) try out.appendSlice(a, try self.paneTable(a, shown, w, wm.table_h));
            },
        }
        return finish(a, &out, w, h);
    }

    fn mainLines(self: *const Model, a: Alloc, out: *std.ArrayListUnmanaged(u8), h: usize, W: usize, H: usize) !void {
        const lay = self.paneLayout(W, H);
        var panes: [3]Lines = undefined;
        for (lay.slots[0..lay.n], 0..) |s, i| {
            const inner_w = s.w -| 2;
            const inner_h = h -| 2;
            const content: Lines = switch (s.kind) {
                .browser => try self.paneBrowser(a, inner_w, inner_h),
                .workspace => try self.paneWorkspace(a, inner_w, inner_h, lay.stacked and lay.n > 1),
                .inspector => try self.paneInspector(a, inner_w, inner_h),
            };
            panes[i] = try self.paneFrame(a, s.kind, s.w, h, content);
        }

        var i: usize = 0;
        while (i < h) : (i += 1) {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            for (panes[0..lay.n], 0..) |p, pi| {
                if (pi > 0) try line.append(a, ' ');
                try line.appendSlice(a, p[i]);
            }
            try pushLine(a, out, line.items);
        }
    }

    fn diagLines(self: *const Model, a: Alloc, out: *std.ArrayListUnmanaged(u8), h: usize, W: usize) !void {
        const items = self.app.diags.items.items;
        const head = try std.fmt.allocPrint(a, "-- Diagnostics ({d}) --", .{items.len});
        try pushLine(a, out, try fit(a, head, W));
        const rows = h - 1;

        var dl: std.ArrayListUnmanaged(ViewLine) = .empty;
        var sel_line: usize = 0;
        var n: usize = 0;
        while (self.orderedDiag(n)) |idx| : (n += 1) {
            const d = items[idx];
            const grp = switch (d.group) {
                .parse => "parse",
                .validation => "valid",
                .export_dbc => "export",
            };
            var where: []const u8 = "";
            if (d.message) |m| where = try std.fmt.allocPrint(a, " {s}{s}{s}", .{ m, if (d.signal != null) "/" else "", d.signal orelse "" });
            const txt = try std.fmt.allocPrint(a, "[{s}] {s}{s}: {s}", .{ grp, @tagName(d.severity), where, d.text });
            if (n == self.diag_cursor) sel_line = dl.items.len;
            for (try wrap(a, txt, W -| 2), 0..) |c, ci| {
                try dl.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}{s}", .{ if (ci == 0) "" else "  ", c }), .item = n });
            }
        }

        const top = topFor(sel_line, dl.items.len, rows);
        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const li = top + i;
            if (li >= dl.items.len) {
                try pushLine(a, out, try fit(a, "", W));
                continue;
            }
            const line = dl.items[li];
            const st: SelStyle = if (line.item.? == self.diag_cursor) (if (self.focus == .diags) .sel else .dim) else .none;
            try pushLine(a, out, try styled(a, try fit(a, line.text, W), st));
        }
    }

    fn helpLines(self: *const Model, a: Alloc, out: *std.ArrayListUnmanaged(u8), h: usize, W: usize) !void {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(a, "Keys (press any key to close)");
        try lines.append(a, "");
        inline for (comptime std.meta.fieldNames(Action), 0..) |fname, fi| {
            const act: Action = @fromBackingInt(@intCast(fi));
            if (self.keymap.primary(act)) |chord| {
                var buf: [24]u8 = undefined;
                try lines.append(a, try std.fmt.allocPrint(a, "  {s: <12} {s}", .{ chord.describe(&buf), fname }));
            }
        }
        try lines.append(a, "  Arrows, Home/End, PgUp/PgDn move; Enter edits or activates; Esc cancels; Tab/Shift+Tab change pane.");
        try lines.append(a, "Panes (Messages tab): browser, bit map, signal table, inspector. Map: arrows move the cell cursor;");
        try lines.append(a, "  Enter edits the owning signal, or adds one at an unused bit.");
        try lines.append(a, "Commands (F9): open PATH, save [PATH], export [PATH], validate, compact, undo, redo, new, payload, move,");
        try lines.append(a, "  mode strict|preserve, add bus|message|signal|node|table NAME, help, quit");
        try lines.append(a, "Mouse: click rows, map cells, tabs, menu titles and buttons; wheel scrolls the pane under the pointer.");
        try lines.append(a, "  To select text with the terminal, hold Shift (most terminals) or start with --no-mouse.");
        try lines.append(a, "Remap in ~/.config/can_dbz_editor/keys.conf or $CAN_DBZ_EDITOR_KEYS: action = ctrl+o, f2, shift+f2, insert");
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const line = if (i < lines.items.len) lines.items[i] else "";
            try pushLine(a, out, try fit(a, line, W));
        }
    }
};

test "panes fill every reference size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "BatteryStatus");
    inline for (.{ .{ "Voltage", "0", "16" }, .{ "SOC", "32", "8" } }) |d| {
        const si = try ops.addSignal(&m.app.doc, mi, d[0]);
        try ops.setSignalField(&m.app.doc, mi, si, .start_bit, d[1]);
        try ops.setSignalField(&m.app.doc, mi, si, .bit_length, d[2]);
    }
    try m.rebuildRows();
    m.cursor = 2;
    const sizes = [_][2]usize{ .{ 160, 50 }, .{ 120, 36 }, .{ 100, 30 }, .{ 80, 24 }, .{ 60, 18 } };
    for (sizes) |sz| {
        inline for (.{ Focus.tree, Focus.map, Focus.table, Focus.details }) |f| {
            m.focus = f;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            const main_h = sz[1] - 6;
            try m.mainLines(a, &out, main_h, sz[0], sz[1]);
            try std.testing.expectEqual(main_h, std.mem.count(u8, out.items, "\n") + 1);
        }
    }
    m.focus = .map;
    m.sel_sig = 1;
    var colored: std.ArrayListUnmanaged(u8) = .empty;
    try m.mainLines(a, &colored, 30, 120, 36);
    try std.testing.expect(std.mem.indexOf(u8, colored.items, "\x1b[1;91m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.items, "\x1b[30;101;1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.items, "\x1b[38;5;110m╔") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.items, "\x1b[38;5;110m┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.items, "Signal Inspector") != null);
}

test "undo keeps the selected message when indices shift" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    _ = try ops.addMessage(&m.app.doc, "can0", "A");
    _ = try ops.addMessage(&m.app.doc, "can0", "B");
    try m.app.beginEdit();
    ops.deleteMessage(&m.app.doc, 0);
    m.app.endEdit();
    try m.rebuildRows();
    m.selectRow(.{ .kind = .message, .bus = 0, .msg = 0 });
    try m.stepHistory(false);
    const r = m.browserRow().?;
    try std.testing.expectEqualStrings("B", m.app.doc.messages.items[r.msg].name);
}

test "an edit that adds validation errors is rejected and leaves the document unchanged" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "M");
    const si = try ops.addSignal(&m.app.doc, mi, "S");
    const row: Row = .{ .kind = .signal, .bus = 0, .msg = mi, .sig = si };
    try std.testing.expect(!try m.applyTag(row, .{ .s = .start_bit }, "60"));
    try std.testing.expectEqual(@as(u16, 0), m.app.doc.messages.items[mi].signals.items[si].start_bit);
    try std.testing.expect(!m.app.isDirty());
    try std.testing.expect(try m.applyTag(row, .{ .s = .start_bit }, "8"));
    try std.testing.expectEqual(@as(u16, 8), m.app.doc.messages.items[mi].signals.items[si].start_bit);
    try std.testing.expect(m.app.isDirty());
}

test "payload test renders decoded rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "M");
    const si = try ops.addSignal(&m.app.doc, mi, "S");
    try ops.setSignalField(&m.app.doc, mi, si, .bit_length, "8");
    try ops.setMessageField(&m.app.doc, mi, .length, "1");
    try m.rebuildRows();
    m.cursor = 2;
    try m.payload_buf.appendSlice(std.testing.allocator, "2A");
    m.ws_tab = .payload;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try m.mainLines(a, &out, 20, 100, 30);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "42") != null);
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, out.items, "\n") + 1);
}

test "placement mode rejects collisions and applies a free position" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "M");
    inline for (.{ .{ "A", "0" }, .{ "B", "8" } }) |d| {
        const si = try ops.addSignal(&m.app.doc, mi, d[0]);
        try ops.setSignalField(&m.app.doc, mi, si, .start_bit, d[1]);
    }
    try m.rebuildRows();
    m.cursor = 2;
    m.focus = .map;
    m.selectSig(2);
    try m.startPlacement();
    try std.testing.expect(m.mode == .place);

    m.place_start = 4;
    try m.commitPlacement();
    try std.testing.expect(m.mode == .place);
    try std.testing.expectEqual(@as(u16, 8), m.app.doc.messages.items[mi].signals.items[1].start_bit);
    try std.testing.expect(!m.app.isDirty());

    m.place_start = 16;
    try m.commitPlacement();
    try std.testing.expect(m.mode == .normal);
    try std.testing.expectEqual(@as(u16, 16), m.app.doc.messages.items[mi].signals.items[1].start_bit);
    try std.testing.expect(m.app.isDirty());
}

test "plain mode marks selection without escape sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    plain = true;
    defer plain = false;
    const s = try Model.styled(arena.allocator(), "  0x100 Msg", .sel);
    try std.testing.expectEqualStrings(">  0x100 Msg"[0..0] ++ ">", s[0..1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, s, 0x1b) == null);
}

test "color styles signals and borders while plain mode stays uncolored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = try Model.signalMarker(a, 0, 'A');
    try std.testing.expectEqualStrings("\x1b[1;91mA\x1b[39m", marker);
    const selected = try Model.styled(a, "selected", .sel);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\x1b[30;46;1m") != null);
    const fitted = try Model.fit(a, "\x1b[31mABC\x1b[0m", 3);
    try std.testing.expectEqualStrings("\x1b[31mABC\x1b[0m", fitted);
    const body = [_][]const u8{"xy"};
    const box = try Model.boxed(a, 4, &body);
    try std.testing.expectEqualStrings("\x1b[36m┌──┐\x1b[0m", box[0]);

    plain = true;
    defer plain = false;
    try std.testing.expectEqualStrings("A", try Model.signalMarker(a, 0, 'A'));
    const plain_box = try Model.boxed(a, 4, &body);
    try std.testing.expectEqualStrings("+--+", plain_box[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain_box[1], 0x1b) == null);
}

test "spec chords reach their actions and plain letters do nothing" {
    const km: keymap_mod.Keymap = .{};
    const ctrl_o = Model.chordOf(.{ .key = .{ .char = 'O' }, .modifiers = .{ .ctrl = true } }).?;
    try std.testing.expectEqual(Action.open, km.lookup(ctrl_o).?);
    const shift_f2 = Model.chordOf(.{ .key = .f2, .modifiers = .{ .shift = true } }).?;
    try std.testing.expectEqual(Action.pane_prev, km.lookup(shift_f2).?);
    const letter = Model.chordOf(.{ .key = .{ .char = 'a' } }).?;
    try std.testing.expect(km.lookup(letter) == null);
}

test "duplicate and new document" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    _ = try ops.addMessage(&m.app.doc, "can0", "A");
    try m.rebuildRows();
    m.cursor = 2;
    try m.duplicateSelected();
    try std.testing.expectEqual(@as(usize, 2), m.app.doc.messages.items.len);
    try std.testing.expect(m.app.isDirty());
    try m.doNew();
    try std.testing.expectEqual(@as(usize, 0), m.app.doc.messages.items.len);
    try std.testing.expect(!m.app.isDirty());
}

test "browser lists categories, expands one at a time and filters messages" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    _ = try ops.addMessage(&m.app.doc, "can0", "Engine");
    _ = try ops.addMessage(&m.app.doc, "can0", "Brakes");
    _ = try ops.addNode(&m.app.doc, "ECU");
    try m.rebuildRows();
    // 5 categories + bus + 2 messages
    try std.testing.expectEqual(@as(usize, 8), m.rows.items.len);
    try m.expandCategory(.nodes);
    try std.testing.expectEqual(@as(usize, 6), m.rows.items.len);
    try m.expandCategory(.messages);
    try m.filter_buf.appendSlice(std.testing.allocator, "brak");
    try m.rebuildRows();
    try std.testing.expectEqual(@as(usize, 7), m.rows.items.len);
    m.filter_buf.clearRetainingCapacity();
    try m.filter_buf.appendSlice(std.testing.allocator, "0x101");
    try m.rebuildRows();
    try std.testing.expectEqual(@as(usize, 7), m.rows.items.len);
    m.filter_buf.clearRetainingCapacity();
    try m.filter_buf.appendSlice(std.testing.allocator, "frame:fd");
    try m.rebuildRows();
    try std.testing.expectEqual(@as(usize, 5), m.rows.items.len);
}

test "menu runs the chosen action and the view renders every mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    _ = try m.do(.menu);
    try std.testing.expect(m.mode == .menu);
    _ = try m.onMenuKey(.{ .key = .right });
    _ = try m.onMenuKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), m.menu_idx);
    try std.testing.expectEqual(@as(usize, 1), m.menu_item);
    const box = try m.menuBox(arena.allocator());
    try std.testing.expectEqual(@as(usize, 6), box.x);
    var found = false;
    for (box.lines) |l| {
        if (std.mem.indexOf(u8, l, "Redo") != null) found = true;
    }
    try std.testing.expect(found);
    _ = try m.onMenuKey(.{ .key = .escape });
    try std.testing.expect(m.mode == .normal);
}

test "overlay replaces columns and keeps surrounding text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Model.overlay(a, "0123456789", 2, "ab", 2);
    try std.testing.expectEqualStrings("01\x1b[0mab456789", s);
    const styled_base = try Model.overlay(a, "\x1b[7m0123456789\x1b[0m", 3, "X", 1);
    try std.testing.expect(std.mem.indexOf(u8, styled_base, "012") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled_base, "456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled_base, "3") == null);
}

test "palette filters entries and runs the chosen one; welcome offers open and new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    _ = try m.do(.command);
    try std.testing.expect(m.mode == .palette);
    for ("payl") |c| _ = try m.onPaletteKey(.{ .key = .{ .char = c } });
    const matches = try m.paletteEntries(a);
    try std.testing.expect(matches.len >= 2);
    _ = try m.onPaletteKey(.{ .key = .escape });
    try std.testing.expect(m.mode == .normal);

    _ = try m.do(.command);
    for ("go to: nod") |c| {
        _ = if (c == ' ') try m.onPaletteKey(.{ .key = .space }) else try m.onPaletteKey(.{ .key = .{ .char = c } });
    }
    _ = try m.onPaletteKey(.{ .key = .enter });
    try std.testing.expect(m.tab == .nodes);

    try m.promptCreate();
    try std.testing.expect(m.mode == .welcome);
    _ = try m.onWelcomeKey(.{ .key = .down });
    _ = try m.onWelcomeKey(.{ .key = .enter });
    try std.testing.expect(m.mode == .input);
    try std.testing.expect(m.input_purpose == .new_path);
}

test "opening a file is deferred to the next tick" {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    defer m.deinit();
    try m.doOpen("does-not-exist.can.json");
    try std.testing.expect(m.pending_open != null);
    try std.testing.expect(std.mem.indexOf(u8, m.status.?, "Loading") != null);
}

test "tailFit keeps the end of long input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try Model.tailFit(arena.allocator(), "0123456789", 5);
    try std.testing.expectEqualStrings("6789 ", s);
}

fn fieldIndex(m: *const Model, a: Alloc, row: Row, label: []const u8) !usize {
    const fs = try m.formFields(a, row);
    for (fs, 0..) |f, i| {
        if (std.mem.eql(u8, f.label, label)) return i;
    }
    return error.NoSuchField;
}

fn formModel() !Model {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    errdefer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "M");
    _ = try ops.addSignal(&m.app.doc, mi, "A");
    _ = try ops.addSignal(&m.app.doc, mi, "B");
    try m.rebuildRows();
    m.cursor = 2;
    m.focus = .table;
    m.selectSig(1);
    return m;
}

test "form drafts are validated, applied together as one undo step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    const row = m.curRow().?;
    try std.testing.expect(row.kind == .signal);

    var fs = try m.formFields(a, row);
    var idx = try fieldIndex(&m, a, row, "start_bit");
    try m.setDraft(row, idx, fs[idx], "999");
    try std.testing.expect(m.drafts.items[0].err != null);
    try std.testing.expect(!try m.applyDrafts());
    try std.testing.expect(!m.app.isDirty());

    fs = try m.formFields(a, row);
    idx = try fieldIndex(&m, a, row, "start_bit");
    try m.setDraft(row, idx, fs[idx], "16");
    try std.testing.expect(m.drafts.items[0].err == null);
    fs = try m.formFields(a, row);
    idx = try fieldIndex(&m, a, row, "name");
    try m.setDraft(row, idx, fs[idx], "Renamed");
    try std.testing.expectEqual(@as(usize, 2), m.drafts.items.len);
    const undo_before = m.app.undo_stack.items.len;
    try std.testing.expect(try m.applyDrafts());
    try std.testing.expectEqual(undo_before + 1, m.app.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.drafts.items.len);
    const sig = m.app.doc.messages.items[0].signals.items[0];
    try std.testing.expectEqualStrings("Renamed", sig.name);
    try std.testing.expectEqual(@as(u16, 16), sig.start_bit);
}

test "compact three-pane reference renders section-specific signal inspectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    m.term_w = 80;
    m.term_h = 36;
    m.focus = .table;
    const groups = [_]Group{ .conversion, .choices, .multiplexing, .metadata };
    const expected = [_][]const u8{
        "Signal Inspector",
        "Section: [Choices v]",
        "Is selector:",
        "Attributes:",
    };
    for (groups, 0..) |group, i| {
        m.insp_group = group;
        var screen: std.ArrayListUnmanaged(u8) = .empty;
        try m.mainLines(a, &screen, 31, 80, 36);
        try std.testing.expect(std.mem.indexOf(u8, screen.items, "SIGNAL: A") != null);
        if (i == 0) try std.testing.expect(std.mem.indexOf(u8, screen.items, "physical = raw *") != null);
        if (i == 1) try std.testing.expect(std.mem.indexOf(u8, screen.items, "Mode: (*) Inline") != null);
        if (i == 2) try std.testing.expect(std.mem.indexOf(u8, screen.items, "Conditions:") != null);
        if (i == 3) try std.testing.expect(std.mem.indexOf(u8, screen.items, expected[i]) != null);
    }
    const panes = m.paneLayout(80, 36);
    try std.testing.expectEqual(@as(usize, 3), panes.n);
    try std.testing.expectEqual(@as(usize, 16), panes.slots[0].w);
    try std.testing.expectEqual(@as(usize, 27), panes.slots[2].w);
}

test "reverting to the current value removes the draft" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    const row = m.curRow().?;
    var fs = try m.formFields(a, row);
    const idx = try fieldIndex(&m, a, row, "unit");
    try m.setDraft(row, idx, fs[idx], "V");
    try std.testing.expectEqual(@as(usize, 1), m.drafts.items.len);
    fs = try m.formFields(a, row);
    try m.setDraft(row, idx, fs[idx], "");
    try std.testing.expectEqual(@as(usize, 0), m.drafts.items.len);
    try std.testing.expect(m.form_row == null);
}

test "leaving with unapplied edits asks first and replays the key after Discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    const row = m.curRow().?;
    const fs = try m.formFields(a, row);
    const idx = try fieldIndex(&m, a, row, "unit");
    try m.setDraft(row, idx, fs[idx], "V");
    try std.testing.expectEqual(@as(usize, 1), m.sel_sig);
    _ = try m.onKey(.{ .key = .down });
    try std.testing.expect(m.mode == .draft_prompt);
    try std.testing.expectEqual(@as(usize, 1), m.sel_sig);
    _ = try m.onKey(.{ .key = .{ .char = 'd' } });
    try std.testing.expect(m.mode == .normal);
    try std.testing.expectEqual(@as(usize, 0), m.drafts.items.len);
    try std.testing.expectEqual(@as(usize, 2), m.sel_sig);
}

test "cycle fields step through their options as drafts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    m.focus = .details;
    const row = m.curRow().?;
    const idx = try fieldIndex(&m, a, row, "byte_order");
    const vfs = try m.visibleFields(a, row);
    for (vfs, 0..) |vf, vi| {
        if (vf.idx == idx) m.field_cursor = vi;
    }
    _ = try m.onKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("big_endian", m.drafts.items[0].text);
}

test "multiplexer conditions can be drafted, validated, applied and viewed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try formModel();
    defer m.deinit();
    const msg_index = 0;
    try ops.setSignalField(&m.app.doc, msg_index, 0, .name, "Page");
    try ops.setSignalField(&m.app.doc, msg_index, 1, .name, "Mode");
    try ops.setSignalField(&m.app.doc, msg_index, 0, .is_multiplexer, "true");
    try ops.setSignalField(&m.app.doc, msg_index, 1, .is_multiplexer, "true");
    const target = try ops.addSignal(&m.app.doc, msg_index, "Temperature");
    m.selectSig(target + 1);
    const row = m.curRow().?;
    const fs = try m.formFields(a, row);
    const idx = try fieldIndex(&m, a, row, "conditions");
    try std.testing.expectEqual(Group.multiplexing, fs[idx].group);
    try m.setDraft(row, idx, fs[idx], "Missing=1");
    try std.testing.expect(m.drafts.items[0].err != null);
    try std.testing.expect(!try m.applyDrafts());

    try m.setDraft(row, idx, fs[idx], "Page=1, 2..4; Mode=3");
    try std.testing.expectEqualStrings("", m.drafts.items[0].err orelse "");
    try std.testing.expect(try m.applyDrafts());
    const sig = &m.app.doc.messages.items[msg_index].signals.items[target];
    try std.testing.expectEqual(@as(usize, 2), sig.when.items.len);
    try std.testing.expectEqualStrings("Page=1, 2..4; Mode=3", try ops.formatMuxConditions(a, sig.when.items));

    const mux_lines = try m.muxPane(a, &m.app.doc.messages.items[msg_index], 80, 8);
    const rendered = try std.mem.join(a, "\n", mux_lines);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Temperature: active when Page = 1,2..4 AND Mode = 3") != null);
}

fn click(x: u16, y: u16) zz.MouseEvent {
    return .{ .x = x, .y = y, .button = .left, .event_type = .press };
}

fn mouseModel() !Model {
    var m: Model = .{ .app = try App.init(std.testing.allocator, undefined) };
    errdefer m.deinit();
    const mi = try ops.addMessage(&m.app.doc, "can0", "M");
    _ = try ops.addSignal(&m.app.doc, mi, "A");
    _ = try ops.addSignal(&m.app.doc, mi, "B");
    try m.rebuildRows();
    m.term_w = 120;
    m.term_h = 36;
    return m;
}

test "mouse selects browser rows, map cells and table rows" {
    var m = try mouseModel();
    defer m.deinit();
    // The browser frame adds one row and column before its content.
    _ = try m.onMouse(click(2, 6));
    try std.testing.expectEqual(@as(usize, 2), m.cursor);
    try std.testing.expect(m.focus == .tree);
    // The workspace frame adds one row and column before its content.
    _ = try m.onMouse(click(29, 7));
    try std.testing.expect(m.focus == .map);
    try std.testing.expectEqual(@as(u32, 15), m.map_bit);
    try std.testing.expectEqual(@as(usize, 2), m.sel_sig);
    // The table header and first row move down with the workspace frame.
    _ = try m.onMouse(click(31, 18));
    try std.testing.expect(m.focus == .table);
    try std.testing.expectEqual(@as(usize, 1), m.sel_sig);
}

test "mouse hits the menu bar, workspace tabs and inspector buttons" {
    var m = try mouseModel();
    defer m.deinit();
    _ = try m.onMouse(click(2, 6));
    _ = try m.onMouse(click(8, 1));
    try std.testing.expect(m.mode == .menu);
    try std.testing.expectEqual(@as(usize, 1), m.menu_idx);
    _ = try m.onMouse(click(100, 30));
    try std.testing.expect(m.mode == .normal);
    // The framed workspace tab row is y=3.
    _ = try m.onMouse(click(34, 3));
    try std.testing.expect(m.ws_tab == .payload);
}

test "mouse clicks with unapplied edits ask first and replay after Discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try mouseModel();
    defer m.deinit();
    _ = try m.onMouse(click(2, 6));
    m.focus = .table;
    m.selectSig(1);
    const row = m.curRow().?;
    const fs = try m.formFields(a, row);
    const idx = try fieldIndex(&m, a, row, "unit");
    try m.setDraft(row, idx, fs[idx], "V");
    _ = try m.onMouse(click(31, 19));
    try std.testing.expect(m.mode == .draft_prompt);
    try std.testing.expectEqual(@as(usize, 1), m.sel_sig);
    _ = try m.onKey(.{ .key = .{ .char = 'd' } });
    try std.testing.expectEqual(@as(usize, 2), m.sel_sig);
    try std.testing.expectEqual(@as(usize, 0), m.drafts.items.len);
}

test "wheel moves the selection of the pane under the pointer" {
    var m = try mouseModel();
    defer m.deinit();
    _ = try m.onMouse(click(2, 6));
    _ = try m.onMouse(.{ .x = 31, .y = 18, .button = .wheel_down, .event_type = .press });
    try std.testing.expect(m.focus == .table);
    try std.testing.expectEqual(@as(usize, 1), m.sel_sig);
}

test "inspector shows its Apply and Discard buttons at every size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try mouseModel();
    defer m.deinit();
    _ = try m.onMouse(click(2, 6));
    const sizes = [_][2]usize{ .{ 160, 50 }, .{ 120, 36 }, .{ 100, 30 }, .{ 80, 24 }, .{ 60, 18 } };
    for (sizes) |sz| {
        m.focus = .details;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try m.mainLines(a, &out, sz[1] - 5, sz[0], sz[1]);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "[Apply]") != null);
    }
}
