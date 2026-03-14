const std = @import("std");

/// Easing functions for animation curves.
pub const Easing = enum {
    linear,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_out_cubic,
    ease_in_out_cubic,

    pub fn apply(self: Easing, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .ease_in_quad => t * t,
            .ease_out_quad => t * (2.0 - t),
            .ease_in_out_quad => if (t < 0.5)
                2.0 * t * t
            else
                -1.0 + (4.0 - 2.0 * t) * t,
            .ease_out_cubic => blk: {
                const t1 = t - 1.0;
                break :blk t1 * t1 * t1 + 1.0;
            },
            .ease_in_out_cubic => if (t < 0.5)
                4.0 * t * t * t
            else
                (t - 1.0) * (2.0 * t - 2.0) * (2.0 * t - 2.0) + 1.0,
        };
    }
};

/// Linearly interpolate between two values of the same type.
/// Supports f32, arrays of f32, and structs with all-f32 fields.
pub fn lerp(comptime T: type, a: T, b: T, t: f32) T {
    const info = @typeInfo(T);
    switch (info) {
        .float, .comptime_float => {
            return a + (b - a) * t;
        },
        .array => |arr| {
            if (arr.child != f32) @compileError("lerp: array element type must be f32");
            var result: T = undefined;
            for (0..arr.len) |i| {
                result[i] = a[i] + (b[i] - a[i]) * t;
            }
            return result;
        },
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                if (field.type != f32) @compileError("lerp: struct field '" ++ field.name ++ "' must be f32");
                @field(result, field.name) = @field(a, field.name) + (@field(b, field.name) - @field(a, field.name)) * t;
            }
            return result;
        },
        else => @compileError("lerp: unsupported type " ++ @typeName(T)),
    }
}

/// Animated value that smoothly transitions between states.
pub fn Animated(comptime T: type) type {
    return struct {
        const Self = @This();

        current: T,
        target: T,
        start: T,
        progress: f32,
        duration: f32,
        easing: Easing,
        active: bool,

        /// Create an animated value at rest with the given initial value.
        pub fn init(value: T) Self {
            return .{
                .current = value,
                .target = value,
                .start = value,
                .progress = 1.0,
                .duration = 0.0,
                .easing = .linear,
                .active = false,
            };
        }

        /// Begin animating toward a new target value.
        pub fn setTarget(self: *Self, target: T, duration: f32, easing: Easing) void {
            self.start = self.current;
            self.target = target;
            self.progress = 0.0;
            self.duration = duration;
            self.easing = easing;
            self.active = true;
        }

        /// Set value immediately without animation.
        pub fn set(self: *Self, value: T) void {
            self.current = value;
            self.target = value;
            self.start = value;
            self.progress = 1.0;
            self.active = false;
        }

        /// Advance animation by dt seconds. Returns true if still animating.
        pub fn update(self: *Self, dt: f32) bool {
            if (!self.active) return false;

            if (self.duration <= 0.0) {
                self.current = self.target;
                self.progress = 1.0;
                self.active = false;
                return false;
            }

            self.progress += dt / self.duration;
            if (self.progress >= 1.0) {
                self.progress = 1.0;
                self.current = self.target;
                self.active = false;
                return false;
            }

            const eased = self.easing.apply(self.progress);
            self.current = lerp(T, self.start, self.target, eased);
            return true;
        }

        /// Get the current interpolated value.
        pub fn get(self: *const Self) T {
            return self.current;
        }
    };
}

/// Returns true if any of the given animated values are currently active.
/// Pass a struct/tuple of pointers to Animated values.
pub fn anyActive(animated_ptrs: anytype) bool {
    inline for (std.meta.fields(@TypeOf(animated_ptrs))) |field| {
        if (@field(animated_ptrs, field.name).active) return true;
    }
    return false;
}

/// Simple frame clock for computing delta time between frames.
pub const FrameClock = struct {
    last_time_ns: ?i128,
    dt: f32,

    pub fn init() FrameClock {
        return .{
            .last_time_ns = null,
            .dt = 0.0,
        };
    }

    /// Advance the clock. Returns delta time in seconds since last tick.
    pub fn tick(self: *FrameClock) f32 {
        const now = std.time.nanoTimestamp();
        if (self.last_time_ns) |last| {
            const delta_ns = now - last;
            self.dt = @as(f32, @floatFromInt(delta_ns)) / 1_000_000_000.0;
        } else {
            self.dt = 0.0;
        }
        self.last_time_ns = now;
        return self.dt;
    }
};

// --- Tests ---

test "easing linear identity" {
    try std.testing.expectEqual(@as(f32, 0.0), Easing.linear.apply(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), Easing.linear.apply(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), Easing.linear.apply(1.0));
}

test "easing ease_out_quad endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), Easing.ease_out_quad.apply(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), Easing.ease_out_quad.apply(1.0));
}

test "lerp f32" {
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), lerp(f32, 0.0, 10.0, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lerp(f32, 0.0, 10.0, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), lerp(f32, 0.0, 10.0, 1.0), 0.001);
}

test "lerp array" {
    const a = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const b = [4]f32{ 1.0, 2.0, 4.0, 8.0 };
    const result = lerp([4]f32, a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), result[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), result[3], 0.001);
}

test "lerp struct" {
    const Color = struct { r: f32, g: f32, b: f32, a: f32 };
    const a: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
    const b: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    const result = lerp(Color, a, b, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), result.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), result.a, 0.001);
}

test "animated f32 basic transition" {
    var anim = Animated(f32).init(0.0);
    try std.testing.expect(!anim.active);

    anim.setTarget(10.0, 1.0, .linear);
    try std.testing.expect(anim.active);

    // Advance halfway
    _ = anim.update(0.5);
    try std.testing.expect(anim.active);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), anim.get(), 0.001);

    // Advance to completion
    _ = anim.update(0.5);
    try std.testing.expect(!anim.active);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), anim.get(), 0.001);
}

test "animated set immediate" {
    var anim = Animated(f32).init(0.0);
    anim.setTarget(10.0, 1.0, .linear);
    _ = anim.update(0.25);

    anim.set(42.0);
    try std.testing.expect(!anim.active);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), anim.get(), 0.001);
}

test "animated zero duration completes immediately" {
    var anim = Animated(f32).init(0.0);
    anim.setTarget(10.0, 0.0, .linear);

    const still_active = anim.update(0.016);
    try std.testing.expect(!still_active);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), anim.get(), 0.001);
}

test "anyActive detects active animations" {
    var a = Animated(f32).init(0.0);
    var b = Animated(f32).init(0.0);

    try std.testing.expect(!anyActive(.{ &a, &b }));

    a.setTarget(1.0, 1.0, .linear);
    try std.testing.expect(anyActive(.{ &a, &b }));

    _ = a.update(1.0);
    try std.testing.expect(!anyActive(.{ &a, &b }));
}

test "frame clock first tick returns zero" {
    var clock = FrameClock.init();
    const dt = clock.tick();
    try std.testing.expectEqual(@as(f32, 0.0), dt);
    try std.testing.expect(clock.last_time_ns != null);
}
