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
const janet = @import("janet.zig");

const c = @cImport({
    @cInclude("wayland-egl.h");
    @cInclude("EGL/egl.h");
    @cInclude("GLES3/gl3.h");
});

const log = std.log.scoped(.shoal);

const MAX_OUTPUTS = 8;

// ---------------------------------------------------------------------------
// Surface — per-output layer shell surface with its own EGL window
// ---------------------------------------------------------------------------

const Surface = struct {
    output: ?*wl.Output = null,
    wl_surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    egl_window: ?*c.struct_wl_egl_window = null,
    egl_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    width: u32 = 0,
    height: u32 = 0,
    needs_render: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    frame_requested_ms: i64 = 0,
    // Output identity from wl_output events (for matching tidepool outputs)
    output_x: i32 = 0,
    output_y: i32 = 0,
    output_name: [64]u8 = undefined,
    output_name_len: usize = 0,

    const frame_watchdog_ms: i64 = 500;

    fn initEgl(self: *Surface) !void {
        if (!self.configured or self.width == 0 or self.height == 0) return error.NotConfigured;
        if (self.egl_window != null) return;

        self.egl_window = c.wl_egl_window_create(
            @ptrCast(self.wl_surface.?),
            @intCast(self.width),
            @intCast(self.height),
        );
        if (self.egl_window == null) return error.EGLWindowFailed;

        self.egl_surface = c.eglCreateWindowSurface(
            egl_display,
            egl_config,
            @ptrCast(self.egl_window),
            null,
        );
        if (self.egl_surface == c.EGL_NO_SURFACE) {
            c.wl_egl_window_destroy(self.egl_window);
            self.egl_window = null;
            return error.EGLSurfaceFailed;
        }
    }

    fn deinitEgl(self: *Surface) void {
        if (self.egl_surface != c.EGL_NO_SURFACE) {
            _ = c.eglDestroySurface(egl_display, self.egl_surface);
            self.egl_surface = c.EGL_NO_SURFACE;
        }
        if (self.egl_window) |win| {
            c.wl_egl_window_destroy(win);
            self.egl_window = null;
        }
    }

    fn makeCurrent(self: *Surface) bool {
        return c.eglMakeCurrent(egl_display, self.egl_surface, self.egl_surface, egl_context) == c.EGL_TRUE;
    }
};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

// Wayland globals
var compositor: ?*wl.Compositor = null;
var layer_shell: ?*zwlr.LayerShellV1 = null;
var seat: ?*wl.Seat = null;
var shm: ?*wl.Shm = null;

// Per-output surfaces
var surfaces: [MAX_OUTPUTS]Surface = [_]Surface{.{}} ** MAX_OUTPUTS;
var surface_count: usize = 0;

// Shared EGL
var egl_display: c.EGLDisplay = c.EGL_NO_DISPLAY;
var egl_context: c.EGLContext = c.EGL_NO_CONTEXT;
var egl_config: c.EGLConfig = null;

