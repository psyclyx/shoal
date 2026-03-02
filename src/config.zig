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
    const config = loadInner(arena.allocator()) catch |err| {
        log.warn("config load failed: {}", .{err});
        return .{ .config = .{}, .arena = arena };
    };
    return .{ .config = config, .arena = arena };
}

fn loadInner(allocator: std.mem.Allocator) !Config {
    const path = resolveConfigPath(allocator) catch return Config{};

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
