const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.tidepool);
const cs = @import("compositor_state.zig");

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const TagInfo = struct {
    focused: bool = false,
    occupied: bool = false,
};

pub const WindowInfo = struct {
    wid: u32 = 0,
    app_id: [128]u8 = undefined,
    app_id_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    tag: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    focused: bool = false,
    float: bool = false,
    fullscreen: bool = false,
    visible: bool = false,
    row: u8 = 0,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    // Layout metadata (from scroll/grid layouts)
    column: u8 = 0,
    column_total: u8 = 0,
    row_in_col: u8 = 0,
    row_in_col_total: u8 = 0,

    pub fn getAppId(self: *const WindowInfo) []const u8 {
        return self.app_id[0..self.app_id_len];
    }
    pub fn getTitle(self: *const WindowInfo) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn getLayout(self: *const WindowInfo) []const u8 {
        return self.layout[0..self.layout_len];
    }
};

pub const SignalEvent = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    pending: bool = false,

    pub fn getName(self: *const SignalEvent) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn consume(self: *SignalEvent) ?[]const u8 {
        if (!self.pending) return null;
        self.pending = false;
        return self.name[0..self.name_len];
    }
};

pub const OutputInfo = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    tags: [11]TagInfo = [_]TagInfo{.{}} ** 11,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    active_row: u8 = 0,
    focused: bool = false,
    // Viewport context (from layout topic)
    usable_x: i32 = 0,
    usable_y: i32 = 0,
    usable_w: i32 = 0,
    usable_h: i32 = 0,
    scroll_offset: f32 = 0,
    total_content_w: f32 = 0,
    column_widths: [32]f32 = [_]f32{0} ** 32,
    column_count: usize = 0,

    pub fn getLayout(self: *const OutputInfo) []const u8 {
        return self.layout[0..self.layout_len];
    }
};

