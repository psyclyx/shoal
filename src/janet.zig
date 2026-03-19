const std = @import("std");
const hiccup = @import("hiccup.zig");
const animation = @import("animation.zig");
const jutil = @import("jutil.zig");
const spawn_mod = @import("spawn.zig");
const ipc_mod = @import("ipc.zig");
const theme_mod = @import("theme.zig");
const log = std.log.scoped(.janet);

pub const c = jutil.c;
pub const Janet = jutil.Janet;
pub const JanetTable = jutil.JanetTable;

// Re-export helpers used by other modules (main.zig, hiccup.zig)
pub const kw = jutil.kw;
pub const janetGet = jutil.janetGet;
pub const makeTuple = jutil.makeTuple;
pub const makeEvent = jutil.makeEvent;
pub const makeEventArgs = jutil.makeEventArgs;
pub const janetIndexedView = jutil.janetIndexedView;
pub const IndexedView = jutil.IndexedView;

const boot_source = @embedFile("shoal.janet");
const json_source = @embedFile("json.janet");
const tidepool_source = @embedFile("tidepool.janet");
const clock_source = @embedFile("clock.janet");
const sysinfo_source = @embedFile("sysinfo.janet");
const bar_source = @embedFile("bar.janet");
const launcher_source = @embedFile("launcher.janet");
const osd_source = @embedFile("osd.janet");
const dmenu_source = @embedFile("dmenu.janet");

/// Initialize the Janet VM. Must be called before any other Janet operations.
pub fn init() !void {
    if (c.janet_init() != 0) return error.JanetInitFailed;
    log.info("Janet VM initialized (version {s})", .{c.JANET_VERSION});
}

/// Shut down the Janet VM and free all resources.
pub fn deinit() void {
    c.janet_deinit();
    log.info("Janet VM deinitialized", .{});
}

/// Create a core environment table with all Janet builtins.
pub fn coreEnv() *JanetTable {
    return c.janet_core_env(null);
}

/// Evaluate a Janet string in the given environment.
/// Returns the result value, or an error if evaluation failed.
pub fn doString(env: *JanetTable, source: [:0]const u8, source_path: [:0]const u8) !Janet {
    var out: Janet = undefined;
    const status = c.janet_dostring(env, source.ptr, source_path.ptr, &out);
    if (status != 0) return error.JanetEvalFailed;
    return out;
}

/// Extract a number from a Janet value.
pub fn unwrapNumber(val: Janet) !f64 {
    if (c.janet_checktype(val, c.JANET_NUMBER) == 0) return error.JanetTypeMismatch;
    return c.janet_unwrap_number(val);
}

/// Extract a string from a Janet value as a Zig slice.
pub fn unwrapString(val: Janet) ![]const u8 {
    if (c.janet_checktype(val, c.JANET_STRING) == 0) return error.JanetTypeMismatch;
    const s = c.janet_unwrap_string(val);
    const len = c.janet_string_length(s);
    return s[0..@intCast(len)];
}

// ---------------------------------------------------------------------------
// Dispatch — the reactive event loop bridge
// ---------------------------------------------------------------------------

/// fx execution order (indices into the fx_order array)
const fx_order = [_][:0]const u8{
    "db",
    "anim",
    "dispatch-n",
    "dispatch",
    "timer",
    "spawn",
    "exec",
    "ipc",
    "surface",
    "stdout",
    "exit",
    "render",
};

const MAX_QUEUED_EVENTS = 256;
const MAX_TIMERS = 64;
const MAX_ANIMS = 64;
const MAX_SURFACE_REQUESTS = 8;

const AnimSlot = struct {
    active: bool = false,
    id: Janet = undefined, // keyword, GC-rooted when active
    current: f64 = 0,
    target: f64 = 0,
    start: f64 = 0,
    progress: f32 = 0,
    duration: f32 = 0,
    easing: animation.Easing = .linear,
    on_complete: Janet = undefined, // event tuple or nil, GC-rooted when active
};

const Timer = struct {
    active: bool = false,
    fire_time: f64 = 0, // monotonic seconds
    event: Janet = undefined, // GC-rooted when active
    repeat: bool = false,
    interval: f64 = 0, // seconds, for repeating timers
    id: Janet = undefined, // keyword id for cancellation, or nil
};

