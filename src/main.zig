// TODO: Extract Surface struct to support multiple wl_surfaces (bar + overlays).
// The tidepool client now streams window topology and signal events that
// overlay modules will consume. See surface.zig (planned).

const std = @import("std");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const clay = @import("clay");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Theme = config_mod.Theme;
const theme_mod = @import("theme.zig");
const Renderer = @import("renderer.zig").Renderer;
const TextRenderer = @import("text.zig").TextRenderer;
const Layout = @import("layout.zig").Layout;
const animation = @import("animation.zig");
const modules_mod = @import("modules.zig");
const ModuleManager = modules_mod.ModuleManager;

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
var needs_render = true;

var cfg: Config = .{};

// Subsystems
var renderer: Renderer = undefined;
var text_renderer: TextRenderer = undefined;
var layout: Layout = undefined;
var frame_clock: animation.FrameClock = animation.FrameClock.init();
var module_manager: ModuleManager = undefined;

// Font ID for the primary font
var primary_font_id: u16 = 0;

// Animation state
var bg_color: animation.Animated([4]f32) = animation.Animated([4]f32).init(.{ 0, 0, 0, 1 });

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var config_result = config_mod.load(allocator);
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

    // Initialize subsystems
    renderer = try Renderer.init(allocator);
    defer renderer.deinit();

    text_renderer = try TextRenderer.init(allocator);
    defer text_renderer.deinit();

    primary_font_id = text_renderer.loadFont(cfg.theme.font_family, cfg.theme.font_size) catch |err| blk: {
        log.warn("failed to load font \"{s}\": {}, falling back to monospace", .{ cfg.theme.font_family, err });
        break :blk text_renderer.loadFont("monospace", cfg.theme.font_size) catch return error.FontLoadFailed;
    };

    layout = try Layout.init(allocator, &text_renderer, &renderer);
    defer layout.deinit(allocator);

    module_manager = try ModuleManager.init(allocator, cfg.bar);
    defer module_manager.deinit();

    // Initialize animated background from theme
    bg_color.set(cfg.theme.background());

    log.info("shoal running: {}x{}", .{ configured_width, configured_height });

    // Force initial module update
    _ = module_manager.updateAll();

    // Do initial render — compositor won't send frame callbacks until we
    // have committed at least one buffer.
    render();

    // Request next frame
    requestFrame();

    while (running) {
        if (display.dispatch() != .SUCCESS) break;
    }
}

fn requestFrame() void {
    const cb = wl_surface.?.frame() catch return;
    cb.setListener(*const void, frameListener, &{});
}

fn frameListener(_: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
    switch (event) {
        .done => {
            const dt = frame_clock.tick();

            // Update animations
            var any_animating = false;
            if (bg_color.update(dt)) any_animating = true;

            // Update modules (non-blocking)
            const modules_changed = module_manager.updateAll();

            if (needs_render or any_animating or modules_changed) {
                render();
                needs_render = false;
            }

            // Always request next frame (modules need periodic polling)
            requestFrame();
        },
    }
}

fn render() void {
    const w: f32 = @floatFromInt(configured_width);
    const h: f32 = @floatFromInt(configured_height);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, text_renderer.getAtlasTexture());

    renderer.begin(w, h);
    layout.setDimensions(w, h);

    layout.beginLayout();
    declareUI();
    layout.endLayout();

    renderer.end();
    _ = c.eglSwapBuffers(egl_display, egl_surface);
}

fn declareUI() void {
    const bg = bg_color.get();
    const theme = &cfg.theme;

    // Root: full bar background
    clay.UI()(.{
        .id = clay.ElementId.ID("root"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 },
            .child_alignment = .{ .y = .center },
            .direction = .left_to_right,
        },
        .background_color = theme_mod.toClay(bg),
        .corner_radius = .all(8),
    })({
        // Left: workspaces and primary info — flush left
        clay.UI()(.{
            .id = clay.ElementId.ID("left"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .child_gap = 12,
                .child_alignment = .{ .y = .center },
            },
        })({
            module_manager.renderSection(
                module_manager.modules_left,
                theme,
                primary_font_id,
                cfg.theme.font_size,
            );
        });

        // Center: window title — centered, understated
        clay.UI()(.{
            .id = clay.ElementId.ID("center"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            module_manager.renderSection(
                module_manager.modules_center,
                theme,
                primary_font_id,
                cfg.theme.font_size,
            );
        });

        // Right: system status — flush right, spaced with separators
        clay.UI()(.{
            .id = clay.ElementId.ID("right"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .child_gap = 16,
                .child_alignment = .{ .x = .right, .y = .center },
            },
        })({
            module_manager.renderSection(
                module_manager.modules_right,
                theme,
                primary_font_id,
                cfg.theme.font_size,
            );
        });
    });
}

// --- Type mapping ---

fn wlLayer(l: Config.Layer) zwlr.LayerShellV1.Layer {
    return switch (l) {
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

fn registryListener(registry_: *wl.Registry, event: wl.Registry.Event, _: *const void) void {
    switch (event) {
        .global => |global| {
            const iface = std.mem.span(global.interface);
            if (std.mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                compositor = registry_.bind(global.name, wl.Compositor, @min(global.version, 6)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                layer_shell = registry_.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Seat.interface.name))) {
                seat = registry_.bind(global.name, wl.Seat, @min(global.version, 9)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Shm.interface.name))) {
                shm = registry_.bind(global.name, wl.Shm, @min(global.version, 2)) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (wl_output == null) {
                    wl_output = registry_.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
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

            needs_render = true;
            requestFrame();
        },
        .closed => {
            running = false;
        },
    }
}