pub const TidepoolState = struct {
    // Per-output state (up to 8 outputs)
    outputs: [8]OutputInfo = [_]OutputInfo{.{}} ** 8,
    output_count: usize = 0,
    // Legacy flat accessors (focused output's data)
    tags: [11]TagInfo = [_]TagInfo{.{}} ** 11,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    app_id: [128]u8 = undefined,
    app_id_len: usize = 0,
    // Windows
    windows: [64]WindowInfo = [_]WindowInfo{.{}} ** 64,
    window_count: usize = 0,
    windows_changed: bool = false,
    signal: SignalEvent = .{},
    connected: bool = false,

    pub fn getLayout(self: *const TidepoolState) []const u8 {
        return self.layout[0..self.layout_len];
    }

    pub fn getTitle(self: *const TidepoolState) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getAppId(self: *const TidepoolState) []const u8 {
        return self.app_id[0..self.app_id_len];
    }

    /// Find the output matching a given position, or the focused output.
    pub fn getOutput(self: *const TidepoolState, x: i32, y: i32) ?*const OutputInfo {
        for (self.outputs[0..self.output_count]) |*o| {
            if (o.x == x and o.y == y) return o;
        }
        return null;
    }

    pub fn getFocusedOutput(self: *const TidepoolState) ?*const OutputInfo {
        for (self.outputs[0..self.output_count]) |*o| {
            if (o.focused) return o;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Netrepl framing protocol
// ---------------------------------------------------------------------------

fn sendMsg(fd: posix.fd_t, payload: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .little);
    // Write header
    var written: usize = 0;
    while (written < 4) {
        const n = posix.write(fd, hdr[written..]) catch |err| return err;
        written += n;
    }
    // Write payload
    written = 0;
    while (written < payload.len) {
        const n = posix.write(fd, payload[written..]) catch |err| return err;
        written += n;
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const TidepoolClient = struct {
    state: TidepoolState = .{},
    socket_fd: ?posix.fd_t = null,
    recv_buf: [16384]u8 = undefined,
    recv_pos: usize = 0,
    allocator: std.mem.Allocator,
    last_restart_ns: i128 = 0,
    handshake_done: bool = false,

    const restart_delay_ns: i128 = 1 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator) TidepoolClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TidepoolClient) void {
        self.disconnect();
    }

    /// Connect to tidepool's netrepl socket.
    pub fn start(self: *TidepoolClient) !void {
        if (self.socket_fd != null) return;

        const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse {
            log.warn("XDG_RUNTIME_DIR not set", .{});
            return error.NoRuntimeDir;
        };
        const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse {
            log.warn("WAYLAND_DISPLAY not set", .{});
            return error.NoWaylandDisplay;
        };

        // Build socket path
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/tidepool-{s}", .{ runtime_dir, wayland_display }) catch {
            log.warn("socket path too long", .{});
            return error.PathTooLong;
        };
        // Null-terminate for sockaddr
        if (path.len >= 108) {
            log.warn("socket path exceeds sockaddr_un limit", .{});
            return error.PathTooLong;
        }

        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
            log.warn("socket() failed: {}", .{err});
            self.last_restart_ns = std.time.nanoTimestamp();
            return err;
        };
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            log.warn("connect({s}) failed: {}", .{ path, err });
            posix.close(fd);
            self.last_restart_ns = std.time.nanoTimestamp();
            return err;
        };

        // Set non-blocking
        var fl_flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
            log.warn("fcntl GETFL failed: {}", .{err});
            posix.close(fd);
            return err;
        };
        fl_flags |= @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));
        _ = posix.fcntl(fd, posix.F.SETFL, fl_flags) catch |err| {
            log.warn("fcntl SETFL failed: {}", .{err});
            posix.close(fd);
            return err;
        };

        self.socket_fd = fd;
        self.recv_pos = 0;
        self.handshake_done = false;
        self.last_restart_ns = std.time.nanoTimestamp();

        // Send handshake (blocking-ish, socket buffer should absorb)
        const handshake = "\xFF{:name \"shoal\" :auto-flush true}";
        sendMsg(fd, handshake) catch |err| {
            log.warn("handshake send failed: {}", .{err});
            self.disconnect();
            return err;
        };

        log.info("connected to tidepool at {s}", .{path});
    }

    /// Send watch subscription after handshake is complete.
    fn sendSubscription(self: *TidepoolClient) void {
        const fd = self.socket_fd orelse return;
        const expr = "(ipc/watch-json [:tags :layout :title :windows :signal])\n";
        sendMsg(fd, expr) catch |err| {
            log.warn("subscription send failed: {}", .{err});
            self.disconnect();
            return;
        };
        self.handshake_done = true;
        self.state.connected = true;
        log.info("subscribed to tidepool events", .{});
    }

    /// Disconnect from the socket.
    pub fn disconnect(self: *TidepoolClient) void {
        if (self.socket_fd) |fd| {
            posix.close(fd);
        }
        self.socket_fd = null;
        self.recv_pos = 0;
        self.handshake_done = false;
        self.state.connected = false;
    }

    /// Send an action to tidepool (e.g. "focus-tag" with args "3").
    pub fn sendAction(self: *TidepoolClient, action: []const u8, args: []const u8) void {
        const fd = self.socket_fd orelse return;
        if (!self.handshake_done) return;

        var expr_buf: [512]u8 = undefined;
        const expr = if (args.len > 0)
            std.fmt.bufPrint(&expr_buf, "(ipc/dispatch \"{s}\" {s})\n", .{ action, args }) catch return
        else
            std.fmt.bufPrint(&expr_buf, "(ipc/dispatch \"{s}\")\n", .{action}) catch return;

        sendMsg(fd, expr) catch |err| {
            log.warn("action send failed: {}", .{err});
        };
    }

    /// Try to read available data from the socket.
    /// Non-blocking: reads whatever is available, extracts complete netrepl messages.
    /// Returns true if any state was updated.
    pub fn tryRead(self: *TidepoolClient) bool {
        if (self.socket_fd == null) {
            self.tryReconnect();
            return false;
        }

        const fd = self.socket_fd.?;
        var updated = false;

        while (true) {
            const space = self.recv_buf[self.recv_pos..];
            if (space.len == 0) {
                log.warn("recv buffer overflow, reconnecting", .{});
                self.disconnect();
                return updated;
            }

            const n = posix.read(fd, space) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("read from tidepool failed: {}", .{err});
                    self.disconnect();
                    return updated;
                },
            };

            if (n == 0) {
                log.info("tidepool socket EOF", .{});
                self.disconnect();
                return updated;
            }

            self.recv_pos += n;

            // Extract complete netrepl messages (4-byte LE length prefix)
            while (self.recv_pos >= 4) {
                const buf = self.recv_buf[0..self.recv_pos];
                const msg_len = std.mem.readInt(u32, buf[0..4], .little);
                const total = 4 + msg_len;

                if (self.recv_pos < total) break; // incomplete message

                const payload = buf[4..total];

                if (payload.len > 0 and payload[0] == 0xFF) {
                    // Output data — contains JSON lines
                    if (!self.handshake_done) {
                        // First 0xFF response is the handshake prompt; skip it and subscribe
                        self.sendSubscription();
                    } else {
                        // Parse JSON lines from the payload (skip 0xFF prefix)
                        const data = payload[1..];
                        var line_start: usize = 0;
                        for (data, 0..) |ch, i| {
                            if (ch == '\n') {
                                const line = data[line_start..i];
                                if (line.len > 0) {
                                    self.parseLine(line);
                                    updated = true;
                                }
                                line_start = i + 1;
                            }
                        }
                        // Handle last line without trailing newline
                        if (line_start < data.len) {
                            const line = data[line_start..];
                            if (line.len > 0) {
                                self.parseLine(line);
                                updated = true;
                            }
                        }
                    }
                } else if (payload.len > 0 and payload[0] == 0xFE) {
                    // Return value — for handshake, skip and send subscription
                    if (!self.handshake_done) {
                        self.sendSubscription();
                    }
                }
                // else: plain text response, ignore

                // Shift remaining data to front
                const remaining = self.recv_pos - total;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.recv_buf[0..remaining], buf[total..self.recv_pos]);
                }
                self.recv_pos = remaining;
            }
        }

        return updated;
    }

    fn tryReconnect(self: *TidepoolClient) void {
        const now = std.time.nanoTimestamp();
        if (now - self.last_restart_ns < restart_delay_ns) return;

        log.info("attempting tidepool reconnect", .{});
        self.start() catch {
            self.tryFallbackFiles();
        };
    }

    fn tryFallbackFiles(self: *TidepoolClient) void {
        const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return;

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/tidepool-tags", .{runtime_dir}) catch return;

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        var buf: [1024]u8 = undefined;
        const n = file.readAll(&buf) catch return;
        if (n == 0) return;

        for (&self.state.tags) |*tag| {
            tag.* = .{};
        }

        var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (iter.next()) |line| {
            if (line.len < 2) continue;
            const prefix = line[0];
            const num = std.fmt.parseInt(usize, line[1..], 10) catch continue;
            if (num > 10) continue;
            switch (prefix) {
                'f' => {
                    self.state.tags[num].focused = true;
                    self.state.tags[num].occupied = true;
                },
                'o' => {
                    self.state.tags[num].occupied = true;
                },
                else => {},
            }
        }
    }

    fn parseLine(self: *TidepoolClient, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
            log.warn("JSON parse error: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;
        const map = root.object;

        const event_val = map.get("event") orelse return;
        if (event_val != .string) return;
        const event = event_val.string;

        if (std.mem.eql(u8, event, "tags")) {
            self.parseTagsEvent(map);
        } else if (std.mem.eql(u8, event, "layout")) {
            self.parseLayoutEvent(map);
        } else if (std.mem.eql(u8, event, "title")) {
            self.parseTitleEvent(map);
        } else if (std.mem.eql(u8, event, "windows")) {
            self.parseWindowsEvent(map);
        } else if (std.mem.eql(u8, event, "signal")) {
            self.parseSignalEvent(map);
        }
    }

    fn parseTagsEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        // Reset legacy flat tags
        for (&self.state.tags) |*tag| {
            tag.* = .{};
        }

        if (map.get("outputs")) |outputs_val| {
            if (outputs_val == .array) {
                for (outputs_val.array.items) |output| {
                    if (output != .object) continue;
                    const out_map = output.object;

                    const is_focused = blk: {
                        const f = out_map.get("focused") orelse break :blk false;
                        break :blk f == .bool and f.bool;
                    };

                    // Find or create output entry
                    const out_x = jsonI32(out_map, "x");
                    const out_y = jsonI32(out_map, "y");
                    const oi = self.findOrCreateOutput(out_x, out_y);

                    // Reset this output's tags
                    for (&oi.tags) |*t| t.* = .{};
                    oi.focused = is_focused;

                    if (out_map.get("tags")) |tags_val| {
                        if (tags_val == .array) {
                            for (tags_val.array.items) |tag_num| {
                                if (tag_num != .integer) continue;
                                const idx: usize = @intCast(@max(0, @min(10, tag_num.integer)));
                                oi.tags[idx].focused = true;
                                oi.tags[idx].occupied = true;
                                // Update legacy flat tags for focused output
                                if (is_focused) {
                                    self.state.tags[idx].focused = true;
                                    self.state.tags[idx].occupied = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Parse occupied tags (global)
        if (map.get("occupied")) |occupied_val| {
            if (occupied_val == .array) {
                for (occupied_val.array.items) |tag_num| {
                    if (tag_num != .integer) continue;
                    const idx: usize = @intCast(@max(0, @min(10, tag_num.integer)));
                    self.state.tags[idx].occupied = true;
                    // Set occupied on all outputs
                    for (self.state.outputs[0..self.state.output_count]) |*o| {
                        o.tags[idx].occupied = true;
                    }
                }
            }
        }

        self.sortOutputs();
    }

    fn parseTitleEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        if (map.get("title")) |title_val| {
            if (title_val == .string) {
                const len = @min(title_val.string.len, self.state.title.len);
                @memcpy(self.state.title[0..len], title_val.string[0..len]);
                self.state.title_len = len;
            }
        } else {
            self.state.title_len = 0;
        }

        if (map.get("app-id")) |app_id_val| {
            if (app_id_val == .string) {
                const len = @min(app_id_val.string.len, self.state.app_id.len);
                @memcpy(self.state.app_id[0..len], app_id_val.string[0..len]);
                self.state.app_id_len = len;
            }
        } else {
            self.state.app_id_len = 0;
        }
    }

    fn parseLayoutEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        if (map.get("outputs")) |outputs_val| {
            if (outputs_val != .array) return;
            for (outputs_val.array.items) |output| {
                if (output != .object) continue;
                const out_map = output.object;

                const out_x = jsonI32(out_map, "x");
                const out_y = jsonI32(out_map, "y");
                const oi = self.findOrCreateOutput(out_x, out_y);

                const is_focused = blk: {
                    const f = out_map.get("focused") orelse break :blk false;
                    break :blk f == .bool and f.bool;
                };
                oi.focused = is_focused;

                // Output dimensions
                oi.w = jsonI32(out_map, "w");
                oi.h = jsonI32(out_map, "h");

                // Layout name
                if (out_map.get("layout")) |layout_val| {
                    if (layout_val == .string) {
                        const len = @min(layout_val.string.len, oi.layout.len);
                        @memcpy(oi.layout[0..len], layout_val.string[0..len]);
                        oi.layout_len = len;
                        // Update legacy flat layout for focused output
                        if (is_focused) {
                            @memcpy(self.state.layout[0..len], layout_val.string[0..len]);
                            self.state.layout_len = len;
                        }
                    }
                }

                // Active row
                if (out_map.get("active-row")) |v| {
                    if (v == .integer) oi.active_row = @intCast(@max(0, @min(255, v.integer)));
                }

                // Viewport context
                if (out_map.get("viewport")) |vp_val| {
                    if (vp_val == .object) {
                        const vp = vp_val.object;
                        oi.usable_x = jsonI32(vp, "x");
                        oi.usable_y = jsonI32(vp, "y");
                        oi.usable_w = jsonI32(vp, "w");
                        oi.usable_h = jsonI32(vp, "h");
                        oi.scroll_offset = jsonF32(vp, "scroll-offset");
                        oi.total_content_w = jsonF32(vp, "total-content-w");

                        // Column widths
                        oi.column_count = 0;
                        if (vp.get("column-widths")) |cw_val| {
                            if (cw_val == .array) {
                                for (cw_val.array.items, 0..) |cw, i| {
                                    if (i >= oi.column_widths.len) break;
                                    oi.column_widths[i] = switch (cw) {
                                        .float => @floatCast(cw.float),
                                        .integer => @floatFromInt(cw.integer),
                                        else => 0,
                                    };
                                    oi.column_count = i + 1;
                                }
                            }
                        }
                    }
                }
            }
        }

        self.sortOutputs();
    }

    fn parseWindowsEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        self.state.window_count = 0;
        self.state.windows_changed = true;

        const windows_val = map.get("windows") orelse return;
        if (windows_val != .array) return;

        for (windows_val.array.items) |win_val| {
            if (self.state.window_count >= self.state.windows.len) {
                log.warn("window count exceeds max ({}), truncating", .{self.state.windows.len});
                break;
            }
            if (win_val != .object) continue;
            const wm = win_val.object;

            var info = WindowInfo{};

            if (wm.get("wid")) |v| {
                if (v == .integer) info.wid = @intCast(@max(0, v.integer));
            }
            if (wm.get("app-id")) |v| {
                if (v == .string) {
                    const len = @min(v.string.len, info.app_id.len);
                    @memcpy(info.app_id[0..len], v.string[0..len]);
                    info.app_id_len = len;
                }
            }
            if (wm.get("title")) |v| {
                if (v == .string) {
                    const len = @min(v.string.len, info.title.len);
                    @memcpy(info.title[0..len], v.string[0..len]);
                    info.title_len = len;
                }
            }
            if (wm.get("tag")) |v| {
                if (v == .integer) info.tag = @intCast(@max(0, @min(10, v.integer)));
            }
            if (wm.get("x")) |v| {
                if (v == .integer) info.x = @intCast(v.integer);
            }
            if (wm.get("y")) |v| {
                if (v == .integer) info.y = @intCast(v.integer);
            }
            if (wm.get("w")) |v| {
                if (v == .integer) info.w = @intCast(v.integer);
            }
            if (wm.get("h")) |v| {
                if (v == .integer) info.h = @intCast(v.integer);
            }
            if (wm.get("focused")) |v| {
                if (v == .bool) info.focused = v.bool;
            }
            if (wm.get("float")) |v| {
                if (v == .bool) info.float = v.bool;
            }
            if (wm.get("fullscreen")) |v| {
                if (v == .bool) info.fullscreen = v.bool;
            }
            if (wm.get("visible")) |v| {
                if (v == .bool) info.visible = v.bool;
            }
            if (wm.get("row")) |v| {
                if (v == .integer) info.row = @intCast(@max(0, @min(255, v.integer)));
            }
            if (wm.get("layout")) |v| {
                if (v == .string) {
                    const len = @min(v.string.len, info.layout.len);
                    @memcpy(info.layout[0..len], v.string[0..len]);
                    info.layout_len = len;
                }
            }
            if (wm.get("meta")) |meta_val| {
                if (meta_val == .object) {
                    const meta = meta_val.object;
                    if (meta.get("column")) |v| {
                        if (v == .integer) info.column = @intCast(@max(0, @min(255, v.integer)));
                    }
                    if (meta.get("column-total")) |v| {
                        if (v == .integer) info.column_total = @intCast(@max(0, @min(255, v.integer)));
                    }
                    if (meta.get("row")) |v| {
                        if (v == .integer) info.row_in_col = @intCast(@max(0, @min(255, v.integer)));
                    }
                    if (meta.get("row-total")) |v| {
                        if (v == .integer) info.row_in_col_total = @intCast(@max(0, @min(255, v.integer)));
                    }
                }
            }

            self.state.windows[self.state.window_count] = info;
            self.state.window_count += 1;
        }
    }

    fn parseSignalEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        if (map.get("name")) |v| {
            if (v == .string) {
                const len = @min(v.string.len, self.state.signal.name.len);
                @memcpy(self.state.signal.name[0..len], v.string[0..len]);
                self.state.signal.name_len = len;
                self.state.signal.pending = true;
            }
        }
    }

    /// Sort outputs by position (left-to-right, then top-to-bottom).
    fn sortOutputs(self: *TidepoolClient) void {
        const outputs = self.state.outputs[0..self.state.output_count];
        std.mem.sort(OutputInfo, outputs, {}, struct {
            fn lessThan(_: void, a: OutputInfo, b: OutputInfo) bool {
                if (a.x != b.x) return a.x < b.x;
                return a.y < b.y;
            }
        }.lessThan);
    }

    // --- Helpers ---

    fn findOrCreateOutput(self: *TidepoolClient, x: i32, y: i32) *OutputInfo {
        // Find existing
        for (self.state.outputs[0..self.state.output_count]) |*o| {
            if (o.x == x and o.y == y) return o;
        }
        // Create new
        if (self.state.output_count < self.state.outputs.len) {
            const o = &self.state.outputs[self.state.output_count];
            o.* = .{};
            o.x = x;
            o.y = y;
            self.state.output_count += 1;
            return o;
        }
        // Overflow — reuse last
        return &self.state.outputs[self.state.outputs.len - 1];
    }

    fn jsonI32(map: std.json.ObjectMap, key: []const u8) i32 {
        const v = map.get(key) orelse return 0;
        if (v != .integer) return 0;
        return @intCast(v.integer);
    }

    fn jsonF32(map: std.json.ObjectMap, key: []const u8) f32 {
        const v = map.get(key) orelse return 0;
        return switch (v) {
            .float => @floatCast(v.float),
            .integer => @floatFromInt(v.integer),
            else => 0,
        };
    }

    pub fn toCompositorState(self: *TidepoolClient) cs.CompositorState {
        var result = cs.CompositorState{};

        // Copy outputs
        result.output_count = self.state.output_count;
        for (self.state.outputs[0..self.state.output_count], 0..) |*src, i| {
            var dst = &result.outputs[i];
            dst.x = src.x;
            dst.y = src.y;
            dst.w = src.w;
            dst.h = src.h;
            dst.focused = src.focused;
            dst.usable_w = src.usable_w;
            dst.usable_h = src.usable_h;
            dst.scroll_offset = src.scroll_offset;
            dst.total_content_w = src.total_content_w;
            dst.column_count = src.column_count;
            dst.column_widths = src.column_widths;
            dst.layout_len = src.layout_len;
            @memcpy(dst.layout[0..src.layout_len], src.layout[0..src.layout_len]);
            for (&src.tags, 0..) |*t, ti| {
                dst.tags[ti] = .{ .focused = t.focused, .occupied = t.occupied };
            }
        }

        // Copy flat tags
        for (&self.state.tags, 0..) |*t, i| {
            result.tags[i] = .{ .focused = t.focused, .occupied = t.occupied };
        }

        // Copy title
        result.title_len = self.state.title_len;
        @memcpy(result.title[0..self.state.title_len], self.state.title[0..self.state.title_len]);

        // Copy windows
        result.window_count = self.state.window_count;
        for (self.state.windows[0..self.state.window_count], 0..) |*src, i| {
            var dst = &result.windows[i];
            dst.wid = src.wid;
            dst.tag = src.tag;
            dst.x = src.x;
            dst.y = src.y;
            dst.w = src.w;
            dst.h = src.h;
            dst.focused = src.focused;
            dst.float = src.float;
            dst.fullscreen = src.fullscreen;
            dst.visible = src.visible;
            dst.column = src.column;
            dst.column_total = src.column_total;
            dst.row_in_col = src.row_in_col;
            dst.row_in_col_total = src.row_in_col_total;
            dst.app_id_len = src.app_id_len;
            @memcpy(dst.app_id[0..src.app_id_len], src.app_id[0..src.app_id_len]);
            dst.title_len = src.title_len;
            @memcpy(dst.title[0..src.title_len], src.title[0..src.title_len]);
        }

        // Copy signal (consumed via consumeSignal(), not here)
        if (self.state.signal.pending) {
            result.signal.pending = true;
            result.signal.name_len = self.state.signal.name_len;
            @memcpy(result.signal.name[0..self.state.signal.name_len], self.state.signal.name[0..self.state.signal.name_len]);
        }

        result.connected = self.state.connected;
        return result;
    }

    /// Mark the current signal as consumed so it won't appear in future state copies.
    pub fn consumeSignal(self: *TidepoolClient) void {
        self.state.signal.pending = false;
    }

    // Keep old stop() as alias for disconnect
    pub fn stop(self: *TidepoolClient) void {
        self.disconnect();
    }
};
