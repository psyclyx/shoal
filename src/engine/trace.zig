const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

const State = enum { unknown, disabled, enabled };

var state: State = .unknown;

pub fn enabled() bool {
    switch (state) {
        .enabled => return true,
        .disabled => return false,
        .unknown => {
            const value = c.getenv("SHOAL_TRACE");
            const is_enabled = value != null and value[0] != 0 and value[0] != '0';
            state = if (is_enabled) .enabled else .disabled;
            return is_enabled;
        },
    }
}

pub fn nowNs() i128 {
    if (!enabled()) return 0;
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.tv_sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.tv_nsec));
}

pub fn elapsedMs(start_ns: i128) f64 {
    if (start_ns == 0) return 0;
    return @as(f64, @floatFromInt(nowNs() - start_ns)) / std.time.ns_per_ms;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("shoal-trace t_ns={d} " ++ fmt ++ "\n", .{nowNs()} ++ args);
}

pub fn logDuration(comptime label: []const u8, start_ns: i128) void {
    if (!enabled()) return;
    log(label ++ " dur_ms={d:.3}", .{elapsedMs(start_ns)});
}
