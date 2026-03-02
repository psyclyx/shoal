const std = @import("std");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const config = @import("config.zig");
const Config = config.Config;
const c = @cImport({
    @cInclude("wayland-egl.h");
    @cInclude("EGL/egl.h");
    @cInclude("GLES3/gl3.h");
});

const log = std.log.scoped(.shoal);

// --- Global state ---
var compositor: ?*wl.Compositor = null;
var layer_shell: ?*zwlr.LayerShellV1 = null;
var seat: ?*wl.Seat = null;
var shm: ?*wl.Shm = null;
var wl_output: ?*wl.Output = null;

var wl_surface: ?*wl.Surface = null;
var layer_surface: ?*zwlr.LayerSurfaceV1 = null;
var egl_window: ?*c.struct_wl_egl_window = null;
var egl_display: c.EGLDisplay = c.EGL_NO_DISPLAY;
var egl_context: c.EGLContext = c.EGL_NO_CONTEXT;
var egl_surface: c.EGLSurface = c.EGL_NO_SURFACE;

var configured_width: u32 = 0;
var configured_height: u32 = 0;
var running = true;

var cfg: Config = .{};

pub fn main() !void {
    var config_result = config.load(std.heap.page_allocator);
    defer config_result.deinit();
    cfg = config_result.config;

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    registry.setListener(*const void, registryListener, &{});

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const comp = compositor orelse return error.NoCompositor;
    const ls = layer_shell orelse return error.NoLayerShell;

    wl_surface = try comp.createSurface();
    layer_surface = try ls.getLayerSurface(wl_surface.?, wl_output, wlLayer(cfg.layer), cfg.namespace);

    const ls_surf = layer_surface.?;
    ls_surf.setSize(cfg.width, cfg.height);
    ls_surf.setAnchor(wlAnchor(cfg.anchor));
    ls_surf.setExclusiveZone(cfg.exclusive_zone);
    ls_surf.setMargin(cfg.margin.top, cfg.margin.right, cfg.margin.bottom, cfg.margin.left);
    ls_surf.setKeyboardInteractivity(wlKeyboardInteractivity(cfg.keyboard_interactivity));
    ls_surf.setListener(*const void, layerSurfaceListener, &{});

    // Initial commit (no buffer) to trigger configure
    wl_surface.?.commit();

    // Initialize EGL
    egl_display = c.eglGetDisplay(@ptrCast(display));
    if (egl_display == c.EGL_NO_DISPLAY) return error.EGLDisplayFailed;

    var egl_major: c.EGLint = 0;
    var egl_minor: c.EGLint = 0;
    if (c.eglInitialize(egl_display, &egl_major, &egl_minor) != c.EGL_TRUE)
        return error.EGLInitFailed;
    defer _ = c.eglTerminate(egl_display);

    log.info("EGL {}.{}", .{ egl_major, egl_minor });

    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE)
        return error.EGLBindFailed;

    const config_attribs = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
        c.EGL_NONE,
    };

    var egl_config: c.EGLConfig = null;
    var num_configs: c.EGLint = 0;
    if (c.eglChooseConfig(egl_display, &config_attribs, &egl_config, 1, &num_configs) != c.EGL_TRUE or num_configs == 0)
        return error.EGLConfigFailed;

    const context_attribs = [_]c.EGLint{
        c.EGL_CONTEXT_MAJOR_VERSION, 3,
        c.EGL_CONTEXT_MINOR_VERSION, 0,
        c.EGL_NONE,
    };
    egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &context_attribs);
    if (egl_context == c.EGL_NO_CONTEXT) return error.EGLContextFailed;
    defer _ = c.eglDestroyContext(egl_display, egl_context);

    // Wait for configure
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (configured_width == 0 or configured_height == 0) return error.NoConfigure;

    // Create EGL window surface
    egl_window = c.wl_egl_window_create(@ptrCast(wl_surface.?), @intCast(configured_width), @intCast(configured_height));
    if (egl_window == null) return error.EGLWindowFailed;
    defer c.wl_egl_window_destroy(egl_window);

    egl_surface = c.eglCreateWindowSurface(egl_display, egl_config, @ptrCast(egl_window), null);
    if (egl_surface == c.EGL_NO_SURFACE) return error.EGLSurfaceFailed;
    defer _ = c.eglDestroySurface(egl_display, egl_surface);

    if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) != c.EGL_TRUE)
        return error.EGLMakeCurrentFailed;

    log.info("shoal running: {}x{}", .{ configured_width, configured_height });

    render();

    while (running) {
        if (display.dispatch() != .SUCCESS) break;
    }
}

fn render() void {
    c.glViewport(0, 0, @intCast(configured_width), @intCast(configured_height));
    c.glClearColor(cfg.background.r, cfg.background.g, cfg.background.b, cfg.background.a);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    _ = c.eglSwapBuffers(egl_display, egl_surface);
}

// --- Type mapping ---

fn wlLayer(layer: Config.Layer) zwlr.LayerShellV1.Layer {
    return switch (layer) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

fn wlAnchor(anchor: Config.Anchor) zwlr.LayerSurfaceV1.Anchor {
    return .{
        .top = anchor.top,
        .bottom = anchor.bottom,
        .left = anchor.left,
        .right = anchor.right,
    };
}

fn wlKeyboardInteractivity(ki: Config.KeyboardInteractivity) zwlr.LayerSurfaceV1.KeyboardInteractivity {
    return switch (ki) {
        .none => .none,
        .exclusive => .exclusive,
        .on_demand => .on_demand,
    };
}

// --- Wayland listeners ---

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, _: *const void) void {
    switch (event) {
        .global => |global| {
            const iface = std.mem.span(global.interface);
            if (std.mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                compositor = registry.bind(global.name, wl.Compositor, @min(global.version, 6)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Seat.interface.name))) {
                seat = registry.bind(global.name, wl.Seat, @min(global.version, 9)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Shm.interface.name))) {
                shm = registry.bind(global.name, wl.Shm, @min(global.version, 2)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (wl_output == null) {
                    wl_output = registry.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                }
            }
        },
        .global_remove => {},
    }
}

fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, _: *const void) void {
    switch (event) {
        .configure => |lscfg| {
            layer_surface.?.ackConfigure(lscfg.serial);
            configured_width = lscfg.width;
            configured_height = lscfg.height;

            if (egl_window) |win| {
                c.wl_egl_window_resize(win, @intCast(lscfg.width), @intCast(lscfg.height), 0, 0);
            }

            render();
        },
        .closed => {
            running = false;
        },
    }
}
