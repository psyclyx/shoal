const std = @import("std");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const clay = @import("clay");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Renderer = @import("renderer.zig").Renderer;
const TextRenderer = @import("text.zig").TextRenderer;
const Layout = @import("layout.zig").Layout;
const animation = @import("animation.zig");
const janet = @import("janet.zig");
const hiccup_mod = @import("hiccup.zig");

const c = @cImport({
    @cInclude("wayland-egl.h");
    @cInclude("EGL/egl.h");
    @cInclude("GLES3/gl3.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const BTN_LEFT: u32 = 0x110;

const log = std.log.scoped(.shoal);

const MAX_OUTPUTS = 8;
const MAX_SURFACES = 16; // MAX_OUTPUTS static + dynamic

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
    // View dispatch — null means default view, keyword string selects a named view
    view_name_str: ?[:0]const u8 = null,
    // Dynamic surfaces are created/destroyed from Janet via :surface fx
    is_dynamic: bool = false,
    // Hot surface: pre-created with EGL ready, waiting to be claimed
    is_hot: bool = false,

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
var pointer: ?*wl.Pointer = null;
var keyboard: ?*wl.Keyboard = null;

// XKB state
var xkb_ctx: ?*xkb.struct_xkb_context = null;
var xkb_km: ?*xkb.struct_xkb_keymap = null;
var xkb_st: ?*xkb.struct_xkb_state = null;
var keyboard_focus_surface: ?*wl.Surface = null;

// Pointer state
var pointer_x: f32 = -1;
var pointer_y: f32 = -1;
var pointer_surface: ?*wl.Surface = null;
var pointer_button_pressed: bool = false;
var pointer_button_just_released: bool = false;
var pointer_surface_changed: bool = false;
var pointer_scroll_y: f64 = 0; // accumulated vertical scroll within frame

// Hover tracking — stores element IDs hovered in the previous frame
const MAX_HOVER_IDS = 8;
const MAX_HOVER_ID_LEN = 64;
var prev_hover_strs: [MAX_HOVER_IDS][MAX_HOVER_ID_LEN]u8 = [_][MAX_HOVER_ID_LEN]u8{[_]u8{0} ** MAX_HOVER_ID_LEN} ** MAX_HOVER_IDS;
var prev_hover_lens: [MAX_HOVER_IDS]usize = [_]usize{0} ** MAX_HOVER_IDS;
var prev_hover_count: usize = 0;

// Per-output surfaces (static) + dynamic surfaces
var surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES;
var surface_count: usize = 0;
var static_surface_count: usize = 0;

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
var dispatch: janet.Dispatch = undefined;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var config_result = config_mod.load(allocator);
    defer config_result.deinit();
    cfg = config_result.config;
    const dmenu = config_result.dmenu;

    // Initialize the Janet VM and reactive dispatch
    try janet.init();
    defer janet.deinit();

    dispatch = janet.createDispatch();
    try dispatch.initBoot(cfg.theme, dmenu.enabled);
    defer dispatch.deinitDispatch();

    // In dmenu mode: read stdin items and inject into db
    if (dmenu.enabled) {
        var stdin_buf: [65536]u8 = undefined;
        const bytes = std.fs.File.stdin().readAll(&stdin_buf) catch 0;
        const content = stdin_buf[0..bytes];

        // Collect line slices (pointing into stdin_buf)
        var item_ptrs: [4096][]const u8 = undefined;
        var item_count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and item_count < item_ptrs.len) {
                item_ptrs[item_count] = line;
                item_count += 1;
            }
        }

        dispatch.injectDmenuItems(item_ptrs[0..item_count], dmenu.prompt);
    }

    // Dispatch :init — all modules register :init handlers (composed automatically)
    dispatch.enqueue(janet.makeEvent("init"));
    _ = dispatch.processQueue();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    defer {
        if (xkb_st) |s| xkb.xkb_state_unref(s);
        if (xkb_km) |m| xkb.xkb_keymap_unref(m);
        if (xkb_ctx) |ctx| xkb.xkb_context_unref(ctx);
    }

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

    // Disable vsync blocking — frame callbacks handle pacing
    _ = c.eglSwapInterval(egl_display, 0);

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
    defer {
        for (surfaces[0..surface_count]) |*surf| {
            surf.deinitEgl();
            if (surf.is_dynamic) {
                if (surf.layer_surface) |ls_surf| ls_surf.destroy();
                if (surf.wl_surface) |ws| ws.destroy();
            }
        }
    }

    // Make first surface current for subsystem init
    if (!surfaces[0].makeCurrent()) return error.EGLMakeCurrentFailed;

    // Initialize subsystems
    renderer = try Renderer.init(allocator);
    defer renderer.deinit();

    text_renderer = try TextRenderer.init(allocator);
    defer text_renderer.deinit();

    _ = text_renderer.loadFont(cfg.theme.font_family, cfg.theme.font_size) catch |err| blk: {
        log.warn("failed to load font \"{s}\": {}, falling back to monospace", .{ cfg.theme.font_family, err });
        break :blk text_renderer.loadFont("monospace", cfg.theme.font_size) catch return error.FontLoadFailed;
    };

    layout = try Layout.init(allocator, &text_renderer, &renderer);
    defer layout.deinit(allocator);

    static_surface_count = surface_count;

    // Pre-create a hot overlay surface so dynamic surface creation is instant
    createHotSurface();

    log.info("shoal running on {d} output(s)", .{surface_count});

    // Force initial render — request frame callback BEFORE render so the
    // callback is associated with this commit (wl_surface.frame takes effect
    // on the next wl_surface.commit, which eglSwapBuffers triggers).
    for (surfaces[0..surface_count]) |*surf| {
        if (surf.egl_surface != c.EGL_NO_SURFACE) {
            requestFrame(surf);
            _ = renderSurface(surf);
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

        // Poll Wayland fd + spawn fds + IPC fds with timeout based on timers
        var poll_fds: [26]std.posix.pollfd = undefined; // 1 base + 16 spawns + 8 ipc + 1 headroom
        poll_fds[0] = .{ .fd = wl_fd, .events = std.posix.POLL.IN, .revents = 0 };
        var nfds: usize = 1;
        const spawn_fd_start = nfds;
        nfds += dispatch.fillSpawnPollFds(poll_fds[nfds..]);
        const ipc_fd_start = nfds;
        nfds += dispatch.fillIpcPollFds(poll_fds[nfds..]);
        const poll_timeout: i32 = if (dispatch.hasActiveAnims())
            16 // ~60fps for active animations
        else
            dispatch.nextTimerTimeoutMs() orelse -1; // -1 = block until event
        _ = std.posix.poll(poll_fds[0..nfds], poll_timeout) catch 0;

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) break;
        } else {
            display.cancelRead();
        }
        if (display.dispatchPending() != .SUCCESS) break;

        // Process readable spawn fds
        for (poll_fds[spawn_fd_start..ipc_fd_start]) |pfd| {
            if (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                dispatch.onSpawnReadable(pfd.fd);
            }
        }

        // Process readable IPC fds
        for (poll_fds[ipc_fd_start..nfds]) |pfd| {
            if (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                dispatch.onIpcReadable(pfd.fd);
            }
        }

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
        var db_changed = false;
        const loop_t0 = std.time.microTimestamp();
        _ = dispatch.processQueue();
        const loop_t1 = std.time.microTimestamp();

        // Process surface lifecycle requests from Janet
        processSurfaceRequests();
        const loop_t2 = std.time.microTimestamp();

        if (dispatch.render_dirty) {
            dispatch.render_dirty = false;
            db_changed = true;
        }

        // Tick animations
        const dt = frame_clock.tick();
        const anim_active = dispatch.tickAnimations(dt);

        // Process any completion events from finished animations
        _ = dispatch.processQueue();
        if (dispatch.render_dirty) {
            dispatch.render_dirty = false;
            db_changed = true;
        }

        if (db_changed) {
            // DB or explicit render change — all surfaces need re-render
            const loop_t3 = std.time.microTimestamp();
            markAllDirty();
            const loop_t4 = std.time.microTimestamp();
            const total = loop_t4 - loop_t0;
            if (total > 2000) { // only log if > 2ms
                log.info("loop: total={d}us queue={d}us surface={d}us render={d}us", .{
                    total,
                    loop_t1 - loop_t0,
                    loop_t2 - loop_t1,
                    loop_t4 - loop_t3,
                });
            }
        } else if (anim_active) {
            // Only animations changed — only dynamic surfaces use animations
            markDynamicDirty();
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
                requestFrame(surf);
                if (renderSurface(surf)) {
                    surf.needs_render = false;
                }
            }
        },
    }
}

