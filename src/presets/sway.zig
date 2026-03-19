pub const name = "sway";

pub const modules = .{
    .{ .name = "sway.janet", .source = @embedFile("../compositors/sway.janet") },
    .{ .name = "clock.janet", .source = @embedFile("../modules/clock.janet") },
    .{ .name = "sysinfo.janet", .source = @embedFile("../modules/sysinfo.janet") },
    .{ .name = "bar.janet", .source = @embedFile("../modules/bar.janet") },
    .{ .name = "launcher.janet", .source = @embedFile("../modules/launcher.janet") },
    .{ .name = "osd.janet", .source = @embedFile("../modules/osd.janet") },
};

pub const dmenu_source = @embedFile("../modules/dmenu.janet");
