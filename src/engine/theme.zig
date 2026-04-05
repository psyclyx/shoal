const std = @import("std");

/// RGBA color in 0.0-1.0 range (GL-native).
pub const Color = [4]f32;

/// Base16 color theme with font configuration.
pub const Theme = struct {
    // Base16 palette
    base00: Color, // default background
    base01: Color, // lighter background
    base02: Color, // selection background
    base03: Color, // comments, invisibles
    base04: Color, // dark foreground
    base05: Color, // default foreground
    base06: Color, // light foreground
    base07: Color, // lightest foreground
    base08: Color, // red
    base09: Color, // orange
    base0A: Color, // yellow
    base0B: Color, // green
    base0C: Color, // cyan
    base0D: Color, // blue
    base0E: Color, // purple
    base0F: Color, // brown

    // Font configuration
    font_family: []const u8 = "monospace",
    font_size: u16 = 21,

    // --- Semantic accessors ---

    pub fn background(self: Theme) Color {
        return self.base00;
    }

    pub fn surface(self: Theme) Color {
        return self.base01;
    }

    pub fn overlay(self: Theme) Color {
        return self.base02;
    }

    pub fn muted(self: Theme) Color {
        return self.base03;
    }

    pub fn subtle(self: Theme) Color {
        return self.base04;
    }

    pub fn text(self: Theme) Color {
        return self.base05;
    }

    pub fn bright_text(self: Theme) Color {
        return self.base06;
    }

    pub fn accent(self: Theme) Color {
        return self.base0D;
    }

    pub fn err(self: Theme) Color {
        return self.base08;
    }

    pub fn warning(self: Theme) Color {
        return self.base0A;
    }

    pub fn success(self: Theme) Color {
        return self.base0B;
    }

    pub fn info(self: Theme) Color {
        return self.base0C;
    }
};

/// Returns a dark theme based on Catppuccin Mocha.
pub fn default() Theme {
    return .{
        .base00 = hexToColor("1e1e2e"),
        .base01 = hexToColor("181825"),
        .base02 = hexToColor("313244"),
        .base03 = hexToColor("45475a"),
        .base04 = hexToColor("585b70"),
        .base05 = hexToColor("cdd6f4"),
        .base06 = hexToColor("f5e0dc"),
        .base07 = hexToColor("b4befe"),
        .base08 = hexToColor("f38ba8"),
        .base09 = hexToColor("fab387"),
        .base0A = hexToColor("f9e2af"),
        .base0B = hexToColor("a6e3a1"),
        .base0C = hexToColor("94e2d5"),
        .base0D = hexToColor("89b4fa"),
        .base0E = hexToColor("cba6f7"),
        .base0F = hexToColor("f2cdcd"),
    };
}

/// Parse a hex color string into a Color.
/// Accepts "#RRGGBB", "#RRGGBBAA", "RRGGBB", or "RRGGBBAA".
pub fn parseHexColor(hex_input: []const u8) ?Color {
    const hex = if (hex_input.len > 0 and hex_input[0] == '#') hex_input[1..] else hex_input;

    if (hex.len != 6 and hex.len != 8) return null;

    const r = std.fmt.parseUnsigned(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseUnsigned(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseUnsigned(u8, hex[4..6], 16) catch return null;
    const a: u8 = if (hex.len == 8)
        std.fmt.parseUnsigned(u8, hex[6..8], 16) catch return null
    else
        255;

    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

/// Convert a Color (0.0-1.0) to Clay's color format (0-255 range as f32).
pub fn toClay(color: Color) [4]f32 {
    return .{
        color[0] * 255.0,
        color[1] * 255.0,
        color[2] * 255.0,
        color[3] * 255.0,
    };
}

/// Parse a Theme from a std.json parsed Value (the "theme" object from config JSON).
/// Fields are like `{"base00": "#1e1e2e", "font_family": "monospace", "font_size": 14}`.
pub fn fromJson(allocator: std.mem.Allocator, json_val: std.json.Value) !Theme {
    if (json_val != .object) return error.InvalidThemeFormat;

    var theme = default();
    const map = json_val.object;

    // Parse base16 color fields
    inline for (.{
        .{ "base00", &theme.base00 },
        .{ "base01", &theme.base01 },
        .{ "base02", &theme.base02 },
        .{ "base03", &theme.base03 },
        .{ "base04", &theme.base04 },
        .{ "base05", &theme.base05 },
        .{ "base06", &theme.base06 },
        .{ "base07", &theme.base07 },
        .{ "base08", &theme.base08 },
        .{ "base09", &theme.base09 },
        .{ "base0A", &theme.base0A },
        .{ "base0B", &theme.base0B },
        .{ "base0C", &theme.base0C },
        .{ "base0D", &theme.base0D },
        .{ "base0E", &theme.base0E },
        .{ "base0F", &theme.base0F },
    }) |entry| {
        if (map.get(entry[0])) |val| {
            if (val == .string) {
                if (parseHexColor(val.string)) |color| {
                    entry[1].* = color;
                }
            }
        }
    }

    // Parse font configuration
    if (map.get("font_family")) |val| {
        if (val == .string) {
            theme.font_family = try allocator.dupe(u8, val.string);
        }
    }

    if (map.get("font_size")) |val| {
        if (val == .integer) {
            if (val.integer > 0 and val.integer <= std.math.maxInt(u16)) {
                theme.font_size = @intCast(val.integer);
            }
        }
    }

    return theme;
}

/// Compile-time hex color parse for default theme initialization.
fn hexToColor(comptime hex: []const u8) Color {
    @setEvalBranchQuota(10000);
    const result = comptime parseHexColor(hex);
    return result orelse @compileError("invalid hex color: " ++ hex);
}