var running = true;
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

    // Initialize the Janet VM and reactive dispatch
    try janet.init();
    defer janet.deinit();

    var dispatch = janet.createDispatch();
    try dispatch.initBoot();
    defer dispatch.deinitDispatch();

    // -- End-to-end dispatch test --
    // Register handlers: :init sets db, :init also schedules a timer via fx
    _ = try dispatch.eval(
        \\(reg-event-handler :init
        \\  (fn [cofx event]
        \\    {:db (merge (cofx :db) {:initialized true})
        \\     :timer {:delay 0.001 :event [:timer-test] :id :test-timer}}))
    , "init-handler");

    _ = try dispatch.eval(
        \\(reg-event-handler :timer-test
        \\  (fn [cofx event]
        \\    {:db (merge (cofx :db) {:timer-fired true})}))
    , "timer-test-handler");

    // Dispatch :init via the queue and verify
    dispatch.enqueue(janet.makeEvent("init"));
    _ = dispatch.processQueue();
    const init_val = janet.janetGet(dispatch.db, janet.kw("initialized"));
    if (janet.c.janet_checktype(init_val, janet.c.JANET_BOOLEAN) != 0 and
        janet.c.janet_unwrap_boolean(init_val) != 0)
    {
        log.info("dispatch test PASSED: db updated with :initialized true", .{});
    } else {
        log.err("dispatch test FAILED: db not updated after :init dispatch", .{});
        return error.DispatchTestFailed;
    }

    // Wait for timer to fire (1ms delay) and verify
    std.Thread.sleep(5 * std.time.ns_per_ms);
    dispatch.checkTimers();
    _ = dispatch.processQueue();
    const timer_val = janet.janetGet(dispatch.db, janet.kw("timer-fired"));
    if (janet.c.janet_checktype(timer_val, janet.c.JANET_BOOLEAN) != 0 and
        janet.c.janet_unwrap_boolean(timer_val) != 0)
    {
        log.info("timer test PASSED: timer fired and updated db", .{});
    } else {
        log.err("timer test FAILED: timer did not fire", .{});
        return error.TimerTestFailed;
    }

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    registry.setListener(*const void, registryListener, &{});

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const comp = compositor orelse return error.NoCompositor;
    const ls = layer_shell orelse return error.NoLayerShell;

    if (surface_count == 0) return error.NoOutputs;

    // Create layer surfaces for each output
    for (surfaces[0..surface_count]) |*surf| {
        surf.wl_surface = try comp.createSurface();
        surf.layer_surface = try ls.getLayerSurface(
            surf.wl_surface.?,
            surf.output,
            wlLayer(cfg.layer),
            cfg.namespace,
        );

        const ls_surf = surf.layer_surface.?;
        ls_surf.setSize(cfg.width, cfg.height);
        ls_surf.setAnchor(wlAnchor(cfg.anchor));
        ls_surf.setExclusiveZone(cfg.exclusive_zone);
        ls_surf.setMargin(cfg.margin.top, cfg.margin.right, cfg.margin.bottom, cfg.margin.left);
        ls_surf.setKeyboardInteractivity(wlKeyboardInteractivity(cfg.keyboard_interactivity));
        ls_surf.setListener(*Surface, layerSurfaceListener, surf);

        surf.wl_surface.?.commit();
    }

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

    // Wait for configure events
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Create EGL windows for configured surfaces
    var any_configured = false;
    for (surfaces[0..surface_count]) |*surf| {
        surf.initEgl() catch |err| {
            log.warn("EGL init failed for surface: {}", .{err});
            continue;
        };
        any_configured = true;
    }
    if (!any_configured) return error.NoConfigure;
    defer for (surfaces[0..surface_count]) |*surf| surf.deinitEgl();

    // Make first surface current for subsystem init
    if (!surfaces[0].makeCurrent()) return error.EGLMakeCurrentFailed;

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

    module_manager = try ModuleManager.init(allocator, cfg.moduleLayout());
    defer module_manager.deinit();

    // Initialize animated background from theme
    bg_color.set(cfg.theme.background());

    log.info("shoal running on {d} output(s)", .{surface_count});

    // Force initial module update + render
    _ = module_manager.updateAll();
    for (surfaces[0..surface_count]) |*surf| {
        if (surf.egl_surface != c.EGL_NO_SURFACE) {
            _ = renderSurface(surf);
            requestFrame(surf);
        }
    }

    const wl_fd = display.getFd();

    while (running) {
        // Dispatch any already-queued Wayland events before polling
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) {
                running = false;
                break;
            }
        }
        if (!running) break;

        _ = display.flush();

        // Poll Wayland fd + tidepool fd with timeout based on timers
        const tp_fd = module_manager.provider.getFd();
        var poll_fds = [2]std.posix.pollfd{
            .{ .fd = wl_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = tp_fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const nfds: std.posix.nfds_t = if (tp_fd != null) 2 else 1;
        const poll_timeout: i32 = dispatch.nextTimerTimeoutMs() orelse 100;
        _ = std.posix.poll(poll_fds[0..nfds], @min(poll_timeout, 100)) catch 0;

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) break;
        } else {
            display.cancelRead();
        }
        if (display.dispatchPending() != .SUCCESS) break;

        // Watchdog: reset stalled frame callbacks
        const now_ms = std.time.milliTimestamp();
        for (surfaces[0..surface_count]) |*surf| {
            if (surf.frame_pending and surf.needs_render and
                (now_ms - surf.frame_requested_ms) > Surface.frame_watchdog_ms)
            {
                log.warn("frame callback watchdog triggered, resetting", .{});
                surf.frame_pending = false;
            }
        }

        // Check timers, process event queue
        dispatch.checkTimers();
        if (dispatch.processQueue()) {
            if (dispatch.render_dirty) {
                dispatch.render_dirty = false;
                markAllDirty();
            }
        }

        // Check for data updates (tidepool, module timers, animations)
        const dt = frame_clock.tick();
        var changed = false;
        if (bg_color.update(dt)) changed = true;
        if (module_manager.updateAll()) changed = true;

        if (changed) {
            markAllDirty();
        }
    }
}

