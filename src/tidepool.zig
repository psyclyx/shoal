const std = @import("std");
const log = std.log.scoped(.tidepool);

pub const TagInfo = struct {
    focused: bool = false,
    occupied: bool = false,
};

pub const WindowMeta = union(enum) {
    scroll: struct { column: u16, column_total: u16, row: u16, row_total: u16 },
    tabbed: struct { tab_index: u16, tab_total: u16 },
    master_stack: struct { is_master: bool, index: u16, index_total: u16 },
    grid: struct { row: u16, row_total: u16, column: u16, column_total: u16 },
    dwindle: struct { depth: u16, depth_total: u16 },
    none,
};

pub const WindowInfo = struct {
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
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    meta: WindowMeta = .none,

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

pub const TidepoolState = struct {
    tags: [11]TagInfo = [_]TagInfo{.{}} ** 11, // tags 0-10
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    app_id: [128]u8 = undefined,
    app_id_len: usize = 0,
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
};

pub const TidepoolClient = struct {
    state: TidepoolState = .{},
    child: ?std.process.Child = null,
    stdout_fd: ?std.posix.fd_t = null,
    stdout_buf: [4096]u8 = undefined,
    stdout_pos: usize = 0,
    allocator: std.mem.Allocator,
    last_restart_ns: i128 = 0,

    const restart_delay_ns: i128 = 3 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator) TidepoolClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TidepoolClient) void {
        self.stop();
    }

    /// Start the tidepoolmsg watch subprocess.
    pub fn start(self: *TidepoolClient) !void {
        if (self.child != null) return;

        var child = std.process.Child.init(
            &.{ "tidepoolmsg", "watch", "tags", "layout", "title", "windows", "signal" },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            log.warn("failed to spawn tidepoolmsg: {}", .{err});
            self.state.connected = false;
            self.last_restart_ns = std.time.nanoTimestamp();
            return err;
        };

        // Set stdout fd to non-blocking
        const stdout_fd = child.stdout.?.handle;
        var fl_flags = std.posix.fcntl(stdout_fd, std.posix.F.GETFL, 0) catch |err| {
            log.warn("fcntl GETFL failed: {}", .{err});
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.FcntlFailed;
        };
        fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = std.posix.fcntl(stdout_fd, std.posix.F.SETFL, fl_flags) catch |err| {
            log.warn("fcntl SETFL NONBLOCK failed: {}", .{err});
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.FcntlFailed;
        };

        self.child = child;
        self.stdout_fd = stdout_fd;
        self.stdout_pos = 0;
        self.state.connected = true;
        self.last_restart_ns = std.time.nanoTimestamp();
        log.info("tidepoolmsg started", .{});
    }

    /// Stop the subprocess.
    pub fn stop(self: *TidepoolClient) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        self.stdout_fd = null;
        self.stdout_pos = 0;
        self.state.connected = false;
    }

    /// Try to read available data from the subprocess stdout.
    /// Non-blocking: reads whatever is available, parses complete lines.
    /// Returns true if any state was updated.
    pub fn tryRead(self: *TidepoolClient) bool {
        // If no child, attempt reconnection after delay
        if (self.child == null) {
            self.tryReconnect();
            return false;
        }

        const fd = self.stdout_fd orelse return false;
        var updated = false;

        // Read as much as available
        while (true) {
            const space = self.stdout_buf[self.stdout_pos..];
            if (space.len == 0) {
                // Buffer full with no newline — discard and reset
                log.warn("stdout buffer overflow, discarding", .{});
                self.stdout_pos = 0;
                break;
            }

            const n = std.posix.read(fd, space) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("read from tidepoolmsg failed: {}", .{err});
                    self.stop();
                    return updated;
                },
            };

            if (n == 0) {
                // EOF — child exited
                log.info("tidepoolmsg EOF, process exited", .{});
                self.stop();
                return updated;
            }

            self.stdout_pos += n;

            // Extract and parse complete lines
            while (true) {
                const buf = self.stdout_buf[0..self.stdout_pos];
                const newline_pos = std.mem.indexOfScalar(u8, buf, '\n') orelse break;

                const line = buf[0..newline_pos];
                if (line.len > 0) {
                    self.parseLine(line);
                    updated = true;
                }

                // Shift remaining data to front
                const remaining = self.stdout_pos - (newline_pos + 1);
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.stdout_buf[0..remaining], buf[newline_pos + 1 .. self.stdout_pos]);
                }
                self.stdout_pos = remaining;
            }
        }

        return updated;
    }

    fn tryReconnect(self: *TidepoolClient) void {
        const now = std.time.nanoTimestamp();
        if (now - self.last_restart_ns < restart_delay_ns) return;

        log.info("attempting tidepoolmsg reconnect", .{});
        self.start() catch {
            // start() already logged the error and set last_restart_ns
            // Also try fallback indicator files
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

        // Reset tags
        for (&self.state.tags) |*tag| {
            tag.* = .{};
        }

        // Parse simple format: one tag number per line, prefixed with 'f' for focused, 'o' for occupied
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
        // Reset all tags
        for (&self.state.tags) |*tag| {
            tag.* = .{};
        }

        // Parse outputs for focused tags
        if (map.get("outputs")) |outputs_val| {
            if (outputs_val == .array) {
                for (outputs_val.array.items) |output| {
                    if (output != .object) continue;
                    const out_map = output.object;

                    const is_focused = blk: {
                        const f = out_map.get("focused") orelse break :blk false;
                        break :blk f == .bool and f.bool;
                    };

                    if (!is_focused) continue;

                    if (out_map.get("tags")) |tags_val| {
                        if (tags_val == .array) {
                            for (tags_val.array.items) |tag_num| {
                                if (tag_num != .integer) continue;
                                const idx: usize = @intCast(@max(0, @min(10, tag_num.integer)));
                                self.state.tags[idx].focused = true;
                                self.state.tags[idx].occupied = true;
                            }
                        }
                    }
                }
            }
        }

        // Parse occupied tags
        if (map.get("occupied")) |occupied_val| {
            if (occupied_val == .array) {
                for (occupied_val.array.items) |tag_num| {
                    if (tag_num != .integer) continue;
                    const idx: usize = @intCast(@max(0, @min(10, tag_num.integer)));
                    self.state.tags[idx].occupied = true;
                }
            }
        }
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

                const is_focused = blk: {
                    const f = out_map.get("focused") orelse break :blk false;
                    break :blk f == .bool and f.bool;
                };

                if (!is_focused) continue;

                if (out_map.get("layout")) |layout_val| {
                    if (layout_val == .string) {
                        const len = @min(layout_val.string.len, self.state.layout.len);
                        @memcpy(self.state.layout[0..len], layout_val.string[0..len]);
                        self.state.layout_len = len;
                        return;
                    }
                }
            }
        }
    }

    fn parseWindowsEvent(self: *TidepoolClient, map: std.json.ObjectMap) void {
        self.state.window_count = 0;
        self.state.windows_changed = true;

        const windows_val = map.get("windows") orelse return;
        if (windows_val != .array) return;

        for (windows_val.array.items) |win_val| {
            if (self.state.window_count >= self.state.windows.len) break;
            if (win_val != .object) continue;
            const wm = win_val.object;

            var info = WindowInfo{};

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
            if (wm.get("layout")) |v| {
                if (v == .string) {
                    const len = @min(v.string.len, info.layout.len);
                    @memcpy(info.layout[0..len], v.string[0..len]);
                    info.layout_len = len;
                }
            }

            // Parse layout meta
            if (wm.get("meta")) |meta_val| {
                if (meta_val == .object) {
                    info.meta = parseWindowMeta(meta_val.object, info.getLayout());
                }
            }

            self.state.windows[self.state.window_count] = info;
            self.state.window_count += 1;
        }
    }

    fn parseWindowMeta(meta: std.json.ObjectMap, layout_name: []const u8) WindowMeta {
        if (std.mem.eql(u8, layout_name, "scroll")) {
            return .{ .scroll = .{
                .column = jsonU16(meta, "column"),
                .column_total = jsonU16(meta, "column-total"),
                .row = jsonU16(meta, "row"),
                .row_total = jsonU16(meta, "row-total"),
            } };
        } else if (std.mem.eql(u8, layout_name, "tabbed")) {
            return .{ .tabbed = .{
                .tab_index = jsonU16(meta, "tab-index"),
                .tab_total = jsonU16(meta, "tab-total"),
            } };
        } else if (std.mem.eql(u8, layout_name, "master-stack")) {
            const is_master = if (meta.get("position")) |v| blk: {
                if (v == .string) break :blk std.mem.eql(u8, v.string, "master");
                break :blk false;
            } else false;
            return .{ .master_stack = .{
                .is_master = is_master,
                .index = jsonU16(meta, "index"),
                .index_total = jsonU16(meta, "index-total"),
            } };
        } else if (std.mem.eql(u8, layout_name, "grid")) {
            return .{ .grid = .{
                .row = jsonU16(meta, "row"),
                .row_total = jsonU16(meta, "row-total"),
                .column = jsonU16(meta, "column"),
                .column_total = jsonU16(meta, "column-total"),
            } };
        } else if (std.mem.eql(u8, layout_name, "dwindle")) {
            return .{ .dwindle = .{
                .depth = jsonU16(meta, "depth"),
                .depth_total = jsonU16(meta, "depth-total"),
            } };
        }
        return .none;
    }

    fn jsonU16(map: std.json.ObjectMap, key: []const u8) u16 {
        const v = map.get(key) orelse return 0;
        if (v != .integer) return 0;
        return @intCast(@max(0, @min(65535, v.integer)));
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
};