pub const Dispatch = struct {
    env: *JanetTable,
    db: Janet,
    render_dirty: bool = false,

    // Event queue (ring buffer)
    event_queue: [MAX_QUEUED_EVENTS]Janet = undefined,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,

    // Timers
    timers: [MAX_TIMERS]Timer = [_]Timer{.{}} ** MAX_TIMERS,

    // Animation pool
    anims: [MAX_ANIMS]AnimSlot = [_]AnimSlot{.{}} ** MAX_ANIMS,

    // Spawn pool (child processes)
    spawns: spawn_mod.SpawnPool = .{},

    // IPC connection pool (Unix sockets)
    ipcs: ipc_mod.IpcPool = .{},

    // Surface lifecycle requests (processed by main.zig)
    surface_requests: [MAX_SURFACE_REQUESTS]Janet = undefined,
    surface_request_count: usize = 0,

    // Cached function references (set by initBoot)
    fn_get_handler: Janet = undefined,
    fn_get_cofx_injector: Janet = undefined,
    fn_get_fx_executor: Janet = undefined,
    fn_bump_generation: Janet = undefined,
    fn_set_current_db: Janet = undefined,
    fn_get_view_fn: Janet = undefined,

    /// Load the shoal boot file into a fresh environment. Sets up registries.
    pub fn initBoot(self: *Dispatch, theme: theme_mod.Theme, dmenu_mode: bool) !void {
        // Set global dispatch pointer for Janet C functions
        global_dispatch = self;

        // GC root the db before any janet_dostring calls — the db table is
        // only referenced from the Zig struct (invisible to Janet's GC).
        c.janet_gcroot(self.db);

        // Register C functions before evaluating boot source
        c.janet_cfuns(self.env, null, &anim_cfun);

        // Evaluate boot source
        var out: Janet = undefined;
        const status = c.janet_dostring(
            self.env,
            boot_source.ptr,
            "shoal.janet",
            &out,
        );
        if (status != 0) return error.BootFailed;

        // Load JSON decoder (used by tidepool and other data sources)
        var json_out: Janet = undefined;
        const json_status = c.janet_dostring(
            self.env,
            json_source.ptr,
            "json.janet",
            &json_out,
        );
        if (json_status != 0) return error.JsonBootFailed;

        // Inject theme colors into the environment (before modules which read them)
        self.injectTheme(theme);

        if (dmenu_mode) {
            self.loadDmenuModule();
        } else {
            // Load modules: user config dir takes precedence over embedded defaults.
            self.loadModules();
        }

        // Cache lookup functions from the environment
        self.fn_get_handler = envLookup(self.env, "get-handler") orelse return error.BootMissingGetHandler;
        self.fn_get_cofx_injector = envLookup(self.env, "get-cofx-injector") orelse return error.BootMissingGetCofxInjector;
        self.fn_get_fx_executor = envLookup(self.env, "get-fx-executor") orelse return error.BootMissingGetFxExecutor;
        self.fn_bump_generation = envLookup(self.env, "bump-generation") orelse return error.BootMissingBumpGeneration;
        self.fn_set_current_db = envLookup(self.env, "set-current-db") orelse return error.BootMissingSetCurrentDb;
        self.fn_get_view_fn = envLookup(self.env, "get-view-fn") orelse return error.BootMissingGetViewFn;

        // Initialize the hiccup walker (pre-intern keywords)
        hiccup.init();

        log.info("shoal boot loaded, dispatch ready", .{});
    }

    /// Enqueue an event for processing. The event is GC-rooted until dequeued.
    pub fn enqueue(self: *Dispatch, event: Janet) void {
        if (self.queue_count >= MAX_QUEUED_EVENTS) {
            log.warn("event queue full, dropping event", .{});
            return;
        }
        c.janet_gcroot(event);
        self.event_queue[self.queue_tail] = event;
        self.queue_tail = (self.queue_tail + 1) % MAX_QUEUED_EVENTS;
        self.queue_count += 1;
    }

    /// Process all queued events. Events enqueued during processing (via :dispatch fx)
    /// are processed in the same batch. Returns true if any events were processed.
    pub fn processQueue(self: *Dispatch) bool {
        if (self.queue_count == 0) return false;
        // Drain until empty (handlers may enqueue more events)
        while (self.queue_count > 0) {
            const event = self.event_queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % MAX_QUEUED_EVENTS;
            self.queue_count -= 1;
            self.dispatchImmediate(event);
            _ = c.janet_gcunroot(event);
        }
        return true;
    }

    /// Dispatch a single event immediately (not queued). Used internally.
    fn dispatchImmediate(self: *Dispatch, event: Janet) void {
        // Extract event-id (first element of tuple)
        const event_id = tupleFirst(event) orelse {
            log.warn("dispatch: event is not a tuple or is empty", .{});
            return;
        };

        // Look up handler
        const handler_entry = self.pcall(self.fn_get_handler, &.{event_id}) orelse return;
        if (c.janet_checktype(handler_entry, c.JANET_NIL) != 0) {
            if (c.janet_checktype(event_id, c.JANET_KEYWORD) != 0) {
                const kw_str = std.mem.span(c.janet_unwrap_keyword(event_id));
                log.debug("dispatch: no handler for :{s}", .{kw_str});
            } else {
                log.debug("dispatch: no handler for event", .{});
            }
            return;
        }
        // Root handler_entry — for composed multi-handlers, get-handler returns
        // a freshly allocated struct not stored in any registry. Without rooting,
        // buildCofx's janet_table(4) can trigger GC and collect it.
        c.janet_gcroot(handler_entry);
        defer _ = c.janet_gcunroot(handler_entry);

        // handler_entry is {:fn handler-fn :cofx [...]}
        const handler_fn = tableGet(handler_entry, "fn") orelse {
            log.warn("dispatch: handler entry missing :fn", .{});
            return;
        };
        const cofx_keys = tableGet(handler_entry, "cofx") orelse c.janet_wrap_nil();

        // Build cofx table (returned GC-rooted, must unroot)
        const cofx = self.buildCofx(event, cofx_keys);
        defer _ = c.janet_gcunroot(cofx);

        // Call handler: (handler-fn cofx event) → fx-map
        const fx_map = self.pcall(handler_fn, &.{ cofx, event }) orelse return;
        c.janet_gcroot(fx_map);
        defer _ = c.janet_gcunroot(fx_map);

        // Execute effects
        self.executeFx(fx_map);
    }

    /// Build the cofx table with built-in values, then inject declared cofx.
    /// Caller must call janet_gcunroot on the returned value.
    fn buildCofx(self: *Dispatch, event: Janet, cofx_keys: Janet) Janet {
        const cofx_table = c.janet_table(4);
        const cofx_val = c.janet_wrap_table(cofx_table);
        c.janet_gcroot(cofx_val);

        // Built-in cofx: :db, :event, :now
        c.janet_table_put(cofx_table, kw("db"), self.db);
        c.janet_table_put(cofx_table, kw("event"), event);
        c.janet_table_put(cofx_table, kw("now"), c.janet_wrap_number(monotonicNow()));

        // Inject declared cofx
        if (c.janet_checktype(cofx_keys, c.JANET_TUPLE) != 0 or
            c.janet_checktype(cofx_keys, c.JANET_ARRAY) != 0)
        {
            const view = janetIndexedView(cofx_keys);
            if (view.items) |items| {
                for (0..@intCast(view.len)) |i| {
                    const cofx_id = items[i];
                    const injector = self.pcall(self.fn_get_cofx_injector, &.{cofx_id}) orelse continue;
                    if (c.janet_checktype(injector, c.JANET_NIL) != 0) {
                        log.warn("dispatch: unknown cofx injector requested", .{});
                        continue;
                    }
                    // Call injector: (injector cofx-table) → updated cofx-table
                    _ = self.pcall(injector, &.{cofx_val}) orelse continue;
                }
            }
        }

        return cofx_val;
    }

    /// Execute effects from an fx map in defined order.
    fn executeFx(self: *Dispatch, fx_map: Janet) void {
        if (c.janet_checktype(fx_map, c.JANET_NIL) != 0) return;

        // Must be a table or struct
        if (c.janet_checktype(fx_map, c.JANET_TABLE) == 0 and
            c.janet_checktype(fx_map, c.JANET_STRUCT) == 0)
        {
            log.warn("dispatch: handler returned non-table fx map", .{});
            return;
        }

        // Process fx in defined order
        for (fx_order) |fx_name| {
            const fx_key = kw(fx_name);
            const fx_val = janetGet(fx_map, fx_key);
            if (c.janet_checktype(fx_val, c.JANET_NIL) != 0) continue;

            if (std.mem.eql(u8, fx_name, "db")) {
                self.setDb(fx_val);
                _ = self.pcall(self.fn_bump_generation, &.{});
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "anim")) {
                self.handleAnimFx(fx_val);
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "render")) {
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "dispatch")) {
                self.enqueue(fx_val);
            } else if (std.mem.eql(u8, fx_name, "dispatch-n")) {
                self.enqueueMultiple(fx_val);
            } else if (std.mem.eql(u8, fx_name, "timer")) {
                self.handleTimerFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "spawn")) {
                self.spawns.handleFx(fx_val, self.eventSink());
            } else if (std.mem.eql(u8, fx_name, "exec")) {
                handleExecFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "ipc")) {
                self.ipcs.handleFx(fx_val, self.eventSink());
            } else if (std.mem.eql(u8, fx_name, "surface")) {
                self.enqueueSurfaceRequest(fx_val);
            } else if (std.mem.eql(u8, fx_name, "stdout")) {
                handleStdoutFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "exit")) {
                handleExitFx(fx_val);
            } else {
                // Look up registered fx executor
                const executor = self.pcall(self.fn_get_fx_executor, &.{fx_key}) orelse continue;
                if (c.janet_checktype(executor, c.JANET_NIL) != 0) {
                    log.warn("dispatch: unknown fx", .{});
                    continue;
                }
                _ = self.pcall(executor, &.{fx_val}) orelse continue;
            }
        }
    }

    fn enqueueMultiple(self: *Dispatch, events: Janet) void {
        const view = janetIndexedView(events);
        if (view.items) |items| {
            for (0..@intCast(view.len)) |i| {
                self.enqueue(items[i]);
            }
        }
    }

    /// Handle :timer fx. Value is a table with:
    ///   {:delay N :event [...]}              — one-shot timer
    ///   {:delay N :event [...] :repeat true} — repeating timer
    ///   {:id :name :cancel true}             — cancel a timer by id
    /// Optional :id key for named timers (enables cancellation/replacement).
    fn handleTimerFx(self: *Dispatch, val: Janet) void {
        // Handle array of timer specs
        if (c.janet_checktype(val, c.JANET_TUPLE) != 0 or
            c.janet_checktype(val, c.JANET_ARRAY) != 0)
        {
            const view = janetIndexedView(val);
            if (view.items) |items| {
                for (0..@intCast(view.len)) |i| {
                    self.handleTimerFx(items[i]);
                }
            }
            return;
        }

        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("timer fx: expected table or array", .{});
            return;
        }

        // Check for cancel
        const cancel_val = janetGet(val, kw("cancel"));
        if (c.janet_checktype(cancel_val, c.JANET_NIL) == 0) {
            const timer_id = janetGet(val, kw("id"));
            if (c.janet_checktype(timer_id, c.JANET_NIL) == 0) {
                self.cancelTimer(timer_id);
            }
            return;
        }

        // Create timer
        const delay_val = janetGet(val, kw("delay"));
        if (c.janet_checktype(delay_val, c.JANET_NUMBER) == 0) {
            log.warn("timer fx: missing :delay", .{});
            return;
        }
        const delay = c.janet_unwrap_number(delay_val);

        const event_val = janetGet(val, kw("event"));
        if (c.janet_checktype(event_val, c.JANET_TUPLE) == 0) {
            log.warn("timer fx: missing :event tuple", .{});
            return;
        }

        const repeat_val = janetGet(val, kw("repeat"));
        const repeat = c.janet_checktype(repeat_val, c.JANET_BOOLEAN) != 0 and
            c.janet_unwrap_boolean(repeat_val) != 0;

        const timer_id = janetGet(val, kw("id"));

        // If this timer has an id, cancel any existing timer with the same id
        if (c.janet_checktype(timer_id, c.JANET_NIL) == 0) {
            self.cancelTimer(timer_id);
        }

        // Find a free slot
        for (&self.timers) |*timer| {
            if (!timer.active) {
                timer.active = true;
                timer.fire_time = monotonicNow() + delay;
                timer.event = event_val;
                timer.repeat = repeat;
                timer.interval = delay;
                timer.id = timer_id;
                c.janet_gcroot(event_val);
                if (c.janet_checktype(timer_id, c.JANET_NIL) == 0) {
                    c.janet_gcroot(timer_id);
                }
                log.debug("timer created: delay={d:.2}s repeat={}", .{ delay, repeat });
                return;
            }
        }
        log.warn("timer fx: no free timer slots", .{});
    }

    /// Cancel all timers matching the given id.
    fn cancelTimer(self: *Dispatch, timer_id: Janet) void {
        for (&self.timers) |*timer| {
            if (timer.active and c.janet_checktype(timer.id, c.JANET_NIL) == 0 and
                c.janet_equals(timer.id, timer_id) != 0)
            {
                self.freeTimer(timer);
            }
        }
    }

    fn freeTimer(_: *Dispatch, timer: *Timer) void {
        _ = c.janet_gcunroot(timer.event);
        if (c.janet_checktype(timer.id, c.JANET_NIL) == 0) {
            _ = c.janet_gcunroot(timer.id);
        }
        timer.active = false;
    }

    /// Check timers against current time, enqueue events for any that have fired.
    pub fn checkTimers(self: *Dispatch) void {
        const now = monotonicNow();
        for (&self.timers) |*timer| {
            if (!timer.active) continue;
            if (now >= timer.fire_time) {
                self.enqueue(timer.event);
                if (timer.repeat) {
                    timer.fire_time += timer.interval;
                    // If fallen far behind (e.g. system suspend), reset to avoid burst
                    if (timer.fire_time < now) timer.fire_time = now + timer.interval;
                } else {
                    self.freeTimer(timer);
                }
            }
        }
    }

    /// Return milliseconds until the next timer fires, or null if no active timers.
    /// Used to set the poll timeout in the main loop.
    pub fn nextTimerTimeoutMs(self: *Dispatch) ?i32 {
        const now = monotonicNow();
        var min_delay: ?f64 = null;
        for (self.timers) |timer| {
            if (!timer.active) continue;
            const remaining = timer.fire_time - now;
            const clamped = if (remaining < 0) 0 else remaining;
            if (min_delay == null or clamped < min_delay.?) {
                min_delay = clamped;
            }
        }
        if (min_delay) |d| {
            const ms_f = @ceil(d * 1000.0);
            const clamped = @min(ms_f, @as(f64, std.math.maxInt(i32)));
            const ms = @as(i32, @intFromFloat(clamped));
            return @max(ms, 0);
        }
        return null;
    }

    pub fn hasActiveAnims(self: *const Dispatch) bool {
        for (self.anims) |slot| {
            if (slot.active) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------
    // Animation pool
    // -------------------------------------------------------------------

    /// Tick all active animations by dt seconds. Returns true if any are active
    /// (caller should keep rendering). Enqueues on-complete events for finished
    /// animations.
    pub fn tickAnimations(self: *Dispatch, dt: f32) bool {
        var any_active = false;
        for (&self.anims) |*slot| {
            if (!slot.active) continue;

            if (slot.duration <= 0) {
                // Immediate set (duration 0 or omitted)
                slot.current = slot.target;
                slot.progress = 1.0;
                self.finishAnim(slot);
                continue;
            }

            slot.progress += dt / slot.duration;
            if (slot.progress >= 1.0) {
                slot.progress = 1.0;
                slot.current = slot.target;
                self.finishAnim(slot);
                any_active = true; // need one more render for the final value
            } else {
                const eased = slot.easing.apply(slot.progress);
                const t: f64 = @floatCast(eased);
                slot.current = slot.start + (slot.target - slot.start) * t;
                any_active = true;
            }
        }
        return any_active;
    }

    fn finishAnim(self: *Dispatch, slot: *AnimSlot) void {
        slot.active = false;
        // Enqueue on-complete event if present
        if (c.janet_checktype(slot.on_complete, c.JANET_TUPLE) != 0) {
            if (self.queue_count < MAX_QUEUED_EVENTS) {
                self.enqueue(slot.on_complete);
            } else {
                log.warn("anim on_complete dropped: event queue full", .{});
            }
            _ = c.janet_gcunroot(slot.on_complete);
            slot.on_complete = c.janet_wrap_nil();
        }
        // Keep id and current value alive — (anim :id) can still read the
        // resting value. The GC root on id remains until the slot is reused.
    }

    /// Get the current value of a named animation by keyword. Returns 0 if not found.
    pub fn getAnimValue(self: *Dispatch, id: Janet) f64 {
        for (self.anims) |slot| {
            if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0 and
                c.janet_equals(slot.id, id) != 0)
            {
                return slot.current;
            }
        }
        return 0.0;
    }

    /// Handle the :anim fx value. Accepts a single spec table or an array of specs.
    pub fn handleAnimFx(self: *Dispatch, val: Janet) void {
        // Array of specs
        if (c.janet_checktype(val, c.JANET_TUPLE) != 0 or
            c.janet_checktype(val, c.JANET_ARRAY) != 0)
        {
            // Check if it looks like an array of specs (first element is a table)
            // vs a single tuple value. Specs are tables/structs, not tuples.
            const view = janetIndexedView(val);
            if (view.items) |items| {
                if (view.len > 0) {
                    const first = items[0];
                    if (c.janet_checktype(first, c.JANET_TABLE) != 0 or
                        c.janet_checktype(first, c.JANET_STRUCT) != 0)
                    {
                        // Array of specs
                        for (0..@intCast(view.len)) |i| {
                            self.handleAnimSpec(items[i]);
                        }
                        return;
                    }
                }
            }
        }

        // Single spec (table or struct)
        self.handleAnimSpec(val);
    }

    fn handleAnimSpec(self: *Dispatch, spec: Janet) void {
        if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
            c.janet_checktype(spec, c.JANET_STRUCT) == 0)
        {
            log.warn("anim fx: spec is not a table", .{});
            return;
        }

        const id = janetGet(spec, kw("id"));
        if (c.janet_checktype(id, c.JANET_KEYWORD) == 0) {
            log.warn("anim fx: spec missing :id keyword", .{});
            return;
        }

        // Cancel?
        const cancel_val = janetGet(spec, kw("cancel"));
        if (c.janet_checktype(cancel_val, c.JANET_NIL) == 0) {
            self.cancelAnim(id);
            return;
        }

        // Must have :to
        const to_val = janetGet(spec, kw("to"));
        if (c.janet_checktype(to_val, c.JANET_NUMBER) == 0) {
            log.warn("anim fx: spec missing :to number", .{});
            return;
        }
        const target = c.janet_unwrap_number(to_val);

        // Duration (default 0 = immediate)
        const dur_val = janetGet(spec, kw("duration"));
        const duration: f32 = if (c.janet_checktype(dur_val, c.JANET_NUMBER) != 0)
            @floatCast(c.janet_unwrap_number(dur_val))
        else
            0;

        // Easing (default linear)
        const ease_val = janetGet(spec, kw("easing"));
        const easing = if (c.janet_checktype(ease_val, c.JANET_KEYWORD) != 0)
            parseEasing(ease_val)
        else
            .linear;

        // Explicit :from
        const from_val = janetGet(spec, kw("from"));
        const has_explicit_from = c.janet_checktype(from_val, c.JANET_NUMBER) != 0;

        // On-complete event
        const on_complete = janetGet(spec, kw("on-complete"));

        // Find existing slot with this id (retarget)
        for (&self.anims) |*slot| {
            if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0 and
                c.janet_equals(slot.id, id) != 0)
            {
                // Retarget: start from current value (or explicit :from)
                slot.start = if (has_explicit_from) c.janet_unwrap_number(from_val) else slot.current;
                slot.target = target;
                slot.progress = 0;
                slot.duration = duration;
                slot.easing = easing;
                slot.active = duration > 0;
                if (!slot.active) {
                    slot.current = target;
                    slot.progress = 1.0;
                }
                // Replace on-complete
                if (c.janet_checktype(slot.on_complete, c.JANET_TUPLE) != 0) {
                    _ = c.janet_gcunroot(slot.on_complete);
                }
                if (c.janet_checktype(on_complete, c.JANET_TUPLE) != 0) {
                    if (slot.active) {
                        c.janet_gcroot(on_complete);
                        slot.on_complete = on_complete;
                    } else {
                        // Immediate completion — enqueue directly
                        slot.on_complete = c.janet_wrap_nil();
                        self.enqueue(on_complete);
                    }
                } else {
                    slot.on_complete = c.janet_wrap_nil();
                }
                return;
            }
        }

        // Find a free slot (inactive and no resting value, or first inactive)
        for (&self.anims) |*slot| {
            if (!slot.active and c.janet_checktype(slot.id, c.JANET_NIL) != 0) {
                self.initAnimSlot(slot, id, target, duration, easing, has_explicit_from, from_val, on_complete);
                return;
            }
        }
        // Fall back: reuse any inactive slot
        for (&self.anims) |*slot| {
            if (!slot.active) {
                // Free the old id's GC root
                if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0) {
                    _ = c.janet_gcunroot(slot.id);
                }
                self.initAnimSlot(slot, id, target, duration, easing, has_explicit_from, from_val, on_complete);
                return;
            }
        }

        log.warn("anim fx: no free animation slots", .{});
    }

    fn initAnimSlot(
        self: *Dispatch,
        slot: *AnimSlot,
        id: Janet,
        target: f64,
        duration: f32,
        easing: animation.Easing,
        has_explicit_from: bool,
        from_val: Janet,
        on_complete: Janet,
    ) void {
        const start_val: f64 = if (has_explicit_from) c.janet_unwrap_number(from_val) else target;
        c.janet_gcroot(id);
        slot.* = .{
            .active = duration > 0,
            .id = id,
            .current = if (duration > 0) start_val else target,
            .target = target,
            .start = start_val,
            .progress = if (duration > 0) 0 else 1.0,
            .duration = duration,
            .easing = easing,
            .on_complete = c.janet_wrap_nil(),
        };
        if (c.janet_checktype(on_complete, c.JANET_TUPLE) != 0) {
            if (duration > 0) {
                c.janet_gcroot(on_complete);
                slot.on_complete = on_complete;
            } else {
                // Immediate completion — enqueue on_complete directly
                self.enqueue(on_complete);
            }
        }
    }

    fn cancelAnim(self: *Dispatch, id: Janet) void {
        for (&self.anims) |*slot| {
            if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0 and
                c.janet_equals(slot.id, id) != 0)
            {
                slot.active = false;
                // Discard on-complete
                if (c.janet_checktype(slot.on_complete, c.JANET_TUPLE) != 0) {
                    _ = c.janet_gcunroot(slot.on_complete);
                    slot.on_complete = c.janet_wrap_nil();
                }
                return;
            }
        }
    }

    fn freeAnimSlot(_: *Dispatch, slot: *AnimSlot) void {
        if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.id);
        }
        if (c.janet_checktype(slot.on_complete, c.JANET_TUPLE) != 0) {
            _ = c.janet_gcunroot(slot.on_complete);
        }
        slot.* = .{};
    }

    // -------------------------------------------------------------------
    // Spawn / IPC delegation (pools in spawn.zig / ipc.zig)
    // -------------------------------------------------------------------

    pub fn onSpawnReadable(self: *Dispatch, fd: std.posix.fd_t) void {
        self.spawns.onReadable(fd, self.eventSink());
    }

    pub fn fillSpawnPollFds(self: *Dispatch, buf: []std.posix.pollfd) usize {
        return self.spawns.fillPollFds(buf);
    }

    // -------------------------------------------------------------------
    // Surface lifecycle requests
    // -------------------------------------------------------------------

    fn enqueueSurfaceRequest(self: *Dispatch, val: Janet) void {
        if (self.surface_request_count >= MAX_SURFACE_REQUESTS) {
            log.warn("surface request queue full", .{});
            return;
        }
        c.janet_gcroot(val);
        self.surface_requests[self.surface_request_count] = val;
        self.surface_request_count += 1;
    }

    /// Drain surface requests. Returns a slice of GC-rooted Janet values.
    /// Caller must call janet_gcunroot on each after processing.
    pub fn drainSurfaceRequests(self: *Dispatch) []const Janet {
        const count = self.surface_request_count;
        if (count == 0) return &.{};
        self.surface_request_count = 0;
        return self.surface_requests[0..count];
    }

    pub fn onIpcReadable(self: *Dispatch, fd: std.posix.fd_t) void {
        self.ipcs.onReadable(fd, self.eventSink());
    }

    pub fn fillIpcPollFds(self: *Dispatch, buf: []std.posix.pollfd) usize {
        return self.ipcs.fillPollFds(buf);
    }

    /// Build an EventSink that routes enqueue/timer calls back to this Dispatch.
    fn eventSink(self: *Dispatch) jutil.EventSink {
        return .{
            .ctx = @ptrCast(self),
            .enqueue = enqueueAdapter,
            .timer = timerAdapter,
        };
    }

    fn enqueueAdapter(ctx: *anyopaque, event: Janet) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.enqueue(event);
    }

    fn timerAdapter(ctx: *anyopaque, val: Janet) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.handleTimerFx(val);
    }

    /// Update the db, managing GC roots.
    fn setDb(self: *Dispatch, new_db: Janet) void {
        _ = c.janet_gcunroot(self.db);
        self.db = new_db;
        c.janet_gcroot(new_db);
    }

    /// Set the current db for subscription evaluation. Call before view fn.
    pub fn prepareRender(self: *Dispatch) void {
        _ = self.pcall(self.fn_set_current_db, &.{self.db});
    }

    /// Call the registered view function and walk the resulting hiccup tree.
    /// Call prepareRender() first to set up the db for subscriptions.
    /// Pass a keyword Janet value to render a named view, or nil for the default.
    /// Returns true if a view was rendered, false if no view fn registered.
    pub fn renderView(self: *Dispatch, view_name: Janet) bool {
        // Get the view function (named or default)
        const view_fn_val = if (c.janet_checktype(view_name, c.JANET_NIL) != 0)
            self.pcall(self.fn_get_view_fn, &.{}) orelse return false
        else
            self.pcall(self.fn_get_view_fn, &.{view_name}) orelse return false;
        if (c.janet_checktype(view_fn_val, c.JANET_NIL) != 0) return false;

        // Call the view function (no args) → hiccup tree
        const hiccup_tree = self.pcall(view_fn_val, &.{}) orelse return false;
        c.janet_gcroot(hiccup_tree);
        defer _ = c.janet_gcunroot(hiccup_tree);

        // Walk the hiccup tree, emitting Clay calls
        hiccup.walkHiccup(hiccup_tree);
        return true;
    }

    /// Protected call with 0 arguments. Returns result or null on error.
    fn pcall(self: *Dispatch, func: Janet, args: []const Janet) ?Janet {
        _ = self;
        if (c.janet_checktype(func, c.JANET_FUNCTION) == 0) {
            log.warn("pcall: not a function", .{});
            return null;
        }
        var out: Janet = undefined;
        const argv: [*c]const Janet = if (args.len > 0) args.ptr else null;
        const fiber = c.janet_fiber(
            c.janet_unwrap_function(func),
            64,
            @intCast(args.len),
            argv,
        );
        if (fiber == null) {
            log.warn("pcall: could not create fiber", .{});
            return null;
        }
        const signal = c.janet_continue(fiber, c.janet_wrap_nil(), &out);
        if (signal != c.JANET_SIGNAL_OK) {
            log.warn("pcall: Janet error: {s}", .{jutil.janetToStr(out)});
            return null;
        }
        return out;
    }

    /// Evaluate Janet source in the dispatch environment.
    pub fn eval(self: *Dispatch, source: [:0]const u8, source_path: [:0]const u8) !Janet {
        return doString(self.env, source, source_path);
    }

    /// Inject theme colors as a `theme` def in the Janet environment.
    /// Creates a table with semantic color names and the full Base16 palette,
    /// each as a 4-element RGBA tuple (0-255 range).
    fn injectTheme(self: *Dispatch, theme: theme_mod.Theme) void {
        const t = c.janet_table(24);
        const t_val = c.janet_wrap_table(t);
        c.janet_gcroot(t_val);
        defer _ = c.janet_gcunroot(t_val);

        // Semantic color names
        c.janet_table_put(t, kw("bg"), colorToJanet(theme.background()));
        c.janet_table_put(t, kw("surface"), colorToJanet(theme.surface()));
        c.janet_table_put(t, kw("overlay"), colorToJanet(theme.overlay()));
        c.janet_table_put(t, kw("muted"), colorToJanet(theme.muted()));
        c.janet_table_put(t, kw("subtle"), colorToJanet(theme.subtle()));
        c.janet_table_put(t, kw("text"), colorToJanet(theme.text()));
        c.janet_table_put(t, kw("bright"), colorToJanet(theme.bright_text()));
        c.janet_table_put(t, kw("accent"), colorToJanet(theme.accent()));

        // Full Base16 palette
        c.janet_table_put(t, kw("base00"), colorToJanet(theme.base00));
        c.janet_table_put(t, kw("base01"), colorToJanet(theme.base01));
        c.janet_table_put(t, kw("base02"), colorToJanet(theme.base02));
        c.janet_table_put(t, kw("base03"), colorToJanet(theme.base03));
        c.janet_table_put(t, kw("base04"), colorToJanet(theme.base04));
        c.janet_table_put(t, kw("base05"), colorToJanet(theme.base05));
        c.janet_table_put(t, kw("base06"), colorToJanet(theme.base06));
        c.janet_table_put(t, kw("base07"), colorToJanet(theme.base07));
        c.janet_table_put(t, kw("base08"), colorToJanet(theme.base08));
        c.janet_table_put(t, kw("base09"), colorToJanet(theme.base09));
        c.janet_table_put(t, kw("base0A"), colorToJanet(theme.base0A));
        c.janet_table_put(t, kw("base0B"), colorToJanet(theme.base0B));
        c.janet_table_put(t, kw("base0C"), colorToJanet(theme.base0C));
        c.janet_table_put(t, kw("base0D"), colorToJanet(theme.base0D));
        c.janet_table_put(t, kw("base0E"), colorToJanet(theme.base0E));
        c.janet_table_put(t, kw("base0F"), colorToJanet(theme.base0F));

        c.janet_def(self.env, "theme", c.janet_wrap_table(t), "Base16 theme colors from config");
    }

    /// Try to load a Janet source string. Returns true on success.
    fn loadSource(self: *Dispatch, source: [*:0]const u8, name: [*:0]const u8) bool {
        var out: Janet = undefined;
        const status = c.janet_dostring(self.env, source, name, &out);
        if (status != 0) {
            log.warn("failed to evaluate {s}", .{name});
            return false;
        }
        return true;
    }

    /// Try to load a Janet file from disk. Returns true if loaded successfully.
    fn loadFileFromDisk(self: *Dispatch, path: []const u8) bool {
        if (path.len == 0 or path.len >= 4095) return false;

        var path_z: [4096]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const file = std.fs.openFileAbsolute(path_z[0..path.len :0], .{}) catch return false;
        defer file.close();

        // Read up to 1MB
        var content_buf: [1 << 20]u8 = undefined;
        const n = file.readAll(&content_buf) catch return false;
        if (n == 0 or n >= content_buf.len) return false;
        content_buf[n] = 0;

        var out: Janet = undefined;
        const status = c.janet_dostring(self.env, @ptrCast(content_buf[0..n :0]), @ptrCast(path_z[0..path.len :0]), &out);
        if (status != 0) {
            log.warn("failed to evaluate {s}", .{path_z[0..path.len :0]});
            return false;
        }
        log.info("loaded {s}", .{path_z[0..path.len :0]});
        return true;
    }

    /// Load modules: user config dir overrides embedded defaults.
    ///
    /// If ~/.config/shoal/ contains .janet files, those are loaded alphabetically
    /// and no embedded modules load. This gives the user full control.
    ///
    /// If the config dir is empty or absent, embedded defaults load:
    /// tidepool.janet, clock.janet, sysinfo.janet, bar.janet.
    fn loadModules(self: *Dispatch) void {
        // Try to find and load user modules
        const config_dir = self.resolveAndLoadUserModules();
        if (config_dir) return;

        // No user modules — load embedded defaults
        log.info("no user modules found, loading embedded defaults", .{});
        _ = self.loadSource(tidepool_source.ptr, "tidepool.janet");
        _ = self.loadSource(clock_source.ptr, "clock.janet");
        _ = self.loadSource(sysinfo_source.ptr, "sysinfo.janet");
        _ = self.loadSource(bar_source.ptr, "bar.janet");
        _ = self.loadSource(launcher_source.ptr, "launcher.janet");
        _ = self.loadSource(osd_source.ptr, "osd.janet");
    }

    /// Load only the dmenu module (skips all other modules).
    pub fn loadDmenuModule(self: *Dispatch) void {
        _ = self.loadSource(dmenu_source.ptr, "dmenu.janet");
    }

    /// Inject items into the Janet db for dmenu mode.
    pub fn injectDmenuItems(self: *Dispatch, items: []const []const u8, prompt: []const u8) void {
        const arr = c.janet_array(@intCast(items.len));
        for (items) |item| {
            const s = c.janet_string(@ptrCast(item.ptr), @as(i32, @intCast(item.len)));
            c.janet_array_push(arr, c.janet_wrap_string(s));
        }

        // Set :dmenu/items and :dmenu/prompt in the db table
        if (c.janet_checktype(self.db, c.JANET_TABLE) != 0) {
            const t = c.janet_unwrap_table(self.db);
            c.janet_table_put(t, kw("dmenu/items"), c.janet_wrap_array(arr));
            const ps = c.janet_string(@ptrCast(prompt.ptr), @as(i32, @intCast(prompt.len)));
            c.janet_table_put(t, kw("dmenu/prompt"), c.janet_wrap_string(ps));
        }
    }

    /// Try to open the user config dir and load all .janet files.
    /// Returns true if any user modules were loaded.
    fn resolveAndLoadUserModules(self: *Dispatch) bool {
        // Resolve config dir path
        var dir_path_buf: [4096]u8 = undefined;
        const dir_path = blk: {
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
                break :blk std.fmt.bufPrint(&dir_path_buf, "{s}/shoal", .{xdg}) catch return false;
            }
            if (std.posix.getenv("HOME")) |home| {
                break :blk std.fmt.bufPrint(&dir_path_buf, "{s}/.config/shoal", .{home}) catch return false;
            }
            return false;
        };

        // Open the directory
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return false;
        defer dir.close();

        // Collect .janet filenames, sort alphabetically
        var names: [64][]const u8 = undefined;
        var name_storage: [64][256]u8 = undefined;
        var count: usize = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".janet")) continue;
            if (count >= 64) break;
            const len = @min(entry.name.len, 255);
            @memcpy(name_storage[count][0..len], entry.name[0..len]);
            names[count] = name_storage[count][0..len];
            count += 1;
        }

        if (count == 0) return false;

        // Sort alphabetically
        std.mem.sortUnstable([]const u8, names[0..count], {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Load each file
        var path_buf: [4096]u8 = undefined;
        for (names[0..count]) |name| {
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            _ = self.loadFileFromDisk(full_path);
        }

        log.info("loaded {d} user module(s) from {s}", .{ count, dir_path });
        return true;
    }

    pub fn deinitDispatch(self: *Dispatch) void {
        // Free queued events
        while (self.queue_count > 0) {
            _ = c.janet_gcunroot(self.event_queue[self.queue_head]);
            self.queue_head = (self.queue_head + 1) % MAX_QUEUED_EVENTS;
            self.queue_count -= 1;
        }
        // Free active timers
        for (&self.timers) |*timer| {
            if (timer.active) self.freeTimer(timer);
        }
        // Free animation slots
        for (&self.anims) |*slot| {
            if (c.janet_checktype(slot.id, c.JANET_KEYWORD) != 0) {
                self.freeAnimSlot(slot);
            }
        }
        // Kill active spawns
        for (&self.spawns.slots) |*slot| {
            if (slot.active) self.spawns.kill(slot);
        }
        // Close IPC connections
        self.ipcs.deinit();
        _ = c.janet_gcunroot(self.db);
    }
};

