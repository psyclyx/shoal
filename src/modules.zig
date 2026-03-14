const std = @import("std");
const clay = @import("clay");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const tidepool = @import("tidepool.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const log = std.log.scoped(.modules);

// ---------------------------------------------------------------------------
// Module types
// ---------------------------------------------------------------------------

pub const ModuleType = enum {
    clock,
    cpu,
    memory,
    battery,
    network,
    pulseaudio,
    workspaces,
    title,
    custom,
};

// ---------------------------------------------------------------------------
// Module (tagged union)
// ---------------------------------------------------------------------------

pub const Module = union(ModuleType) {
    clock: Clock,
    cpu: Cpu,
    memory: Memory,
    battery: Battery,
    network: Network,
    pulseaudio: PulseAudio,
    workspaces: Workspaces,
    title: Title,
    custom: Custom,

    pub fn update(self: *Module) void {
        switch (self.*) {
            inline else => |*v| v.update(),
        }
    }

    pub fn render(self: *const Module, theme: *const Theme, font_id: u16, font_size: u16) void {
        switch (self.*) {
            inline else => |*v| v.render(theme, font_id, font_size),
        }
    }

    pub fn needsUpdate(self: *const Module, now_ms: i64) bool {
        const last, const interval = switch (self.*) {
            inline else => |*v| .{ v.last_update_ms, v.interval_ms },
        };
        if (interval <= 0) return false;
        return (now_ms - last) >= interval;
    }

    pub fn setLastUpdate(self: *Module, now_ms: i64) void {
        switch (self.*) {
            inline else => |*v| {
                v.last_update_ms = now_ms;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Config types
// ---------------------------------------------------------------------------

pub const BarConfig = struct {
    modules_left: []const ModuleType = &.{.workspaces},
    modules_center: []const ModuleType = &.{.title},
    modules_right: []const ModuleType = &.{ .pulseaudio, .cpu, .memory, .network, .clock },
    clock_format: []const u8 = "%H:%M",
};

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

pub const Clock = struct {
    text: [64]u8 = undefined,
    text_len: usize = 0,
    format: []const u8,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 1000,

    pub fn init(format: []const u8) Clock {
        return .{ .format = format };
    }

    pub fn update(self: *Clock) void {
        var ts: libc.time_t = std.time.timestamp();
        var tm: libc.struct_tm = undefined;
        if (libc.localtime_r(&ts, &tm) == null) return;

        const h: u8 = @intCast(tm.tm_hour);
        const m: u8 = @intCast(tm.tm_min);
        const s: u8 = @intCast(tm.tm_sec);
        const month: u8 = @intCast(tm.tm_mon + 1);
        const day: u8 = @intCast(tm.tm_mday);
        const year: u16 = @intCast(tm.tm_year + 1900);

        var buf: [64]u8 = undefined;
        var pos: usize = 0;
        const fmt = self.format;
        var fi: usize = 0;
        while (fi < fmt.len) {
            if (pos >= buf.len) break;
            if (fmt[fi] == '%' and fi + 1 < fmt.len) {
                fi += 1;
                switch (fmt[fi]) {
                    'H' => pos = appendU2(&buf, pos, h),
                    'I' => {
                        const h12: u8 = if (h == 0) 12 else if (h > 12) h - 12 else h;
                        pos = appendU2(&buf, pos, h12);
                    },
                    'M' => pos = appendU2(&buf, pos, m),
                    'S' => pos = appendU2(&buf, pos, s),
                    'm' => pos = appendU2(&buf, pos, month),
                    'd' => pos = appendU2(&buf, pos, day),
                    'Y' => {
                        const r = std.fmt.bufPrint(buf[pos..], "{d:0>4}", .{year}) catch break;
                        pos += r.len;
                    },
                    'y' => pos = appendU2(&buf, pos, @intCast(year % 100)),
                    'p' => {
                        const tag: []const u8 = if (h < 12) "AM" else "PM";
                        for (tag) |ch| {
                            if (pos >= buf.len) break;
                            buf[pos] = ch;
                            pos += 1;
                        }
                    },
                    '%' => {
                        buf[pos] = '%';
                        pos += 1;
                    },
                    else => {
                        if (pos + 1 < buf.len) {
                            buf[pos] = '%';
                            pos += 1;
                            buf[pos] = fmt[fi];
                            pos += 1;
                        }
                    },
                }
                fi += 1;
            } else {
                buf[pos] = fmt[fi];
                pos += 1;
                fi += 1;
            }
        }

        @memcpy(self.text[0..pos], buf[0..pos]);
        self.text_len = pos;
    }

    pub fn render(self: *const Clock, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderAccentPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Cpu
// ---------------------------------------------------------------------------

pub const Cpu = struct {
    text: [32]u8 = undefined,
    text_len: usize = 0,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 2000,
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    usage_percent: u8 = 0,

    pub fn init() Cpu {
        return .{};
    }

    pub fn update(self: *Cpu) void {
        const line = readFirstLine("/proc/stat") orelse return;
        var iter = std.mem.tokenizeScalar(u8, line.buf[0..line.len], ' ');
        const label = iter.next() orelse return;
        if (!std.mem.startsWith(u8, label, "cpu")) return;

        var total: u64 = 0;
        var idle: u64 = 0;
        var idx: usize = 0;
        while (iter.next()) |tok| {
            const val = std.fmt.parseUnsigned(u64, tok, 10) catch continue;
            total += val;
            if (idx == 3 or idx == 4) idle += val;
            idx += 1;
        }

        if (self.prev_total > 0 and total > self.prev_total) {
            const dt = total - self.prev_total;
            const di = idle - self.prev_idle;
            if (dt > 0) self.usage_percent = @intCast(((dt - di) * 100) / dt);
        }
        self.prev_idle = idle;
        self.prev_total = total;

        const result = std.fmt.bufPrint(&self.text, "cpu {d}%", .{self.usage_percent}) catch return;
        self.text_len = result.len;
    }

    pub fn render(self: *const Cpu, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

pub const Memory = struct {
    text: [32]u8 = undefined,
    text_len: usize = 0,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 5000,

    pub fn init() Memory {
        return .{};
    }

    pub fn update(self: *Memory) void {
        var total_kb: u64 = 0;
        var available_kb: u64 = 0;
        var found: u2 = 0;

        var buf: [4096]u8 = undefined;
        const data = readFileInto("/proc/meminfo", &buf) orelse return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (found == 3) break;
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total_kb = parseMemInfoValue(line);
                found |= 1;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                available_kb = parseMemInfoValue(line);
                found |= 2;
            }
        }

        if (total_kb > 0 and found == 3) {
            const used_mb = (total_kb - available_kb) / 1024;
            const total_mb = total_kb / 1024;
            const result = std.fmt.bufPrint(&self.text, "mem {d}/{d}M", .{ used_mb, total_mb }) catch return;
            self.text_len = result.len;
        }
    }

    pub fn render(self: *const Memory, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Battery
// ---------------------------------------------------------------------------

pub const Battery = struct {
    text: [32]u8 = undefined,
    text_len: usize = 0,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 10000,
    present: bool = false,

    const bat_base = "/sys/class/power_supply/BAT0/";

    pub fn init() Battery {
        return .{};
    }

    pub fn update(self: *Battery) void {
        const cap_line = readFirstLine(bat_base ++ "capacity") orelse {
            self.present = false;
            return;
        };
        self.present = true;
        const cap_str = trimLine(&cap_line.buf, cap_line.len);

        const status_line = readFirstLine(bat_base ++ "status");
        const charging = if (status_line) |sl|
            std.mem.eql(u8, trimLine(&sl.buf, sl.len), "Charging")
        else
            false;

        if (charging) {
            const result = std.fmt.bufPrint(&self.text, "bat +{s}%", .{cap_str}) catch return;
            self.text_len = result.len;
        } else {
            const result = std.fmt.bufPrint(&self.text, "bat {s}%", .{cap_str}) catch return;
            self.text_len = result.len;
        }
    }

    pub fn render(self: *const Battery, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (!self.present or self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// PulseAudio (via wpctl)
// ---------------------------------------------------------------------------

pub const PulseAudio = struct {
    text: [32]u8 = undefined,
    text_len: usize = 0,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 2000,

    pub fn init() PulseAudio {
        return .{};
    }

    pub fn update(self: *PulseAudio) void {
        var child = std.process.Child.init(
            &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" },
            std.heap.page_allocator,
        );
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;

        child.spawn() catch {
            self.setFallback();
            return;
        };

        var stdout_buf: [128]u8 = undefined;
        const n = child.stdout.?.readAll(&stdout_buf) catch {
            _ = child.wait() catch {};
            self.setFallback();
            return;
        };
        _ = child.wait() catch {};

        const output = std.mem.trim(u8, stdout_buf[0..n], &std.ascii.whitespace);
        const muted = std.mem.indexOf(u8, output, "[MUTED]") != null;
        const prefix = "Volume: ";

        if (std.mem.indexOf(u8, output, prefix)) |idx| {
            const after = output[idx + prefix.len ..];
            var end: usize = 0;
            for (after) |ch| {
                if ((ch >= '0' and ch <= '9') or ch == '.') end += 1 else break;
            }
            if (end > 0) {
                const vol_f = std.fmt.parseFloat(f32, after[0..end]) catch 0.0;
                const pct: u32 = @intFromFloat(@min(@max(vol_f * 100.0, 0.0), 100.0));
                if (muted) {
                    const result = std.fmt.bufPrint(&self.text, "vol muted", .{}) catch return;
                    self.text_len = result.len;
                } else {
                    const result = std.fmt.bufPrint(&self.text, "vol {d}%", .{pct}) catch return;
                    self.text_len = result.len;
                }
                return;
            }
        }
        self.setFallback();
    }

    fn setFallback(self: *PulseAudio) void {
        const result = std.fmt.bufPrint(&self.text, "vol --", .{}) catch return;
        self.text_len = result.len;
    }

    pub fn render(self: *const PulseAudio, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

pub const Network = struct {
    text: [64]u8 = undefined,
    text_len: usize = 0,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 10000,

    pub fn init() Network {
        return .{};
    }

    pub fn update(self: *Network) void {
        var route_buf: [4096]u8 = undefined;
        const route_data = readFileInto("/proc/net/route", &route_buf) orelse {
            self.setDown();
            return;
        };

        var iface_name: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, route_data, '\n');
        _ = lines.next(); // header
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeScalar(u8, line, '\t');
            const iface = fields.next() orelse continue;
            const dest = fields.next() orelse continue;
            if (std.mem.eql(u8, dest, "00000000")) {
                iface_name = iface;
                break;
            }
        }

        const iface = iface_name orelse {
            self.setDown();
            return;
        };

        // Check if wireless
        var wireless_buf: [4096]u8 = undefined;
        if (readFileInto("/proc/net/wireless", &wireless_buf)) |wdata| {
            var wlines = std.mem.splitScalar(u8, wdata, '\n');
            _ = wlines.next();
            _ = wlines.next();
            while (wlines.next()) |wline| {
                const trimmed = std.mem.trimLeft(u8, wline, " ");
                if (std.mem.startsWith(u8, trimmed, iface)) {
                    var wf = std.mem.tokenizeAny(u8, trimmed, " :");
                    _ = wf.next(); // iface
                    _ = wf.next(); // status
                    const link_str = wf.next() orelse break;
                    const clean = std.mem.trimRight(u8, link_str, ".");
                    const link_val = std.fmt.parseUnsigned(u8, clean, 10) catch break;
                    const pct: u8 = @intCast(@min((@as(u16, link_val) * 100) / 70, 100));
                    const result = std.fmt.bufPrint(&self.text, "wifi {d}%", .{pct}) catch return;
                    self.text_len = result.len;
                    return;
                }
            }
        }

        const result = std.fmt.bufPrint(&self.text, "{s} up", .{iface}) catch return;
        self.text_len = result.len;
    }

    fn setDown(self: *Network) void {
        const result = std.fmt.bufPrint(&self.text, "net off", .{}) catch return;
        self.text_len = result.len;
    }

    pub fn render(self: *const Network, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Workspaces (driven by TidepoolClient in ModuleManager)
// ---------------------------------------------------------------------------

pub const Workspaces = struct {
    last_update_ms: i64 = 0,
    interval_ms: i64 = 0, // event-driven

    pub fn init() Workspaces {
        return .{};
    }

    pub fn update(_: *Workspaces) void {}

    pub fn render(_: *const Workspaces, theme: *const Theme, font_id: u16, font_size: u16) void {
        // Actual rendering happens via ModuleManager.renderWorkspaces
        _ = theme;
        _ = font_id;
        _ = font_size;
    }
};

// ---------------------------------------------------------------------------
// Title (driven by TidepoolClient in ModuleManager)
// ---------------------------------------------------------------------------

pub const Title = struct {
    last_update_ms: i64 = 0,
    interval_ms: i64 = 0, // event-driven

    pub fn init() Title {
        return .{};
    }

    pub fn update(_: *Title) void {}

    pub fn render(_: *const Title, theme: *const Theme, font_id: u16, font_size: u16) void {
        _ = theme;
        _ = font_id;
        _ = font_size;
    }
};

// ---------------------------------------------------------------------------
// Custom
// ---------------------------------------------------------------------------

pub const Custom = struct {
    text: [256]u8 = undefined,
    text_len: usize = 0,
    command: []const u8,
    last_update_ms: i64 = 0,
    interval_ms: i64 = 5000,

    pub fn init(command: []const u8, interval_ms: i64) Custom {
        return .{ .command = command, .interval_ms = interval_ms };
    }

    pub fn update(self: *Custom) void {
        if (self.command.len == 0) return;

        var child = std.process.Child.init(
            &.{ "/bin/sh", "-c", self.command },
            std.heap.page_allocator,
        );
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.spawn() catch return;

        var stdout_buf: [256]u8 = undefined;
        const n = child.stdout.?.readAll(&stdout_buf) catch {
            _ = child.wait() catch {};
            return;
        };
        _ = child.wait() catch {};

        const trimmed = std.mem.trimRight(u8, stdout_buf[0..n], &std.ascii.whitespace);
        const len = @min(trimmed.len, self.text.len);
        @memcpy(self.text[0..len], trimmed[0..len]);
        self.text_len = len;
    }

    pub fn render(self: *const Custom, theme: *const Theme, font_id: u16, font_size: u16) void {
        if (self.text_len == 0) return;
        renderPill(self.text[0..self.text_len], theme, font_id, font_size);
    }
};

// ---------------------------------------------------------------------------
// Module Manager
// ---------------------------------------------------------------------------

pub const ModuleManager = struct {
    modules_left: []Module,
    modules_center: []Module,
    modules_right: []Module,
    tidepool_client: ?*tidepool.TidepoolClient,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bar_config: BarConfig) !ModuleManager {
        const left = try allocateModules(allocator, bar_config.modules_left, bar_config);
        errdefer allocator.free(left);
        const center = try allocateModules(allocator, bar_config.modules_center, bar_config);
        errdefer allocator.free(center);
        const right = try allocateModules(allocator, bar_config.modules_right, bar_config);
        errdefer allocator.free(right);

        // Check if tidepool is needed
        var needs_tp = false;
        for (bar_config.modules_left) |t| if (t == .workspaces or t == .title) {
            needs_tp = true;
        };
        if (!needs_tp) for (bar_config.modules_center) |t| if (t == .workspaces or t == .title) {
            needs_tp = true;
        };
        if (!needs_tp) for (bar_config.modules_right) |t| if (t == .workspaces or t == .title) {
            needs_tp = true;
        };

        var tp_client: ?*tidepool.TidepoolClient = null;
        if (needs_tp) {
            const c = try allocator.create(tidepool.TidepoolClient);
            c.* = tidepool.TidepoolClient.init(allocator);
            c.start() catch |err| {
                log.warn("tidepool start failed: {}, will retry", .{err});
            };
            tp_client = c;
        }

        return .{
            .modules_left = left,
            .modules_center = center,
            .modules_right = right,
            .tidepool_client = tp_client,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleManager) void {
        if (self.tidepool_client) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.allocator.free(self.modules_left);
        self.allocator.free(self.modules_center);
        self.allocator.free(self.modules_right);
    }

    /// Returns true if any state changed (needs re-render).
    pub fn updateAll(self: *ModuleManager) bool {
        var changed = false;
        const now_ms = std.time.milliTimestamp();

        if (self.tidepool_client) |c| {
            if (c.tryRead()) changed = true;
        }

        if (updateSlice(self.modules_left, now_ms)) changed = true;
        if (updateSlice(self.modules_center, now_ms)) changed = true;
        if (updateSlice(self.modules_right, now_ms)) changed = true;

        return changed;
    }

    pub fn renderSection(
        self: *const ModuleManager,
        modules: []const Module,
        theme: *const Theme,
        font_id: u16,
        font_size: u16,
    ) void {
        for (modules) |*m| {
            switch (m.*) {
                .workspaces => self.renderWorkspaces(theme, font_id, font_size),
                .title => self.renderTitle(theme, font_id, font_size),
                else => m.render(theme, font_id, font_size),
            }
        }
    }

    fn renderWorkspaces(self: *const ModuleManager, theme: *const Theme, font_id: u16, font_size: u16) void {
        const state = if (self.tidepool_client) |c| &c.state else return;

        clay.UI()(.{
            .id = clay.ElementId.ID("ws_group"),
            .layout = .{
                .child_gap = 3,
                .child_alignment = .{ .y = .center },
            },
        })({
            for (state.tags[1..10], 0..) |tag, i| {
                if (!tag.focused and !tag.occupied) continue;

                var num_buf: [2]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch continue;

                if (tag.focused) {
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("tag", @intCast(i)),
                        .layout = .{
                            .sizing = .{ .w = .fixed(24), .h = .fixed(24) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = theme_mod.toClay(theme.accent()),
                        .corner_radius = .all(6),
                    })({
                        clay.text(num_str, .{
                            .color = theme_mod.toClay(theme.background()),
                            .font_id = font_id,
                            .font_size = font_size,
                        });
                    });
                } else {
                    // Occupied but not focused — visible but secondary
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("tag", @intCast(i)),
                        .layout = .{
                            .sizing = .{ .w = .fixed(24), .h = .fixed(24) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                    })({
                        clay.text(num_str, .{
                            .color = theme_mod.toClay(theme.subtle()),
                            .font_id = font_id,
                            .font_size = font_size,
                        });
                    });
                }
            }
        });
    }

    fn renderTitle(self: *const ModuleManager, theme: *const Theme, font_id: u16, font_size: u16) void {
        const state = if (self.tidepool_client) |c| &c.state else return;
        const title_text = state.getTitle();
        if (title_text.len == 0) return;

        clay.text(title_text, .{
            .color = theme_mod.toClay(theme.text()),
            .font_id = font_id,
            .font_size = font_size,
        });
    }

    fn updateSlice(modules: []Module, now_ms: i64) bool {
        var changed = false;
        for (modules) |*m| {
            if (m.needsUpdate(now_ms)) {
                m.update();
                m.setLastUpdate(now_ms);
                changed = true;
            }
        }
        return changed;
    }

    fn allocateModules(allocator: std.mem.Allocator, types: []const ModuleType, bar_config: BarConfig) ![]Module {
        const modules = try allocator.alloc(Module, types.len);
        for (types, 0..) |t, i| {
            modules[i] = switch (t) {
                .clock => .{ .clock = Clock.init(bar_config.clock_format) },
                .cpu => .{ .cpu = Cpu.init() },
                .memory => .{ .memory = Memory.init() },
                .battery => .{ .battery = Battery.init() },
                .network => .{ .network = Network.init() },
                .pulseaudio => .{ .pulseaudio = PulseAudio.init() },
                .workspaces => .{ .workspaces = Workspaces.init() },
                .title => .{ .title = Title.init() },
                .custom => .{ .custom = Custom.init("", 5000) },
            };
        }
        return modules;
    }
};

// ---------------------------------------------------------------------------
// Shared rendering
// ---------------------------------------------------------------------------

/// Standard module text — default foreground for readability
fn renderPill(text: []const u8, theme: *const Theme, font_id: u16, font_size: u16) void {
    clay.text(text, .{
        .color = theme_mod.toClay(theme.text()),
        .font_id = font_id,
        .font_size = font_size,
    });
}

/// Accent pill — for prominent modules like clock
fn renderAccentPill(text: []const u8, theme: *const Theme, font_id: u16, font_size: u16) void {
    clay.UI()(.{
        .layout = .{
            .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
        },
        .background_color = theme_mod.toClay(theme.overlay()),
        .corner_radius = .all(6),
    })({
        clay.text(text, .{
            .color = theme_mod.toClay(theme.text()),
            .font_id = font_id,
            .font_size = font_size,
        });
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const LineResult = struct {
    buf: [512]u8,
    len: usize,
};

fn readFirstLine(comptime path: []const u8) ?LineResult {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var result: LineResult = .{ .buf = undefined, .len = 0 };
    const n = file.readAll(&result.buf) catch return null;
    const end = std.mem.indexOfScalar(u8, result.buf[0..n], '\n') orelse n;
    result.len = end;
    return result;
}

fn readFileInto(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return buf[0..n];
}

fn trimLine(buf: []const u8, len: usize) []const u8 {
    return std.mem.trimRight(u8, buf[0..len], &std.ascii.whitespace);
}

fn parseMemInfoValue(line: []const u8) u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    const rest = std.mem.trimLeft(u8, line[colon + 1 ..], " ");
    var end: usize = 0;
    for (rest) |ch| {
        if (ch < '0' or ch > '9') break;
        end += 1;
    }
    if (end == 0) return 0;
    return std.fmt.parseUnsigned(u64, rest[0..end], 10) catch 0;
}

fn appendU2(buf: []u8, pos: usize, val: u8) usize {
    if (pos + 2 > buf.len) return pos;
    buf[pos] = '0' + (val / 10);
    buf[pos + 1] = '0' + (val % 10);
    return pos + 2;
}