/// Mark a single surface dirty and kick off a render via frame callback.
fn markSurfaceDirty(surf: *Surface) void {
    if (surf.is_hot) return;
    if (!surf.configured or surf.egl_surface == c.EGL_NO_SURFACE) return;
    surf.needs_render = true;
    if (!surf.frame_pending) {
        // First change after idle — request frame callback BEFORE render
        // so it's associated with this commit, then render immediately
        // for responsiveness.
        requestFrame(surf);
        if (renderSurface(surf)) {
            surf.needs_render = false;
        }
    }
}

/// Mark all surfaces dirty and kick off a render via frame callbacks.
fn markAllDirty() void {
    for (surfaces[0..surface_count]) |*surf| {
        markSurfaceDirty(surf);
    }
}

/// Mark only dynamic surfaces dirty (for animation-only frames).
fn markDynamicDirty() void {
    for (surfaces[static_surface_count..surface_count]) |*surf| {
        markSurfaceDirty(surf);
    }
}

// ---------------------------------------------------------------------------
// Dynamic surface lifecycle
// ---------------------------------------------------------------------------

fn processSurfaceRequests() void {
    const requests = dispatch.drainSurfaceRequests();
    for (requests) |req| {
        defer _ = janet.c.janet_gcunroot(req);
        processSingleSurfaceRequest(req);
    }
}