/// Global dispatch pointer for Janet C functions (which have no userdata).
var global_dispatch: ?*Dispatch = null;

/// Janet C function: (anim :id) → number
fn janetAnimFn(argc: i32, argv: [*c]Janet) callconv(.c) Janet {
    if (argc != 1) return c.janet_wrap_number(0);
    const id = argv[0];
    if (c.janet_checktype(id, c.JANET_KEYWORD) == 0) {
        log.warn("(anim): expected keyword argument", .{});
        return c.janet_wrap_number(0);
    }
    const d = global_dispatch orelse return c.janet_wrap_number(0);
    return c.janet_wrap_number(d.getAnimValue(id));
}

/// Janet C function: (disk-usage "/") → {:total N :used N :available N :percent N}
fn janetDiskUsageFn(argc: i32, argv: [*c]Janet) callconv(.c) Janet {
    if (argc != 1) return c.janet_wrap_nil();
    if (c.janet_checktype(argv[0], c.JANET_STRING) == 0) return c.janet_wrap_nil();

    const str = c.janet_unwrap_string(argv[0]);
    const len: usize = @intCast(c.janet_string_length(str));

    var path_buf: [4096]u8 = undefined;
    if (len >= path_buf.len) return c.janet_wrap_nil();
    @memcpy(path_buf[0..len], str[0..len]);
    path_buf[len] = 0;

    const posix_c = @cImport(@cInclude("sys/vfs.h"));
    var stat: posix_c.struct_statfs = undefined;
    const rc = posix_c.statfs(@ptrCast(path_buf[0..len :0]), &stat);
    if (rc != 0) return c.janet_wrap_nil();

    const bsize: f64 = @floatFromInt(stat.f_bsize);
    const total = @as(f64, @floatFromInt(stat.f_blocks)) * bsize;
    const free_bytes = @as(f64, @floatFromInt(stat.f_bfree)) * bsize;
    const avail = @as(f64, @floatFromInt(stat.f_bavail)) * bsize;
    const used = total - free_bytes;

    const t = c.janet_table(4);
    c.janet_table_put(t, kw("total"), c.janet_wrap_number(total));
    c.janet_table_put(t, kw("used"), c.janet_wrap_number(used));
    c.janet_table_put(t, kw("available"), c.janet_wrap_number(avail));
    c.janet_table_put(t, kw("percent"), c.janet_wrap_number(if (total > 0) used / total * 100.0 else 0));
    return c.janet_wrap_table(t);
}