fn requestFrame(surf: *Surface) void {
    if (surf.frame_pending) return;
    const cb = surf.wl_surface.?.frame() catch return;
    cb.setListener(*Surface, frameListener, surf);
    surf.frame_pending = true;
    surf.frame_requested_ms = std.time.milliTimestamp();
}

fn frameListener(_: *wl.Callback, event: wl.Callback.Event, surf: *Surface) void {
    switch (event) {
        .done => {
            surf.frame_pending = false;
            if (surf.needs_render) {
                if (renderSurface(surf)) {
                    surf.needs_render = false;
                }
                requestFrame(surf);
            }
        },
    }
}

/// Mark all surfaces dirty and kick off a render via frame callbacks.
fn markAllDirty() void {
    for (surfaces[0..surface_count]) |*surf| {
        if (!surf.configured or surf.egl_surface == c.EGL_NO_SURFACE) continue;
        surf.needs_render = true;
        if (!surf.frame_pending) {
            // First change after idle — render immediately for responsiveness,
            // then request a frame callback to throttle subsequent updates.
            if (renderSurface(surf)) {
                surf.needs_render = false;
            }
            requestFrame(surf);
        }
    }
}

/// Render a frame for a surface. Returns true on success, false on failure.
fn renderSurface(surf: *Surface) bool {
    if (!surf.configured or surf.egl_surface == c.EGL_NO_SURFACE) return false;
    if (!surf.makeCurrent()) return false;

    const w: f32 = @floatFromInt(surf.width);
    const h: f32 = @floatFromInt(surf.height);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, text_renderer.getAtlasTexture());

    renderer.begin(w, h);
    layout.setDimensions(w, h);

    layout.beginLayout();
    declareUI(surf.output_name[0..surf.output_name_len]);
    layout.endLayout();

    renderer.end();
    _ = c.eglSwapBuffers(egl_display, surf.egl_surface);
    return true;
}

fn declareUI(output_name: []const u8) void {
    const bg = bg_color.get();
    const theme = &cfg.theme;

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
        clay.UI()(.{
            .id = clay.ElementId.ID("left"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .child_gap = 6,
                .child_alignment = .{ .y = .center },
            },
        })({
            module_manager.renderSection(
                module_manager.modules_left,
                theme,
                primary_font_id,
                cfg.theme.font_size,
                output_name,
            );
        });

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
                output_name,
            );
        });

        clay.UI()(.{
            .id = clay.ElementId.ID("right"),
            .layout = .{
                .sizing = .{ .w = .grow },
                .child_gap = 6,
                .child_alignment = .{ .x = .right, .y = .center },
            },
        })({
            module_manager.renderSection(
                module_manager.modules_right,
                theme,
                primary_font_id,
                cfg.theme.font_size,
                output_name,
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
                if (surface_count < MAX_OUTPUTS) {
                    const output = registry_.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                    surfaces[surface_count] = .{ .output = output };
                    output.setListener(*Surface, outputListener, &surfaces[surface_count]);
                    surface_count += 1;
                }
            }
        },
        .global_remove => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, surf: *Surface) void {
    switch (event) {
        .geometry => |geo| {
            surf.output_x = geo.x;
            surf.output_y = geo.y;
        },
        .name => |name_ev| {
            const name = std.mem.span(name_ev.name);
            const len = @min(name.len, surf.output_name.len);
            @memcpy(surf.output_name[0..len], name[0..len]);
            surf.output_name_len = len;
            log.info("output name: {s} at ({d},{d})", .{ surf.output_name[0..surf.output_name_len], surf.output_x, surf.output_y });
        },
        else => {},
    }
}

fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, surf: *Surface) void {
    switch (event) {
        .configure => |lscfg| {
            surf.layer_surface.?.ackConfigure(lscfg.serial);
            surf.width = lscfg.width;
            surf.height = lscfg.height;
            surf.configured = true;

            if (surf.egl_window) |win| {
                c.wl_egl_window_resize(win, @intCast(lscfg.width), @intCast(lscfg.height), 0, 0);
            }

            surf.needs_render = true;
            requestFrame(surf);
        },
        .closed => {
            running = false;
        },
    }
}