fn processSingleSurfaceRequest(req: janet.Janet) void {
    const jc = janet.c;
    if (jc.janet_checktype(req, jc.JANET_TABLE) == 0 and
        jc.janet_checktype(req, jc.JANET_STRUCT) == 0)
    {
        log.warn("surface fx: expected table", .{});
        return;
    }

    // {:create {:name :launcher :layer :overlay ...}}
    const create_val = janet.janetGet(req, janet.kw("create"));
    if (jc.janet_checktype(create_val, jc.JANET_NIL) == 0) {
        createDynamicSurface(create_val);
        return;
    }

    // {:destroy :launcher}
    const destroy_val = janet.janetGet(req, janet.kw("destroy"));
    if (jc.janet_checktype(destroy_val, jc.JANET_NIL) == 0) {
        destroyDynamicSurface(destroy_val);
        return;
    }

    log.warn("surface fx: expected :create or :destroy key", .{});
}

fn findHotSurface() ?*Surface {
    for (surfaces[static_surface_count..surface_count]) |*surf| {
        if (surf.is_hot) return surf;
    }
    return null;
}

fn createHotSurface() void {
    if (surface_count >= MAX_SURFACES) return;
    if (findHotSurface() != null) return; // already have one

    const comp = compositor orelse return;
    const ls = layer_shell orelse return;

    const wl_surface = comp.createSurface() catch return;
    const layer_surface = ls.getLayerSurface(
        wl_surface,
        null,
        .overlay,
        cfg.namespace,
    ) catch {
        wl_surface.destroy();
        return;
    };

    // Pre-sized at typical launcher dimensions for instant reconfigure
    layer_surface.setSize(600, 460);
    layer_surface.setAnchor(.{ .top = true });
    layer_surface.setExclusiveZone(0);
    layer_surface.setMargin(200, 0, 0, 0);
    layer_surface.setKeyboardInteractivity(.none);

    // Empty input region so the hot surface doesn't steal pointer events
    if (comp.createRegion()) |region| {
        wl_surface.setInputRegion(region);
        region.destroy();
    } else |_| {}

    const surf = &surfaces[surface_count];
    surf.* = .{
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
        .is_dynamic = true,
        .is_hot = true,
    };
    layer_surface.setListener(*Surface, layerSurfaceListener, surf);
    wl_surface.commit();

    surface_count += 1;
    log.info("created hot surface", .{});
}