/// Janet C function: (desktop-apps) → array of {:name "..." :exec "..." :icon "..."}
/// Scans XDG_DATA_DIRS and XDG_DATA_HOME for .desktop files.
fn janetDesktopAppsFn(argc: i32, _: [*c]Janet) callconv(.c) Janet {
    _ = argc;
    const posix_c = @cImport(@cInclude("dirent.h"));

    const results = c.janet_array(64);

    // Build list of data dirs to scan
    var dirs_buf: [8][]const u8 = undefined;
    var dir_count: usize = 0;

    // XDG_DATA_HOME (default ~/.local/share)
    if (std.posix.getenv("XDG_DATA_HOME")) |home| {
        dirs_buf[dir_count] = home;
        dir_count += 1;
    } else if (std.posix.getenv("HOME")) |home| {
        // Will construct path manually below
        dirs_buf[dir_count] = home;
        dir_count += 1;
    }

    // XDG_DATA_DIRS (default /usr/local/share:/usr/share)
    const xdg_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, xdg_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len > 0 and dir_count < dirs_buf.len) {
            dirs_buf[dir_count] = dir;
            dir_count += 1;
        }
    }

    var path_buf: [4096]u8 = undefined;

    for (dirs_buf[0..dir_count], 0..) |base_dir, di| {
        // Build "base_dir/applications" or "base_dir/.local/share/applications"
        const app_path = blk: {
            if (di == 0 and std.posix.getenv("XDG_DATA_HOME") == null) {
                // HOME fallback: construct ~/.local/share/applications
                break :blk std.fmt.bufPrint(&path_buf, "{s}/.local/share/applications", .{base_dir}) catch continue;
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "{s}/applications", .{base_dir}) catch continue;
            }
        };

        if (app_path.len >= path_buf.len - 1) continue;
        path_buf[app_path.len] = 0;

        const dir = posix_c.opendir(@ptrCast(path_buf[0..app_path.len :0]));
        if (dir == null) continue;
        defer _ = posix_c.closedir(dir);

        while (posix_c.readdir(dir)) |entry| {
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            const name = std.mem.span(name_ptr);
            if (!std.mem.endsWith(u8, name, ".desktop")) continue;

            // Build full path
            var file_path_buf: [4096]u8 = undefined;
            const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ app_path, name }) catch continue;
            if (file_path.len >= file_path_buf.len - 1) continue;
            file_path_buf[file_path.len] = 0;

            // Read and parse .desktop file
            const file = std.fs.openFileAbsolute(file_path_buf[0..file_path.len :0], .{}) catch continue;
            defer file.close();

            var read_buf: [8192]u8 = undefined;
            const bytes_read = file.readAll(&read_buf) catch continue;
            const content = read_buf[0..bytes_read];

            var app_name: ?[]const u8 = null;
            var app_exec: ?[]const u8 = null;
            var app_icon: ?[]const u8 = null;
            var no_display = false;
            var hidden = false;

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Name=") and app_name == null) {
                    app_name = line[5..];
                } else if (std.mem.startsWith(u8, line, "Exec=")) {
                    app_exec = line[5..];
                } else if (std.mem.startsWith(u8, line, "Icon=")) {
                    app_icon = line[5..];
                } else if (std.mem.startsWith(u8, line, "NoDisplay=true")) {
                    no_display = true;
                } else if (std.mem.startsWith(u8, line, "Hidden=true")) {
                    hidden = true;
                }
            }

            if (no_display or hidden) continue;
            const display_name = app_name orelse continue;
            const exec_cmd = app_exec orelse continue;

            // Strip field codes (%f, %F, %u, %U, etc.) from exec
            var clean_exec_buf: [2048]u8 = undefined;
            var clean_len: usize = 0;
            var ei: usize = 0;
            while (ei < exec_cmd.len) : (ei += 1) {
                if (exec_cmd[ei] == '%' and ei + 1 < exec_cmd.len) {
                    ei += 1; // skip the field code letter
                    // Also skip leading space before %
                    if (clean_len > 0 and clean_exec_buf[clean_len - 1] == ' ') {
                        clean_len -= 1;
                    }
                } else {
                    if (clean_len < clean_exec_buf.len) {
                        clean_exec_buf[clean_len] = exec_cmd[ei];
                        clean_len += 1;
                    }
                }
            }
            // Trim trailing spaces
            while (clean_len > 0 and clean_exec_buf[clean_len - 1] == ' ') {
                clean_len -= 1;
            }

            const t = c.janet_table(3);
            c.janet_table_put(t, kw("name"), c.janet_wrap_string(
                c.janet_string(@ptrCast(display_name.ptr), @as(i32, @intCast(display_name.len))),
            ));
            c.janet_table_put(t, kw("exec"), c.janet_wrap_string(
                c.janet_string(@ptrCast(clean_exec_buf[0..clean_len].ptr), @as(i32, @intCast(clean_len))),
            ));
            if (app_icon) |icon| {
                c.janet_table_put(t, kw("icon"), c.janet_wrap_string(
                    c.janet_string(@ptrCast(icon.ptr), @as(i32, @intCast(icon.len))),
                ));
            }
            c.janet_array_push(results, c.janet_wrap_table(t));
        }
    }
    return c.janet_wrap_array(results);
}

