// config.json parsing. Currently the only field that's actually consumed
// is `theme` — surfaces are declared in Janet via reg-surface.

const std = @import("std");
const log = std.log.scoped(.config);
const theme_mod = @import("theme.zig");
pub const Theme = theme_mod.Theme;

pub const Config = struct {
    pub const Layer = enum { background, bottom, top, overlay };

    pub const KeyboardInteractivity = enum { none, exclusive, on_demand };

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
};

/// Read theme from a config.json. Search order:
///   1. `explicit_path`, if given.
///   2. `<hint>/config.json` if `hint` is a directory, otherwise
///      `<dirname(hint)>/config.json` if `hint` is a file. This lets
///      callers pass the same config path used for `shoal run` and pick
///      up the per-config config.json that lives next to the modules.
///   3. `$XDG_CONFIG_HOME/shoal/config.json` (legacy single-config layout).
/// Falls back to the default theme if no candidate file exists.
pub fn loadTheme(
    io: std.Io,
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    hint: ?[]const u8,
) Theme {
    var path_buf: [4096]u8 = undefined;
    const path = explicit_path
        orelse resolveFromHint(io, &path_buf, hint)
        orelse resolveConfigPath(&path_buf)
        orelse return theme_mod.default();

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return theme_mod.default(),
        else => {
            log.warn("config.json read failed: {}", .{err});
            return theme_mod.default();
        },
    };
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch |err| {
        log.warn("config.json parse failed: {}", .{err});
        return theme_mod.default();
    };
    defer parsed.deinit();

    if (parsed.value != .object) return theme_mod.default();
    const theme_val = parsed.value.object.get("theme") orelse return theme_mod.default();
    return theme_mod.fromJson(allocator, theme_val) catch theme_mod.default();
}

fn resolveFromHint(io: std.Io, buf: []u8, hint: ?[]const u8) ?[]const u8 {
    const h = hint orelse return null;
    // Treat as directory if it is one; otherwise use its parent.
    if (std.Io.Dir.cwd().openDir(io, h, .{})) |dir| {
        var d = dir;
        d.close(io);
        return std.fmt.bufPrint(buf, "{s}/config.json", .{h}) catch null;
    } else |_| {}
    if (std.fs.path.dirname(h)) |parent| {
        return std.fmt.bufPrint(buf, "{s}/config.json", .{parent}) catch null;
    }
    return null;
}

fn resolveConfigPath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |config_home| {
        return std.fmt.bufPrint(buf, "{s}/shoal/config.json", .{config_home}) catch null;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/shoal/config.json", .{home}) catch null;
    }
    return null;
}

fn getenv(comptime name: [:0]const u8) ?[]const u8 {
    const value = std.posix.system.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}