fn createDynamicSurface(spec: janet.Janet) void {
    const jc = janet.c;
    if (jc.janet_checktype(spec, jc.JANET_TABLE) == 0 and
        jc.janet_checktype(spec, jc.JANET_STRUCT) == 0)
    {
        log.warn("surface create: expected table spec", .{});
        return;
    }

    // Parse spec fields
    const name_val = janet.janetGet(spec, janet.kw("name"));
    if (jc.janet_checktype(name_val, jc.JANET_KEYWORD) == 0) {
        log.warn("surface create: missing :name keyword", .{});
        return;
    }

    // Check for duplicate name (skip hot surfaces — they have no name)
    const name_str = std.mem.span(jc.janet_unwrap_keyword(name_val));
    for (surfaces[static_surface_count..surface_count]) |*existing| {
        if (existing.is_dynamic and !existing.is_hot and existing.view_name_str != null) {
            const existing_name: []const u8 = existing.view_name_str.?;
            if (std.mem.eql(u8, existing_name, name_str)) {
                log.warn("surface create: '{s}' already exists", .{name_str});
                return;
            }
        }
    }

    // Parse optional fields with defaults for overlay/popup use
    const layer = parseJanetLayer(spec) orelse .overlay;
    const width = parseJanetUint(spec, "width") orelse 0;
    const height = parseJanetUint(spec, "height") orelse 0;
    const exclusive_zone = parseJanetInt(spec, "exclusive-zone") orelse 0;
    const ki = parseJanetKI(spec) orelse .none;
    const anchor = parseJanetAnchor(spec);
    const margin = parseJanetMargin(spec);

    // Try to claim a hot surface (overlay layer only — layer is fixed at creation)
    if (layer == .overlay) {
        if (findHotSurface()) |surf| {
            const ls_surf = surf.layer_surface.?;
            ls_surf.setSize(width, height);
            ls_surf.setAnchor(wlAnchor(anchor));
            ls_surf.setExclusiveZone(exclusive_zone);
            ls_surf.setMargin(margin.top, margin.right, margin.bottom, margin.left);
            ls_surf.setKeyboardInteractivity(wlKeyboardInteractivity(ki));

            // Restore full input region now that the surface is active
            surf.wl_surface.?.setInputRegion(null);

            surf.view_name_str = std.mem.span(jc.janet_unwrap_keyword(name_val));
            surf.is_hot = false;

            // If dimensions match, we can render immediately without waiting
            // for a configure round-trip — EGL window is already the right size.
            const dims_match = (surf.width == width and surf.height == height);
            if (dims_match and surf.egl_surface != c.EGL_NO_SURFACE) {
                // Keep configured = true, render this frame
                surf.needs_render = true;
            } else {
                surf.configured = false;
            }
            surf.wl_surface.?.commit();

            log.info("claimed hot surface for '{s}' (immediate={})", .{ name_str, dims_match });
            return;
        }
    }

    // Fallback: create from scratch
    if (surface_count >= MAX_SURFACES) {
        log.warn("surface create: no free surface slots", .{});
        return;
    }

    const comp = compositor orelse return;
    const ls = layer_shell orelse return;

    const wl_surface = comp.createSurface() catch {
        log.warn("surface create: wl_compositor.create_surface failed", .{});
        return;
    };

    const layer_surface = ls.getLayerSurface(
        wl_surface,
        null, // compositor chooses output
        wlLayer(layer),
        cfg.namespace,
    ) catch {
        log.warn("surface create: get_layer_surface failed", .{});
        wl_surface.destroy();
        return;
    };

    layer_surface.setSize(width, height);
    layer_surface.setAnchor(wlAnchor(anchor));
    layer_surface.setExclusiveZone(exclusive_zone);
    layer_surface.setMargin(margin.top, margin.right, margin.bottom, margin.left);
    layer_surface.setKeyboardInteractivity(wlKeyboardInteractivity(ki));

    const surf = &surfaces[surface_count];
    surf.* = .{
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
        .is_dynamic = true,
        .view_name_str = std.mem.span(jc.janet_unwrap_keyword(name_val)),
    };
    layer_surface.setListener(*Surface, layerSurfaceListener, surf);
    wl_surface.commit();

    surface_count += 1;
    log.info("created dynamic surface '{s}'", .{name_str});
}

fn destroyDynamicSurface(name_val: janet.Janet) void {
    const jc = janet.c;
    if (jc.janet_checktype(name_val, jc.JANET_KEYWORD) == 0) {
        log.warn("surface destroy: expected keyword name", .{});
        return;
    }

    const name_str = std.mem.span(jc.janet_unwrap_keyword(name_val));

    for (surfaces[static_surface_count..surface_count], static_surface_count..surface_count) |*surf, idx| {
        if (surf.is_dynamic and !surf.is_hot and surf.view_name_str != null) {
            const surf_name: []const u8 = surf.view_name_str.?;
            if (std.mem.eql(u8, surf_name, name_str)) {
                // Reclaim as hot surface if no hot surface exists
                if (findHotSurface() == null) {
                    const ls_surf = surf.layer_surface.?;
                    ls_surf.setSize(600, 460);
                    ls_surf.setAnchor(.{ .top = true });
                    ls_surf.setExclusiveZone(0);
                    ls_surf.setMargin(200, 0, 0, 0);
                    ls_surf.setKeyboardInteractivity(.none);

                    // Empty input region so hot surface doesn't steal pointer events
                    const comp = compositor orelse unreachable;
                    if (comp.createRegion()) |region| {
                        surf.wl_surface.?.setInputRegion(region);
                        region.destroy();
                    } else |_| {}

                    surf.view_name_str = null;
                    surf.is_hot = true;
                    surf.configured = false;
                    surf.needs_render = false;
                    surf.wl_surface.?.commit();

                    log.info("reclaimed '{s}' as hot surface", .{name_str});
                    return;
                }

                // Already have a hot surface — fully destroy this one
                surf.deinitEgl();
                if (surf.layer_surface) |ls_surf2| ls_surf2.destroy();
                if (surf.wl_surface) |ws| ws.destroy();

                // Swap with last and shrink
                surface_count -= 1;
                if (idx < surface_count) {
                    surfaces[idx] = surfaces[surface_count];
                }
                surfaces[surface_count] = .{};

                log.info("destroyed dynamic surface '{s}'", .{name_str});
                return;
            }
        }
    }

    log.warn("surface destroy: '{s}' not found", .{name_str});
}