/// Handle :exec fx — fire-and-forget process launch (for desktop apps).
/// Value: {:cmd "command string"} or {:cmd ["arg0" "arg1" ...]}
fn handleExecFx(val: Janet) void {
    if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
        c.janet_checktype(val, c.JANET_STRUCT) == 0)
    {
        log.warn("exec fx: expected table", .{});
        return;
    }

    const cmd_val = jutil.janetGet(val, kw("cmd"));

    // Support string command (passed to sh -c) or array command
    var use_shell = false;
    var shell_cmd: ?[]const u8 = null;
    var argv: [33]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 33;
    var argc: usize = 0;

    if (c.janet_checktype(cmd_val, c.JANET_STRING) != 0) {
        // String: run via sh -c
        const str = c.janet_unwrap_string(cmd_val);
        const len: usize = @intCast(c.janet_string_length(str));
        shell_cmd = str[0..len];
        use_shell = true;
    } else {
        // Array: direct exec
        const view = jutil.janetIndexedView(cmd_val);
        if (view.items == null or view.len == 0) {
            log.warn("exec fx: empty or missing :cmd", .{});
            return;
        }
        argc = @intCast(view.len);
        if (argc > 32) {
            log.warn("exec fx: too many args (max 32)", .{});
            return;
        }
        for (0..argc) |i| {
            const s = view.items.?[i];
            if (c.janet_checktype(s, c.JANET_STRING) != 0) {
                argv[i] = @ptrCast(c.janet_unwrap_string(s));
            } else if (c.janet_checktype(s, c.JANET_KEYWORD) != 0) {
                argv[i] = @ptrCast(c.janet_unwrap_keyword(s));
            } else {
                log.warn("exec fx: cmd element is not a string/keyword", .{});
                return;
            }
        }
    }

    const posix_c2 = @cImport(@cInclude("unistd.h"));
    const fork_result = std.posix.fork() catch {
        log.warn("exec fx: fork() failed", .{});
        return;
    };

    if (fork_result == 0) {
        // Child: double-fork to fully detach
        const fork2 = std.posix.fork() catch std.process.exit(127);
        if (fork2 != 0) std.process.exit(0); // first child exits immediately

        // Grandchild: new session, redirect stdio to /dev/null
        _ = posix_c2.setsid();
        const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.process.exit(127);
        _ = std.posix.dup2(devnull, 0) catch {};
        _ = std.posix.dup2(devnull, 1) catch {};
        _ = std.posix.dup2(devnull, 2) catch {};
        if (devnull > 2) std.posix.close(devnull);

        if (use_shell) {
            // Copy shell_cmd to a stack buffer (parent memory is shared until exec)
            var cmd_buf: [4096]u8 = undefined;
            const scmd = shell_cmd orelse std.process.exit(127);
            if (scmd.len >= cmd_buf.len) std.process.exit(127);
            @memcpy(cmd_buf[0..scmd.len], scmd);
            cmd_buf[scmd.len] = 0;
            const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..scmd.len :0]);
            const sh_argv = [_]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
            _ = posix_c2.execvp("/bin/sh", @ptrCast(&sh_argv));
        } else {
            _ = posix_c2.execvp(argv[0].?, @ptrCast(&argv));
        }
        std.process.exit(127);
    }

    // Parent: reap first child immediately
    _ = std.posix.waitpid(fork_result, 0);
}

