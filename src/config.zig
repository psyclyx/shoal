const std = @import("std");
const log = std.log.scoped(.config);

pub const Config = struct {
    layer: Layer = .bottom,
    anchor: Anchor = .{ .top = true, .left = true, .right = true },
    width: u32 = 0,
    height: u32 = 32,
    exclusive_zone: i32 = 32,
    margin: Margin = .{},
    namespace: [:0]const u8 = "shoal",
    keyboard_interactivity: KeyboardInteractivity = .none,
    background: Color = .{ .r = 0.12, .g = 0.12, .b = 0.18, .a = 0.95 },

    pub const Layer = enum {
        background,
        bottom,
        top,
        overlay,
    };

    pub const KeyboardInteractivity = enum {
        none,
        exclusive,
        on_demand,
    };

    pub const Anchor = struct {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    };

    pub const Margin = struct {
        top: i32 = 0,
        right: i32 = 0,
        bottom: i32 = 0,
        left: i32 = 0,
    };

    pub const Color = struct {
        r: f32 = 0.0,
        g: f32 = 0.0,
        b: f32 = 0.0,
        a: f32 = 1.0,
    };
};

pub const LoadResult = struct {
    config: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LoadResult) void {
        self.arena.deinit();
    }
};

pub fn load(backing_allocator: std.mem.Allocator) LoadResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    const allocator = arena.allocator();

    const overrides = parseArgs(allocator) catch {
        printUsage();
        std.process.exit(1);
    };

    if (overrides.help) {
        printUsage();
        std.process.exit(0);
    }

    var config = loadFile(allocator, overrides.config_path) catch |err| blk: {
        log.warn("config load failed: {}", .{err});
        break :blk Config{};
    };

    applyOverrides(&config, overrides);

    return .{ .config = config, .arena = arena };
}

// --- File loading ---

fn loadFile(allocator: std.mem.Allocator, explicit_path: ?[:0]const u8) !Config {
    const path = explicit_path orelse resolveConfigPath(allocator) catch return Config{};

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => |e| return e,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1 << 20);

    return std.json.parseFromSliceLeaky(Config, allocator, contents, .{
        .ignore_unknown_fields = true,
    });
}

fn resolveConfigPath(allocator: std.mem.Allocator) ![:0]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |config_home| {
        return try std.fs.path.joinZ(allocator, &.{ config_home, "shoal", "config.json" });
    }
    if (std.posix.getenv("HOME")) |home| {
        return try std.fs.path.joinZ(allocator, &.{ home, ".config", "shoal", "config.json" });
    }
    return error.NoConfigDir;
}

// --- CLI parsing ---

const CliOverrides = struct {
    config_path: ?[:0]const u8 = null,
    layer: ?Config.Layer = null,
    anchor: ?Config.Anchor = null,
    width: ?u32 = null,
    height: ?u32 = null,
    exclusive_zone: ?i32 = null,
    namespace: ?[:0]const u8 = null,
    keyboard_interactivity: ?Config.KeyboardInteractivity = null,
    background: ?Config.Color = null,
    margin: ?Config.Margin = null,
    help: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !CliOverrides {
    _ = allocator;
    var overrides: CliOverrides = .{};
    var args = std.process.ArgIterator.init();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (eql(arg, "--help") or eql(arg, "-h")) {
            overrides.help = true;
        } else if (eql(arg, "--config")) {
            overrides.config_path = args.next() orelse return error.MissingValue;
        } else if (eql(arg, "--layer")) {
            overrides.layer = parseEnum(Config.Layer, args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--anchor")) {
            overrides.anchor = parseAnchor(args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--width")) {
            overrides.width = parseUint(u32, args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--height")) {
            overrides.height = parseUint(u32, args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--exclusive-zone")) {
            overrides.exclusive_zone = parseInt(i32, args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--namespace")) {
            overrides.namespace = args.next() orelse return error.MissingValue;
        } else if (eql(arg, "--keyboard-interactivity")) {
            overrides.keyboard_interactivity = parseEnum(Config.KeyboardInteractivity, args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--background")) {
            overrides.background = parseHexColor(args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else if (eql(arg, "--margin")) {
            overrides.margin = parseMargin(args.next() orelse return error.MissingValue) orelse return error.InvalidValue;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    return overrides;
}

fn applyOverrides(config: *Config, overrides: CliOverrides) void {
    if (overrides.layer) |v| config.layer = v;
    if (overrides.anchor) |v| config.anchor = v;
    if (overrides.width) |v| config.width = v;
    if (overrides.height) |v| config.height = v;
    if (overrides.exclusive_zone) |v| config.exclusive_zone = v;
    if (overrides.namespace) |v| config.namespace = v;
    if (overrides.keyboard_interactivity) |v| config.keyboard_interactivity = v;
    if (overrides.background) |v| config.background = v;
    if (overrides.margin) |v| config.margin = v;
}

// --- Parsers ---

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseEnum(comptime E: type, s: [:0]const u8) ?E {
    return std.meta.stringToEnum(E, s);
}

fn parseUint(comptime T: type, s: [:0]const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

fn parseInt(comptime T: type, s: [:0]const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

fn parseAnchor(s: [:0]const u8) ?Config.Anchor {
    if (eql(s, "none")) return .{};

    var anchor: Config.Anchor = .{};
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |part| {
        if (eql(part, "top")) {
            anchor.top = true;
        } else if (eql(part, "bottom")) {
            anchor.bottom = true;
        } else if (eql(part, "left")) {
            anchor.left = true;
        } else if (eql(part, "right")) {
            anchor.right = true;
        } else {
            return null;
        }
    }
    return anchor;
}

fn parseMargin(s: [:0]const u8) ?Config.Margin {
    var values: [4]i32 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, s, ',');

    while (iter.next()) |part| {
        if (count >= 4) return null;
        values[count] = std.fmt.parseInt(i32, part, 10) catch return null;
        count += 1;
    }

    return switch (count) {
        1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
        4 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
        else => null,
    };
}

/// Parse hex color: #RRGGBB or #RRGGBBAA
fn parseHexColor(s: [:0]const u8) ?Config.Color {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else return null;

    if (hex.len != 6 and hex.len != 8) return null;

    const r = std.fmt.parseUnsigned(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseUnsigned(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseUnsigned(u8, hex[4..6], 16) catch return null;
    const a: u8 = if (hex.len == 8) std.fmt.parseUnsigned(u8, hex[6..8], 16) catch return null else 255;

    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn printUsage() void {
    const usage =
        \\Usage: shoal [OPTIONS]
        \\
        \\Options:
        \\  --config <path>                 Load config from JSON file
        \\  --layer <layer>                 Surface layer (background|bottom|top|overlay)
        \\  --anchor <edges>                Anchor edges, comma-separated (top,left,right,bottom) or "none"
        \\  --width <px>                    Surface width (0 = auto)
        \\  --height <px>                   Surface height (0 = auto)
        \\  --exclusive-zone <px>           Exclusive zone (-1 to disable)
        \\  --margin <t,r,b,l>              Margin in pixels (single value or top,right,bottom,left)
        \\  --namespace <name>              Surface namespace
        \\  --keyboard-interactivity <mode> Keyboard mode (none|exclusive|on_demand)
        \\  --background <#RRGGBBAA>        Background color as hex
        \\  -h, --help                      Show this help
        \\
        \\Config is loaded in order: defaults → XDG config file → --config file → CLI overrides
        \\XDG config path: $XDG_CONFIG_HOME/shoal/config.json (or ~/.config/shoal/config.json)
        \\
    ;
    std.fs.File.stderr().writeAll(usage) catch {};
}