// --- Janet spec parsers for surface creation ---

fn parseJanetLayer(spec: janet.Janet) ?Config.Layer {
    const val = janet.janetGet(spec, janet.kw("layer"));
    if (janet.c.janet_checktype(val, janet.c.JANET_KEYWORD) == 0) return null;
    const name = std.mem.span(janet.c.janet_unwrap_keyword(val));
    return std.meta.stringToEnum(Config.Layer, name);
}

fn parseJanetUint(spec: janet.Janet, key: [:0]const u8) ?u32 {
    const val = janet.janetGet(spec, janet.kw(key));
    if (janet.c.janet_checktype(val, janet.c.JANET_NUMBER) == 0) return null;
    const n = janet.c.janet_unwrap_number(val);
    if (n < 0) return null;
    return @intFromFloat(n);
}

fn parseJanetInt(spec: janet.Janet, key: [:0]const u8) ?i32 {
    const val = janet.janetGet(spec, janet.kw(key));
    if (janet.c.janet_checktype(val, janet.c.JANET_NUMBER) == 0) return null;
    return @intFromFloat(janet.c.janet_unwrap_number(val));
}

fn parseJanetKI(spec: janet.Janet) ?Config.KeyboardInteractivity {
    const val = janet.janetGet(spec, janet.kw("keyboard-interactivity"));
    if (janet.c.janet_checktype(val, janet.c.JANET_KEYWORD) == 0) return null;
    const name = std.mem.span(janet.c.janet_unwrap_keyword(val));
    if (std.mem.eql(u8, name, "exclusive")) return .exclusive;
    if (std.mem.eql(u8, name, "on-demand")) return .on_demand;
    if (std.mem.eql(u8, name, "none")) return .none;
    return null;
}

fn parseJanetAnchor(spec: janet.Janet) Config.Anchor {
    const val = janet.janetGet(spec, janet.kw("anchor"));
    if (janet.c.janet_checktype(val, janet.c.JANET_TABLE) == 0 and
        janet.c.janet_checktype(val, janet.c.JANET_STRUCT) == 0)
        return .{};
    return .{
        .top = janetBoolField(val, "top"),
        .bottom = janetBoolField(val, "bottom"),
        .left = janetBoolField(val, "left"),
        .right = janetBoolField(val, "right"),
    };
}

fn parseJanetMargin(spec: janet.Janet) Config.Margin {
    const val = janet.janetGet(spec, janet.kw("margin"));
    if (janet.c.janet_checktype(val, janet.c.JANET_TABLE) == 0 and
        janet.c.janet_checktype(val, janet.c.JANET_STRUCT) == 0)
        return .{};
    return .{
        .top = janetIntField(val, "top"),
        .right = janetIntField(val, "right"),
        .bottom = janetIntField(val, "bottom"),
        .left = janetIntField(val, "left"),
    };
}

fn janetBoolField(collection: janet.Janet, key: [:0]const u8) bool {
    const val = janet.janetGet(collection, janet.kw(key));
    return janet.c.janet_checktype(val, janet.c.JANET_BOOLEAN) != 0 and
        janet.c.janet_unwrap_boolean(val) != 0;
}

fn janetIntField(collection: janet.Janet, key: [:0]const u8) i32 {
    const val = janet.janetGet(collection, janet.kw(key));
    if (janet.c.janet_checktype(val, janet.c.JANET_NUMBER) == 0) return 0;
    return @intFromFloat(janet.c.janet_unwrap_number(val));
}