/// Handle :stdout fx — write a string to stdout. Value: "text" or {:text "..." :newline true}
fn handleStdoutFx(val: Janet) void {
    const text = if (c.janet_checktype(val, c.JANET_STRING) != 0) blk: {
        const s = c.janet_unwrap_string(val);
        const len: usize = @intCast(c.janet_string_length(s));
        break :blk s[0..len];
    } else if (c.janet_checktype(val, c.JANET_TABLE) != 0 or c.janet_checktype(val, c.JANET_STRUCT) != 0) blk: {
        const text_val = jutil.janetGet(val, kw("text"));
        if (c.janet_checktype(text_val, c.JANET_STRING) == 0) {
            log.warn("stdout fx: missing :text string", .{});
            return;
        }
        const s = c.janet_unwrap_string(text_val);
        const len: usize = @intCast(c.janet_string_length(s));
        break :blk s[0..len];
    } else {
        log.warn("stdout fx: expected string or table", .{});
        return;
    };

    const stdout = std.fs.File.stdout();
    stdout.writeAll(text) catch {};
    stdout.writeAll("\n") catch {};
}

/// Handle :exit fx — exit the process with a given code. Value: number (exit code)
fn handleExitFx(val: Janet) void {
    const code: u8 = if (c.janet_checktype(val, c.JANET_NUMBER) != 0)
        @intFromFloat(c.janet_unwrap_number(val))
    else
        0;
    std.process.exit(code);
}

