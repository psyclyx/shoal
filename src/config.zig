const std = @import("std");

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