/// Render a frame for a surface. Returns true on success, false on failure.
fn renderSurface(surf: *Surface) bool {
    if (!surf.configured or surf.egl_surface == c.EGL_NO_SURFACE) return false;

    const t0 = std.time.microTimestamp();
    if (!surf.makeCurrent()) return false;

    const w: f32 = @floatFromInt(surf.width);
    const h: f32 = @floatFromInt(surf.height);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, text_renderer.getAtlasTexture());

    // Set pointer state for Clay hit testing — only the surface the pointer
    // is on gets valid coordinates, others get off-screen (-1, -1).
    const is_pointer_surface = pointer_surface != null and surf.wl_surface == pointer_surface;
    if (is_pointer_surface) {
        Layout.setPointerState(.{ pointer_x, pointer_y }, pointer_button_pressed);
    } else {
        Layout.setPointerState(.{ -1, -1 }, false);
    }

    renderer.begin(w, h);
    layout.setDimensions(w, h);

    const t2 = std.time.microTimestamp();
    layout.beginLayout();
    dispatch.prepareRender();
    hiccup_mod.beginPass();
    const view_name = if (surf.view_name_str) |name| janet.kw(name) else janet.c.janet_wrap_nil();
    _ = dispatch.renderView(view_name);
    const t2a = std.time.microTimestamp();
    layout.endLayout();
    const t2b = std.time.microTimestamp();
    hiccup_mod.endPass();
    const t3 = std.time.microTimestamp();

    // After layout: track hover changes and check for clicks on pointer surface
    if (is_pointer_surface) {
        const over_ids = clay.getPointerOverIds();

        // Build current hover set from Clay's pointer-over elements
        var curr_strs: [MAX_HOVER_IDS][MAX_HOVER_ID_LEN]u8 = undefined;
        var curr_lens: [MAX_HOVER_IDS]usize = undefined;
        var curr_count: usize = 0;
        for (over_ids) |eid| {
            const len: usize = @intCast(@max(0, eid.string_id.length));
            if (len > 0 and len <= MAX_HOVER_ID_LEN and curr_count < MAX_HOVER_IDS) {
                @memcpy(curr_strs[curr_count][0..len], eid.string_id.chars[0..len]);
                curr_lens[curr_count] = len;
                curr_count += 1;
            }
        }

        // Dispatch :pointer-leave for elements no longer hovered
        for (prev_hover_strs[0..prev_hover_count], prev_hover_lens[0..prev_hover_count]) |prev_str, prev_len| {
            var found = false;
            for (curr_strs[0..curr_count], curr_lens[0..curr_count]) |curr_str, curr_len| {
                if (prev_len == curr_len and std.mem.eql(u8, prev_str[0..prev_len], curr_str[0..curr_len])) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const str_val = janet.c.janet_stringv(&prev_str, @as(i32, @intCast(prev_len)));
                janet.c.janet_gcroot(str_val);
                defer _ = janet.c.janet_gcunroot(str_val);
                dispatch.enqueue(janet.makeEventArgs("pointer-leave", &.{str_val}));
            }
        }

        // Dispatch :pointer-enter for newly hovered elements
        for (curr_strs[0..curr_count], curr_lens[0..curr_count]) |curr_str, curr_len| {
            var found = false;
            for (prev_hover_strs[0..prev_hover_count], prev_hover_lens[0..prev_hover_count]) |prev_str, prev_len| {
                if (curr_len == prev_len and std.mem.eql(u8, curr_str[0..curr_len], prev_str[0..prev_len])) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const str_val = janet.c.janet_stringv(&curr_str, @as(i32, @intCast(curr_len)));
                janet.c.janet_gcroot(str_val);
                defer _ = janet.c.janet_gcunroot(str_val);
                dispatch.enqueue(janet.makeEventArgs("pointer-enter", &.{str_val}));
            }
        }

        // Update previous hover state
        for (0..curr_count) |i| {
            @memcpy(prev_hover_strs[i][0..curr_lens[i]], curr_strs[i][0..curr_lens[i]]);
            prev_hover_lens[i] = curr_lens[i];
        }
        prev_hover_count = curr_count;

        _ = dispatch.processQueue();
    }

    const t4 = std.time.microTimestamp();
    renderer.end();
    _ = c.eglSwapBuffers(egl_display, surf.egl_surface);
    const t5 = std.time.microTimestamp();

    const name = if (surf.view_name_str) |n| n else "bar";
    const total = t5 - t0;
    if (total > 1000) { // only log if > 1ms
        log.info("render {s}: total={d}us view={d}us clay={d}us pass={d}us draw={d}us swap={d}us", .{
            name,
            total,
            t2a - t2,
            t2b - t2a,
            t3 - t2b,
            t4 - t3,
            t5 - t4,
        });
    }
    return true;
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
                seat.?.setListener(*const void, seatListener, &{});
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
            } else if (surf.is_dynamic) {
                // Dynamic surfaces need EGL init on first configure
                surf.initEgl() catch |err| {
                    log.warn("dynamic surface EGL init failed: {}", .{err});
                    return;
                };
            }

            if (surf.is_hot) {
                // Commit a transparent buffer so the compositor maps the surface
                if (surf.makeCurrent()) {
                    c.glViewport(0, 0, @intCast(surf.width), @intCast(surf.height));
                    c.glClearColor(0, 0, 0, 0);
                    c.glClear(c.GL_COLOR_BUFFER_BIT);
                    _ = c.eglSwapBuffers(egl_display, surf.egl_surface);
                }
                return;
            }

            surf.needs_render = true;
            requestFrame(surf);
        },
        .closed => {
            if (surf.is_dynamic) {
                // Dynamic surface closed by compositor — clean up
                surf.deinitEgl();
                surf.configured = false;
                log.info("dynamic surface closed by compositor", .{});
            } else {
                running = false;
            }
        },
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, _: *const void) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.pointer) {
                if (pointer == null) {
                    pointer = seat.?.getPointer() catch return;
                    pointer.?.setListener(*const void, pointerListener, &{});
                }
            } else {
                if (pointer) |p| {
                    p.release();
                    pointer = null;
                    pointer_surface = null;
                    pointer_x = -1;
                    pointer_y = -1;
                    pointer_button_pressed = false;
                    pointer_button_just_released = false;
                }
            }

            if (caps.capabilities.keyboard) {
                if (keyboard == null) {
                    keyboard = seat.?.getKeyboard() catch return;
                    keyboard.?.setListener(*const void, keyboardListener, &{});
                }
            } else {
                if (keyboard) |k| {
                    k.release();
                    keyboard = null;
                    keyboard_focus_surface = null;
                }
            }
        },
        .name => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *const void) void {
    switch (event) {
        .enter => |ev| {
            pointer_surface = ev.surface;
            pointer_x = @floatCast(ev.surface_x.toDouble());
            pointer_y = @floatCast(ev.surface_y.toDouble());
            pointer_surface_changed = true;
        },
        .leave => |_| {
            // Dispatch :pointer-leave for all previously hovered elements
            for (prev_hover_strs[0..prev_hover_count], prev_hover_lens[0..prev_hover_count]) |prev_str, prev_len| {
                const str_val = janet.c.janet_stringv(&prev_str, @as(i32, @intCast(prev_len)));
                janet.c.janet_gcroot(str_val);
                defer _ = janet.c.janet_gcunroot(str_val);
                dispatch.enqueue(janet.makeEventArgs("pointer-leave", &.{str_val}));
            }
            prev_hover_count = 0;

            pointer_surface = null;
            pointer_x = -1;
            pointer_y = -1;
            pointer_button_pressed = false;
            pointer_button_just_released = false;
            pointer_scroll_y = 0;
            pointer_surface_changed = true;
        },
        .motion => |ev| {
            pointer_x = @floatCast(ev.surface_x.toDouble());
            pointer_y = @floatCast(ev.surface_y.toDouble());
        },
        .button => |ev| {
            if (ev.button == BTN_LEFT) {
                switch (ev.state) {
                    .pressed => {
                        pointer_button_pressed = true;
                    },
                    .released => {
                        pointer_button_pressed = false;
                        pointer_button_just_released = true;
                    },
                    _ => {},
                }
            }
        },
        .axis => |ev| {
            if (ev.axis == .vertical_scroll) {
                pointer_scroll_y += ev.value.toDouble();
            }
        },
        .frame => {
            // Dispatch click events from button release using cached hover state
            if (pointer_button_just_released) {
                pointer_button_just_released = false;
                for (prev_hover_strs[0..prev_hover_count], prev_hover_lens[0..prev_hover_count]) |hover_str, hover_len| {
                    const str_val = janet.c.janet_stringv(&hover_str, @as(i32, @intCast(hover_len)));
                    janet.c.janet_gcroot(str_val);
                    defer _ = janet.c.janet_gcunroot(str_val);
                    dispatch.enqueue(janet.makeEventArgs("click", &.{str_val}));
                }
            }

            // Dispatch scroll events accumulated during this frame
            if (pointer_scroll_y != 0) {
                const dir_str: [:0]const u8 = if (pointer_scroll_y > 0) "down" else "up";
                const dir = janet.c.janet_stringv(dir_str.ptr, @as(i32, @intCast(dir_str.len)));
                janet.c.janet_gcroot(dir);
                defer _ = janet.c.janet_gcunroot(dir);

                // Find hovered element IDs to include in scroll event
                if (prev_hover_count > 0) {
                    const top_str = prev_hover_strs[prev_hover_count - 1];
                    const top_len = prev_hover_lens[prev_hover_count - 1];
                    const id_val = janet.c.janet_stringv(&top_str, @as(i32, @intCast(top_len)));
                    janet.c.janet_gcroot(id_val);
                    defer _ = janet.c.janet_gcunroot(id_val);
                    dispatch.enqueue(janet.makeEventArgs("scroll", &.{ dir, id_val }));
                } else {
                    dispatch.enqueue(janet.makeEventArgs("scroll", &.{dir}));
                }
                pointer_scroll_y = 0;
            }

            // Pointer state has been atomically updated — re-render affected surfaces.
            // Surface transitions (enter/leave) mark all dirty to clear stale hover
            // state on the old surface. Motion/button only dirties the pointer surface.
            if (pointer_surface_changed) {
                markAllDirty();
                pointer_surface_changed = false;
            } else if (pointer_surface) |ps| {
                for (surfaces[0..surface_count]) |*surf| {
                    if (surf.wl_surface == ps) {
                        markSurfaceDirty(surf);
                        break;
                    }
                }
            }
        },
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, _: *const void) void {
    switch (event) {
        .keymap => |km| {
            defer std.posix.close(km.fd);
            if (km.format != .xkb_v1) return;

            const map_data = std.posix.mmap(
                null,
                km.size,
                std.posix.PROT.READ,
                .{ .TYPE = .SHARED },
                km.fd,
                0,
            ) catch return;
            defer std.posix.munmap(map_data);

            if (xkb_ctx == null) {
                xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
                if (xkb_ctx == null) return;
            }

            if (xkb_st) |s| xkb.xkb_state_unref(s);
            if (xkb_km) |m| xkb.xkb_keymap_unref(m);
            xkb_st = null;
            xkb_km = null;

            xkb_km = xkb.xkb_keymap_new_from_string(
                xkb_ctx,
                @ptrCast(map_data.ptr),
                xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
                xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
            );
            if (xkb_km) |m| {
                xkb_st = xkb.xkb_state_new(m);
            }
        },
        .enter => |ev| {
            keyboard_focus_surface = ev.surface;
            dispatch.enqueue(janet.makeEvent("keyboard-enter"));
        },
        .leave => |_| {
            keyboard_focus_surface = null;
            dispatch.enqueue(janet.makeEvent("keyboard-leave"));
        },
        .key => |ev| {
            const state = xkb_st orelse return;
            const keycode: xkb.xkb_keycode_t = ev.key + 8;
            const pressed = ev.state == .pressed;

            const sym = xkb.xkb_state_key_get_one_sym(state, keycode);
            var sym_name: [64]u8 = undefined;
            const sym_len = xkb.xkb_keysym_get_name(sym, &sym_name, sym_name.len);
            if (sym_len < 1) return;
            const sym_ulen: usize = @intCast(sym_len);

            var utf8_buf: [8]u8 = undefined;
            const utf8_len = xkb.xkb_state_key_get_utf8(state, keycode, &utf8_buf, utf8_buf.len);
            const utf8_ulen: usize = if (utf8_len > 0) @intCast(utf8_len) else 0;

            const ctrl = xkb.xkb_state_mod_name_is_active(state, "Control", xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
            const alt = xkb.xkb_state_mod_name_is_active(state, "Mod1", xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
            const shift = xkb.xkb_state_mod_name_is_active(state, "Shift", xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
            const super = xkb.xkb_state_mod_name_is_active(state, "Mod4", xkb.XKB_STATE_MODS_EFFECTIVE) == 1;

            dispatchKeyEvent(
                sym_name[0..sym_ulen],
                utf8_buf[0..utf8_ulen],
                pressed,
                ctrl,
                alt,
                shift,
                super,
            );
        },
        .modifiers => |ev| {
            if (xkb_st) |state| {
                _ = xkb.xkb_state_update_mask(
                    state,
                    ev.mods_depressed,
                    ev.mods_latched,
                    ev.mods_locked,
                    0,
                    0,
                    ev.group,
                );
            }
        },
        .repeat_info => {},
    }
}

fn dispatchKeyEvent(
    sym_name: []const u8,
    utf8: []const u8,
    pressed: bool,
    ctrl: bool,
    alt: bool,
    shift: bool,
    super: bool,
) void {
    const jc = janet.c;

    const st = jc.janet_struct_begin(7);
    jc.janet_struct_put(st, janet.kw("sym"), jc.janet_stringv(sym_name.ptr, @as(i32, @intCast(sym_name.len))));
    jc.janet_struct_put(st, janet.kw("text"), jc.janet_stringv(utf8.ptr, @as(i32, @intCast(utf8.len))));
    jc.janet_struct_put(st, janet.kw("pressed"), jc.janet_wrap_boolean(@intFromBool(pressed)));
    jc.janet_struct_put(st, janet.kw("ctrl"), jc.janet_wrap_boolean(@intFromBool(ctrl)));
    jc.janet_struct_put(st, janet.kw("alt"), jc.janet_wrap_boolean(@intFromBool(alt)));
    jc.janet_struct_put(st, janet.kw("shift"), jc.janet_wrap_boolean(@intFromBool(shift)));
    jc.janet_struct_put(st, janet.kw("super"), jc.janet_wrap_boolean(@intFromBool(super)));
    const key_info = jc.janet_wrap_struct(jc.janet_struct_end(st));

    dispatch.enqueue(janet.makeEventArgs("key", &.{key_info}));
}