const anim_cfun = [_]c.JanetReg{
    .{ .name = "anim", .cfun = janetAnimFn, .documentation = "(anim :id) — get current animated value" },
    .{ .name = "disk-usage", .cfun = janetDiskUsageFn, .documentation = "(disk-usage path) — get filesystem usage for a mount point" },
    .{ .name = "desktop-apps", .cfun = janetDesktopAppsFn, .documentation = "(desktop-apps) — scan XDG dirs for .desktop files" },
    .{ .name = null, .cfun = null, .documentation = null },
};

/// Parse an easing keyword to an Easing enum value.
fn parseEasing(val: Janet) animation.Easing {
    const s = c.janet_unwrap_keyword(val);
    const name = std.mem.span(s);
    if (std.mem.eql(u8, name, "linear")) return .linear;
    if (std.mem.eql(u8, name, "ease-in-quad")) return .ease_in_quad;
    if (std.mem.eql(u8, name, "ease-out-quad")) return .ease_out_quad;
    if (std.mem.eql(u8, name, "ease-in-out-quad")) return .ease_in_out_quad;
    if (std.mem.eql(u8, name, "ease-out-cubic")) return .ease_out_cubic;
    if (std.mem.eql(u8, name, "ease-in-out-cubic")) return .ease_in_out_cubic;
    log.warn("anim: unknown easing '{s}', defaulting to linear", .{name});
    return .linear;
}

