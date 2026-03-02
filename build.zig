const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Wayland protocol scanner ---
    const Scanner = @import("wayland").Scanner;
    const scanner = Scanner.create(b, .{});

    // System protocols
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    // Custom protocols
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    // Generate bindings for globals we need
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_seat", 9);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zwlr_layer_shell_v1", 5);

    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    wayland_mod.linkSystemLibrary("wayland-client", .{});

    // --- Clay layout engine ---
    const zclay = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "shoal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "wayland", .module = wayland_mod },
                .{ .name = "clay", .module = zclay.module("zclay") },
            },
        }),
    });

    // System libraries
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("GLESv2");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("harfbuzz");
    exe.linkSystemLibrary("fontconfig");

    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run shoal");
    run_step.dependOn(&run_cmd.step);
}