/// Create a new Dispatch with an empty db.
pub fn createDispatch() Dispatch {
    const env = coreEnv();
    const empty_db = c.janet_wrap_table(c.janet_table(8));
    return .{
        .env = env,
        .db = empty_db,
    };
}

// ---------------------------------------------------------------------------
// Helpers (janet.zig-local; shared helpers are in jutil.zig)
// ---------------------------------------------------------------------------

/// Get the first element of a Janet tuple.
fn tupleFirst(val: Janet) ?Janet {
    if (c.janet_checktype(val, c.JANET_TUPLE) != 0) {
        const t = c.janet_unwrap_tuple(val);
        const len = c.janet_tuple_length(t);
        if (len > 0) return t[0];
    }
    return null;
}

/// Get a keyword-keyed value from a handler entry (table).
fn tableGet(entry: Janet, key_name: [:0]const u8) ?Janet {
    if (c.janet_checktype(entry, c.JANET_TABLE) == 0 and
        c.janet_checktype(entry, c.JANET_STRUCT) == 0) return null;
    const val = janetGet(entry, kw(key_name));
    if (c.janet_checktype(val, c.JANET_NIL) != 0) return null;
    return val;
}

/// Look up a binding in a Janet environment table by name.
fn envLookup(env: *JanetTable, name: [:0]const u8) ?Janet {
    const sym = c.janet_csymbolv(name.ptr);
    const binding = c.janet_table_get(env, sym);
    if (c.janet_checktype(binding, c.JANET_NIL) != 0) return null;
    if (c.janet_checktype(binding, c.JANET_TABLE) != 0) {
        const val = c.janet_table_get(c.janet_unwrap_table(binding), kw("value"));
        if (c.janet_checktype(val, c.JANET_NIL) != 0) return null;
        return val;
    }
    return null;
}

/// Convert a theme Color (0.0-1.0 f32 RGBA) to a Janet tuple (0-255 integer RGBA).
fn colorToJanet(color: theme_mod.Color) Janet {
    return jutil.makeTuple(&.{
        c.janet_wrap_number(@round(@as(f64, color[0]) * 255.0)),
        c.janet_wrap_number(@round(@as(f64, color[1]) * 255.0)),
        c.janet_wrap_number(@round(@as(f64, color[2]) * 255.0)),
        c.janet_wrap_number(@round(@as(f64, color[3]) * 255.0)),
    });
}

/// Get current monotonic time in seconds.
fn monotonicNow() f64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
}

