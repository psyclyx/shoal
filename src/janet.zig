const std = @import("std");
const hiccup = @import("hiccup.zig");
const animation = @import("animation.zig");
const log = std.log.scoped(.janet);

const posix_c = @cImport({
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

pub const c = @cImport({
    @cInclude("janet.h");
});

pub const Janet = c.Janet;
pub const JanetTable = c.JanetTable;

const boot_source = @embedFile("shoal.janet");
const json_source = @embedFile("json.janet");
const tidepool_source = @embedFile("tidepool.janet");
const clock_source = @embedFile("clock.janet");
const sysinfo_source = @embedFile("sysinfo.janet");

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
    "ipc",
    "surface",
    "render",
};

const MAX_QUEUED_EVENTS = 256;
const MAX_TIMERS = 64;
const MAX_ANIMS = 64;
const MAX_SPAWNS = 16;
const MAX_IPC_CONNS = 8;
const SPAWN_BUF_SIZE = 4096;
const IPC_BUF_SIZE = 8192;

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

const SpawnSlot = struct {
    active: bool = false,
    pid: posix_c.pid_t = 0,
    stdout_fd: std.posix.fd_t = -1,
    event_id: Janet = undefined, // keyword, GC-rooted when active
    done_id: Janet = undefined, // keyword or nil, GC-rooted if keyword
    line_buf: [SPAWN_BUF_SIZE]u8 = undefined,
    line_len: usize = 0,
};

const IpcFraming = enum { line, netrepl };

const IpcSlot = struct {
    active: bool = false,
    fd: std.posix.fd_t = -1,
    name: Janet = undefined, // keyword, GC-rooted when active
    event_id: Janet = undefined, // keyword for recv events, GC-rooted
    connected_id: Janet = undefined, // keyword or nil
    disconnected_id: Janet = undefined, // keyword or nil
    framing: IpcFraming = .line,
    reconnect_delay: f64 = 0, // seconds, 0 = no reconnect
    path: [256]u8 = undefined, // socket path (copied)
    path_len: usize = 0,
    handshake: ?[]const u8 = null, // netrepl handshake payload (GC-rooted string)
    handshake_janet: Janet = undefined, // the Janet string value (for GC root)

    // Recv buffer
    recv_buf: [IPC_BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,

    // Netrepl framing state
    netrepl_msg_len: ?u32 = null, // expected message length (null = reading header)
    netrepl_hdr_buf: [4]u8 = undefined, // partial header bytes
    netrepl_hdr_len: usize = 0,
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
    spawns: [MAX_SPAWNS]SpawnSlot = [_]SpawnSlot{.{}} ** MAX_SPAWNS,

    // IPC connection pool (Unix sockets)
    ipcs: [MAX_IPC_CONNS]IpcSlot = [_]IpcSlot{.{}} ** MAX_IPC_CONNS,

    // Cached function references (set by initBoot)
    fn_get_handler: Janet = undefined,
    fn_get_cofx_injector: Janet = undefined,
    fn_get_fx_executor: Janet = undefined,
    fn_bump_generation: Janet = undefined,
    fn_set_current_db: Janet = undefined,
    fn_get_view_fn: Janet = undefined,

    /// Load the shoal boot file into a fresh environment. Sets up registries.
    pub fn initBoot(self: *Dispatch) !void {
        // Set global dispatch pointer for Janet C functions
        global_dispatch = self;

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

        // Load tidepool module (registers handlers + subs for compositor IPC)
        var tp_out: Janet = undefined;
        const tp_status = c.janet_dostring(
            self.env,
            tidepool_source.ptr,
            "tidepool.janet",
            &tp_out,
        );
        if (tp_status != 0) return error.TidepoolBootFailed;

        // Load clock module (registers handlers + subs for time data)
        var clock_out: Janet = undefined;
        const clock_status = c.janet_dostring(
            self.env,
            clock_source.ptr,
            "clock.janet",
            &clock_out,
        );
        if (clock_status != 0) return error.ClockBootFailed;

        // Load sysinfo module (registers handlers + subs for cpu/mem/battery)
        var sysinfo_out: Janet = undefined;
        const sysinfo_status = c.janet_dostring(
            self.env,
            sysinfo_source.ptr,
            "sysinfo.janet",
            &sysinfo_out,
        );
        if (sysinfo_status != 0) return error.SysinfoBootFailed;

        // Cache lookup functions from the environment
        self.fn_get_handler = envLookup(self.env, "get-handler") orelse return error.BootMissingGetHandler;
        self.fn_get_cofx_injector = envLookup(self.env, "get-cofx-injector") orelse return error.BootMissingGetCofxInjector;
        self.fn_get_fx_executor = envLookup(self.env, "get-fx-executor") orelse return error.BootMissingGetFxExecutor;
        self.fn_bump_generation = envLookup(self.env, "bump-generation") orelse return error.BootMissingBumpGeneration;
        self.fn_set_current_db = envLookup(self.env, "set-current-db") orelse return error.BootMissingSetCurrentDb;
        self.fn_get_view_fn = envLookup(self.env, "get-view-fn") orelse return error.BootMissingGetViewFn;

        // GC root the db so it survives between event cycles
        c.janet_gcroot(self.db);

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
        const handler_entry = self.pcall1(self.fn_get_handler, event_id) orelse return;
        if (c.janet_checktype(handler_entry, c.JANET_NIL) != 0) {
            log.debug("dispatch: no handler for event", .{});
            return;
        }

        // handler_entry is {:fn handler-fn :cofx [...]}
        const handler_fn = tableGet(handler_entry, "fn") orelse {
            log.warn("dispatch: handler entry missing :fn", .{});
            return;
        };
        const cofx_keys = tableGet(handler_entry, "cofx") orelse c.janet_wrap_nil();

        // Build cofx table
        const cofx = self.buildCofx(event, cofx_keys);

        // Call handler: (handler-fn cofx event) → fx-map
        const fx_map = self.pcall2(handler_fn, cofx, event) orelse return;

        // Execute effects
        self.executeFx(fx_map);
    }

    /// Build the cofx table with built-in values, then inject declared cofx.
    fn buildCofx(self: *Dispatch, event: Janet, cofx_keys: Janet) Janet {
        const cofx_table = c.janet_table(4);

        // Built-in cofx: :db, :event, :now
        c.janet_table_put(cofx_table, kw("db"), self.db);
        c.janet_table_put(cofx_table, kw("event"), event);
        c.janet_table_put(cofx_table, kw("now"), c.janet_wrap_number(monotonicNow()));

        const cofx_val = c.janet_wrap_table(cofx_table);

        // Inject declared cofx
        if (c.janet_checktype(cofx_keys, c.JANET_TUPLE) != 0 or
            c.janet_checktype(cofx_keys, c.JANET_ARRAY) != 0)
        {
            const view = janetIndexedView(cofx_keys);
            if (view.items) |items| {
                for (0..@intCast(view.len)) |i| {
                    const cofx_id = items[i];
                    const injector = self.pcall1(self.fn_get_cofx_injector, cofx_id) orelse continue;
                    if (c.janet_checktype(injector, c.JANET_NIL) != 0) {
                        log.warn("dispatch: unknown cofx injector requested", .{});
                        continue;
                    }
                    // Call injector: (injector cofx-table) → updated cofx-table
                    _ = self.pcall1(injector, cofx_val) orelse continue;
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
                _ = self.pcall0(self.fn_bump_generation);
            } else if (std.mem.eql(u8, fx_name, "anim")) {
                self.handleAnimFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "render")) {
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "dispatch")) {
                self.enqueue(fx_val);
            } else if (std.mem.eql(u8, fx_name, "dispatch-n")) {
                self.enqueueMultiple(fx_val);
            } else if (std.mem.eql(u8, fx_name, "timer")) {
                self.handleTimerFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "spawn")) {
                self.handleSpawnFx(fx_val);
            } else if (std.mem.eql(u8, fx_name, "ipc")) {
                self.handleIpcFx(fx_val);
            } else {
                // Look up registered fx executor
                const executor = self.pcall1(self.fn_get_fx_executor, fx_key) orelse continue;
                if (c.janet_checktype(executor, c.JANET_NIL) != 0) {
                    log.warn("dispatch: unknown fx", .{});
                    continue;
                }
                _ = self.pcall1(executor, fx_val) orelse continue;
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
        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("timer fx: expected table", .{});
            return;
        }

        // Check for cancel
        const cancel_val = janetGet(val, kw("cancel"));
        if (c.janet_checktype(cancel_val, c.JANET_NIL) == 0) {
            const timer_id = janetGet(val, kw("id"));
            if (c.janet_checktype(timer_id, c.JANET_NIL) != 0) {
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
                    timer.fire_time = now + timer.interval;
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
            const ms = @as(i32, @intFromFloat(@ceil(d * 1000.0)));
            return @max(ms, 0);
        }
        return null;
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
            self.enqueue(slot.on_complete);
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
                    c.janet_gcroot(on_complete);
                    slot.on_complete = on_complete;
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
        _: *Dispatch,
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
            c.janet_gcroot(on_complete);
            slot.on_complete = on_complete;
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
    // Spawn pool (child processes)
    // -------------------------------------------------------------------

    /// Handle :spawn fx value. Spec: {:cmd ["cmd" "arg1"] :event :event-id :done :done-id}
    fn handleSpawnFx(self: *Dispatch, val: Janet) void {
        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("spawn fx: expected table", .{});
            return;
        }

        const cmd_val = janetGet(val, kw("cmd"));
        const event_val = janetGet(val, kw("event"));
        const done_val = janetGet(val, kw("done"));

        const cmd_view = janetIndexedView(cmd_val);
        if (cmd_view.items == null or cmd_view.len == 0) {
            log.warn("spawn fx: empty or missing :cmd", .{});
            return;
        }

        if (c.janet_checktype(event_val, c.JANET_KEYWORD) == 0) {
            log.warn("spawn fx: missing :event keyword", .{});
            return;
        }

        // Kill existing spawn with same event id (replacement semantics)
        self.killSpawnByEvent(event_val);

        // Build argv (max 32 args + null terminator)
        const argc: usize = @intCast(cmd_view.len);
        if (argc > 32) {
            log.warn("spawn fx: too many args (max 32)", .{});
            return;
        }
        var argv: [33]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 33;
        for (0..argc) |i| {
            const s = cmd_view.items.?[i];
            if (c.janet_checktype(s, c.JANET_STRING) != 0) {
                argv[i] = @ptrCast(c.janet_unwrap_string(s));
            } else if (c.janet_checktype(s, c.JANET_KEYWORD) != 0) {
                argv[i] = @ptrCast(c.janet_unwrap_keyword(s));
            } else if (c.janet_checktype(s, c.JANET_SYMBOL) != 0) {
                argv[i] = @ptrCast(c.janet_unwrap_symbol(s));
            } else {
                log.warn("spawn fx: cmd element is not a string/keyword/symbol", .{});
                return;
            }
        }

        // Create pipe for child stdout
        const pipe_fds = std.posix.pipe() catch {
            log.warn("spawn fx: pipe() failed", .{});
            return;
        };

        // Fork
        const fork_result = std.posix.fork() catch {
            log.warn("spawn fx: fork() failed", .{});
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
            return;
        };

        if (fork_result == 0) {
            // Child process
            std.posix.close(pipe_fds[0]); // Close read end
            _ = std.posix.dup2(pipe_fds[1], 1) catch std.process.exit(127); // stdout = pipe write end
            std.posix.close(pipe_fds[1]); // Close original write end
            _ = posix_c.execvp(argv[0].?, @ptrCast(&argv));
            std.process.exit(127); // exec failed
        }

        // Parent process
        std.posix.close(pipe_fds[1]); // Close write end

        // Find free slot
        for (&self.spawns) |*slot| {
            if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .pid = @intCast(fork_result),
                    .stdout_fd = pipe_fds[0],
                    .event_id = event_val,
                    .done_id = done_val,
                    .line_len = 0,
                };
                c.janet_gcroot(event_val);
                if (c.janet_checktype(done_val, c.JANET_KEYWORD) != 0) {
                    c.janet_gcroot(done_val);
                }
                log.debug("spawn: pid={d} started", .{fork_result});
                return;
            }
        }

        log.warn("spawn fx: no free slots", .{});
        _ = posix_c.kill(@intCast(fork_result), posix_c.SIGKILL);
        _ = posix_c.waitpid(@intCast(fork_result), null, 0);
        std.posix.close(pipe_fds[0]);
    }

    fn killSpawnByEvent(self: *Dispatch, event_id: Janet) void {
        for (&self.spawns) |*slot| {
            if (slot.active and c.janet_equals(slot.event_id, event_id) != 0) {
                self.killSpawn(slot);
                return;
            }
        }
    }

    fn killSpawn(self: *Dispatch, slot: *SpawnSlot) void {
        if (slot.stdout_fd >= 0) {
            std.posix.close(slot.stdout_fd);
            slot.stdout_fd = -1;
        }
        _ = posix_c.kill(slot.pid, posix_c.SIGKILL);
        _ = posix_c.waitpid(slot.pid, null, 0);
        self.freeSpawnSlot(slot);
    }

    /// Called from main loop when poll indicates a spawn fd is readable.
    pub fn onSpawnReadable(self: *Dispatch, fd: std.posix.fd_t) void {
        for (&self.spawns) |*slot| {
            if (slot.active and slot.stdout_fd == fd) {
                self.readSpawnSlot(slot);
                return;
            }
        }
    }

    fn readSpawnSlot(self: *Dispatch, slot: *SpawnSlot) void {
        const available = SPAWN_BUF_SIZE - slot.line_len;
        if (available == 0) {
            // Buffer full with no newline — flush as a line
            self.enqueueSpawnLine(slot, slot.line_buf[0..slot.line_len]);
            slot.line_len = 0;
            return;
        }
        const n = std.posix.read(slot.stdout_fd, slot.line_buf[slot.line_len..]) catch {
            self.finishSpawn(slot);
            return;
        };
        if (n == 0) {
            self.finishSpawn(slot);
            return;
        }
        slot.line_len += n;
        self.drainSpawnLines(slot);
    }

    fn drainSpawnLines(self: *Dispatch, slot: *SpawnSlot) void {
        var start: usize = 0;
        for (0..slot.line_len) |i| {
            if (slot.line_buf[i] == '\n') {
                if (i > start) {
                    self.enqueueSpawnLine(slot, slot.line_buf[start..i]);
                }
                start = i + 1;
            }
        }
        if (start > 0) {
            const remaining = slot.line_len - start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, slot.line_buf[0..remaining], slot.line_buf[start..slot.line_len]);
            }
            slot.line_len = remaining;
        }
    }

    fn enqueueSpawnLine(self: *Dispatch, slot: *SpawnSlot, line: []const u8) void {
        const line_str = c.janet_string(line.ptr, @intCast(line.len));
        const items = [2]Janet{ slot.event_id, c.janet_wrap_string(line_str) };
        self.enqueue(makeTuple(&items));
    }

    fn finishSpawn(self: *Dispatch, slot: *SpawnSlot) void {
        const pid = slot.pid;
        if (slot.stdout_fd >= 0) {
            std.posix.close(slot.stdout_fd);
            slot.stdout_fd = -1;
        }

        // Flush remaining buffered data
        if (slot.line_len > 0) {
            self.enqueueSpawnLine(slot, slot.line_buf[0..slot.line_len]);
            slot.line_len = 0;
        }

        // Reap child
        var status: c_int = 0;
        _ = posix_c.waitpid(pid, &status, 0);
        const exit_code: i32 = if (posix_c.WIFEXITED(status))
            @intCast(posix_c.WEXITSTATUS(status))
        else
            -1;

        // Enqueue done event if configured
        if (c.janet_checktype(slot.done_id, c.JANET_KEYWORD) != 0) {
            const items = [2]Janet{ slot.done_id, c.janet_wrap_number(@floatFromInt(exit_code)) };
            self.enqueue(makeTuple(&items));
        }

        self.freeSpawnSlot(slot);
        log.debug("spawn: pid={d} exited code={d}", .{ pid, exit_code });
    }

    fn freeSpawnSlot(_: *Dispatch, slot: *SpawnSlot) void {
        if (c.janet_checktype(slot.event_id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.event_id);
        }
        if (c.janet_checktype(slot.done_id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.done_id);
        }
        slot.active = false;
        slot.stdout_fd = -1;
    }

    /// Fill a poll fd buffer with active spawn stdout fds. Returns count added.
    pub fn fillSpawnPollFds(self: *Dispatch, buf: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (self.spawns) |slot| {
            if (slot.active and slot.stdout_fd >= 0 and count < buf.len) {
                buf[count] = .{ .fd = slot.stdout_fd, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        return count;
    }

    // -------------------------------------------------------------------
    // IPC connection pool (Unix sockets)
    // -------------------------------------------------------------------

    /// Handle :ipc fx value. Dispatches to connect/send/disconnect.
    /// Value is a table with one of: {:connect {...}}, {:send {...}}, {:disconnect {:name :id}}
    fn handleIpcFx(self: *Dispatch, val: Janet) void {
        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc fx: expected table", .{});
            return;
        }

        const connect_val = janetGet(val, kw("connect"));
        if (c.janet_checktype(connect_val, c.JANET_NIL) == 0) {
            self.handleIpcConnect(connect_val);
        }

        const send_val = janetGet(val, kw("send"));
        if (c.janet_checktype(send_val, c.JANET_NIL) == 0) {
            self.handleIpcSend(send_val);
        }

        const disconnect_val = janetGet(val, kw("disconnect"));
        if (c.janet_checktype(disconnect_val, c.JANET_NIL) == 0) {
            self.handleIpcDisconnect(disconnect_val);
        }
    }

    /// Handle {:connect {:path "..." :name :id :framing :line/:netrepl :event :id ...}}
    fn handleIpcConnect(self: *Dispatch, spec: Janet) void {
        if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
            c.janet_checktype(spec, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc connect: expected table", .{});
            return;
        }

        const name_val = janetGet(spec, kw("name"));
        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc connect: missing :name keyword", .{});
            return;
        }

        const path_val = janetGet(spec, kw("path"));
        if (c.janet_checktype(path_val, c.JANET_STRING) == 0) {
            log.warn("ipc connect: missing :path string", .{});
            return;
        }
        const path_str = c.janet_unwrap_string(path_val);
        const path_len: usize = @intCast(c.janet_string_length(path_str));
        if (path_len >= 256) {
            log.warn("ipc connect: path too long", .{});
            return;
        }

        const event_val = janetGet(spec, kw("event"));
        if (c.janet_checktype(event_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc connect: missing :event keyword", .{});
            return;
        }

        // Parse framing mode
        const framing_val = janetGet(spec, kw("framing"));
        const framing: IpcFraming = blk: {
            if (c.janet_checktype(framing_val, c.JANET_KEYWORD) != 0) {
                const s = std.mem.span(c.janet_unwrap_keyword(framing_val));
                if (std.mem.eql(u8, s, "netrepl")) break :blk .netrepl;
            }
            break :blk .line;
        };

        // Optional event ids
        const connected_val = janetGet(spec, kw("connected"));
        const disconnected_val = janetGet(spec, kw("disconnected"));

        // Reconnect delay
        const reconnect_val = janetGet(spec, kw("reconnect"));
        const reconnect_delay: f64 = if (c.janet_checktype(reconnect_val, c.JANET_NUMBER) != 0)
            c.janet_unwrap_number(reconnect_val)
        else
            0;

        // Handshake (for netrepl)
        const handshake_val = janetGet(spec, kw("handshake"));

        // Disconnect any existing connection with this name
        self.disconnectByName(name_val);

        // Create Unix socket and connect
        const fd = self.ipcSocketConnect(path_str[0..path_len]) orelse {
            log.warn("ipc connect: failed to connect to {s}", .{path_str[0..path_len]});
            // Schedule reconnect if configured
            if (reconnect_delay > 0) {
                self.scheduleIpcReconnect(spec, reconnect_delay);
            }
            return;
        };

        // Find a free slot
        for (&self.ipcs) |*slot| {
            if (!slot.active) {
                slot.active = true;
                slot.fd = fd;
                slot.name = name_val;
                slot.event_id = event_val;
                slot.connected_id = connected_val;
                slot.disconnected_id = disconnected_val;
                slot.framing = framing;
                slot.reconnect_delay = reconnect_delay;
                @memcpy(slot.path[0..path_len], path_str[0..path_len]);
                slot.path_len = path_len;
                slot.recv_len = 0;
                slot.netrepl_msg_len = null;
                slot.netrepl_hdr_len = 0;

                // GC root all keyword values
                c.janet_gcroot(name_val);
                c.janet_gcroot(event_val);
                if (c.janet_checktype(connected_val, c.JANET_KEYWORD) != 0) {
                    c.janet_gcroot(connected_val);
                }
                if (c.janet_checktype(disconnected_val, c.JANET_KEYWORD) != 0) {
                    c.janet_gcroot(disconnected_val);
                }

                // Store handshake if provided
                if (c.janet_checktype(handshake_val, c.JANET_STRING) != 0) {
                    const hs_str = c.janet_unwrap_string(handshake_val);
                    const hs_len: usize = @intCast(c.janet_string_length(hs_str));
                    slot.handshake = hs_str[0..hs_len];
                    slot.handshake_janet = handshake_val;
                    c.janet_gcroot(handshake_val);
                } else {
                    slot.handshake = null;
                    slot.handshake_janet = c.janet_wrap_nil();
                }

                log.info("ipc: connected to {s} as :{s}", .{
                    path_str[0..path_len],
                    std.mem.span(c.janet_unwrap_keyword(name_val)),
                });

                // Send handshake if configured (netrepl: length-prefixed)
                if (slot.handshake) |hs| {
                    self.ipcSendRaw(slot, hs);
                }

                // Enqueue connected event
                if (c.janet_checktype(connected_val, c.JANET_KEYWORD) != 0) {
                    self.enqueue(makeEvent(std.mem.span(c.janet_unwrap_keyword(connected_val))));
                }

                return;
            }
        }

        log.warn("ipc connect: no free slots", .{});
        std.posix.close(fd);
    }

    /// Create a Unix socket and connect to the given path. Returns fd or null.
    fn ipcSocketConnect(_: *Dispatch, path: []const u8) ?std.posix.fd_t {
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
            return null;
        };
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) return null;
        @memcpy(addr.path[0..path.len], path);

        std.posix.connect(
            fd,
            @ptrCast(&addr),
            @intCast(@sizeOf(std.posix.sockaddr.un)),
        ) catch {
            std.posix.close(fd);
            return null;
        };

        return fd;
    }

    /// Send raw bytes on an IPC slot. For netrepl, prepends 4-byte LE length header.
    fn ipcSendRaw(_: *Dispatch, slot: *IpcSlot, data: []const u8) void {
        if (slot.framing == .netrepl) {
            // Netrepl: 4-byte LE length prefix
            const len: u32 = @intCast(data.len);
            const hdr = std.mem.toBytes(std.mem.nativeToLittle(u32, len));
            _ = std.posix.write(slot.fd, &hdr) catch {
                log.warn("ipc send: write header failed", .{});
                return;
            };
        }
        _ = std.posix.write(slot.fd, data) catch {
            log.warn("ipc send: write failed", .{});
        };
    }

    /// Handle {:send {:name :id :data "..."}}
    fn handleIpcSend(self: *Dispatch, spec: Janet) void {
        if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
            c.janet_checktype(spec, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc send: expected table", .{});
            return;
        }

        const name_val = janetGet(spec, kw("name"));
        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc send: missing :name keyword", .{});
            return;
        }

        const data_val = janetGet(spec, kw("data"));
        if (c.janet_checktype(data_val, c.JANET_STRING) == 0) {
            log.warn("ipc send: missing :data string", .{});
            return;
        }
        const data_str = c.janet_unwrap_string(data_val);
        const data_len: usize = @intCast(c.janet_string_length(data_str));

        for (&self.ipcs) |*slot| {
            if (slot.active and c.janet_equals(slot.name, name_val) != 0) {
                self.ipcSendRaw(slot, data_str[0..data_len]);
                return;
            }
        }

        log.warn("ipc send: no connection named :{s}", .{
            std.mem.span(c.janet_unwrap_keyword(name_val)),
        });
    }

    /// Handle {:disconnect {:name :id}}
    fn handleIpcDisconnect(self: *Dispatch, spec: Janet) void {
        const name_val = if (c.janet_checktype(spec, c.JANET_KEYWORD) != 0)
            spec
        else blk: {
            if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
                c.janet_checktype(spec, c.JANET_STRUCT) == 0)
            {
                log.warn("ipc disconnect: expected table or keyword", .{});
                return;
            }
            break :blk janetGet(spec, kw("name"));
        };

        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc disconnect: missing :name keyword", .{});
            return;
        }

        self.disconnectByName(name_val);
    }

    /// Disconnect and free an IPC connection by name. Does not schedule reconnect.
    fn disconnectByName(self: *Dispatch, name: Janet) void {
        for (&self.ipcs) |*slot| {
            if (slot.active and c.janet_equals(slot.name, name) != 0) {
                self.closeIpcSlot(slot, false);
                return;
            }
        }
    }

    /// Close an IPC connection. If `reconnect` is true and the slot has reconnect
    /// configured, schedules a reconnect timer.
    fn closeIpcSlot(self: *Dispatch, slot: *IpcSlot, reconnect: bool) void {
        if (slot.fd >= 0) {
            std.posix.close(slot.fd);
            slot.fd = -1;
        }

        log.info("ipc: disconnected :{s}", .{
            std.mem.span(c.janet_unwrap_keyword(slot.name)),
        });

        // Enqueue disconnected event
        if (c.janet_checktype(slot.disconnected_id, c.JANET_KEYWORD) != 0) {
            self.enqueue(makeEvent(std.mem.span(c.janet_unwrap_keyword(slot.disconnected_id))));
        }

        // Schedule reconnect if applicable
        if (reconnect and slot.reconnect_delay > 0) {
            self.scheduleIpcReconnectFromSlot(slot);
        }

        self.freeIpcSlot(slot);
    }

    /// Schedule a reconnect by creating a timer that dispatches an internal
    /// reconnect event. We store the connect spec in a :dispatch event.
    fn scheduleIpcReconnect(self: *Dispatch, spec: Janet, delay: f64) void {
        // Create timer: {:delay N :event [:_ipc-reconnect spec] :id :_ipc-reconnect/name}
        const reconnect_event_items = [2]Janet{ kw("_ipc-reconnect"), spec };
        const reconnect_event = makeTuple(&reconnect_event_items);

        // Use a named timer so repeated failures don't stack timers
        const name_val = janetGet(spec, kw("name"));
        _ = name_val; // timer id is the reconnect event keyword itself

        const timer_spec = c.janet_table(4);
        c.janet_table_put(timer_spec, kw("delay"), c.janet_wrap_number(delay));
        c.janet_table_put(timer_spec, kw("event"), reconnect_event);
        // TODO: ideally use a unique timer id per connection name
        self.handleTimerFx(c.janet_wrap_table(timer_spec));
    }

    /// Schedule reconnect from a slot that's about to be freed.
    fn scheduleIpcReconnectFromSlot(self: *Dispatch, slot: *IpcSlot) void {
        // Reconstruct the connect spec from the slot's stored values
        const spec = c.janet_table(8);
        const path_str = c.janet_string(slot.path[0..slot.path_len].ptr, @intCast(slot.path_len));
        c.janet_table_put(spec, kw("path"), c.janet_wrap_string(path_str));
        c.janet_table_put(spec, kw("name"), slot.name);
        c.janet_table_put(spec, kw("event"), slot.event_id);
        c.janet_table_put(spec, kw("framing"), kw(if (slot.framing == .netrepl) "netrepl" else "line"));
        c.janet_table_put(spec, kw("reconnect"), c.janet_wrap_number(slot.reconnect_delay));
        if (c.janet_checktype(slot.connected_id, c.JANET_KEYWORD) != 0) {
            c.janet_table_put(spec, kw("connected"), slot.connected_id);
        }
        if (c.janet_checktype(slot.disconnected_id, c.JANET_KEYWORD) != 0) {
            c.janet_table_put(spec, kw("disconnected"), slot.disconnected_id);
        }
        if (slot.handshake != null) {
            c.janet_table_put(spec, kw("handshake"), slot.handshake_janet);
        }

        self.scheduleIpcReconnect(c.janet_wrap_table(spec), slot.reconnect_delay);
    }

    /// Called from main loop when poll indicates an IPC fd is readable.
    pub fn onIpcReadable(self: *Dispatch, fd: std.posix.fd_t) void {
        for (&self.ipcs) |*slot| {
            if (slot.active and slot.fd == fd) {
                self.readIpcSlot(slot);
                return;
            }
        }
    }

    fn readIpcSlot(self: *Dispatch, slot: *IpcSlot) void {
        const available = IPC_BUF_SIZE - slot.recv_len;
        if (available == 0) {
            // Buffer full — for line mode, flush as oversized line; for netrepl, error
            if (slot.framing == .line) {
                self.enqueueIpcMessage(slot, slot.recv_buf[0..slot.recv_len], .line);
                slot.recv_len = 0;
            } else {
                log.warn("ipc: netrepl recv buffer overflow", .{});
                self.closeIpcSlot(slot, true);
            }
            return;
        }

        const n = std.posix.read(slot.fd, slot.recv_buf[slot.recv_len..]) catch {
            self.closeIpcSlot(slot, true);
            return;
        };
        if (n == 0) {
            // EOF — remote closed
            self.closeIpcSlot(slot, true);
            return;
        }

        slot.recv_len += n;

        switch (slot.framing) {
            .line => self.drainIpcLines(slot),
            .netrepl => self.drainIpcNetrepl(slot),
        }
    }

    /// Line framing: split on newlines, enqueue each complete line.
    fn drainIpcLines(self: *Dispatch, slot: *IpcSlot) void {
        var start: usize = 0;
        for (0..slot.recv_len) |i| {
            if (slot.recv_buf[i] == '\n') {
                if (i > start) {
                    self.enqueueIpcMessage(slot, slot.recv_buf[start..i], .line);
                }
                start = i + 1;
            }
        }
        if (start > 0) {
            const remaining = slot.recv_len - start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, slot.recv_buf[0..remaining], slot.recv_buf[start..slot.recv_len]);
            }
            slot.recv_len = remaining;
        }
    }

    /// Netrepl framing: 4-byte LE length prefix + message body.
    /// Messages may have a type byte: 0xFF = output, 0xFE = return.
    fn drainIpcNetrepl(self: *Dispatch, slot: *IpcSlot) void {
        while (slot.recv_len > 0) {
            if (slot.netrepl_msg_len == null) {
                // Reading header — need 4 bytes
                while (slot.netrepl_hdr_len < 4 and slot.recv_len > 0) {
                    // Consume one byte at a time from recv_buf into hdr_buf
                    slot.netrepl_hdr_buf[slot.netrepl_hdr_len] = slot.recv_buf[0];
                    slot.netrepl_hdr_len += 1;
                    // Shift recv_buf forward by 1
                    slot.recv_len -= 1;
                    if (slot.recv_len > 0) {
                        std.mem.copyForwards(u8, slot.recv_buf[0..slot.recv_len], slot.recv_buf[1 .. slot.recv_len + 1]);
                    }
                }
                if (slot.netrepl_hdr_len < 4) break; // need more data

                slot.netrepl_msg_len = std.mem.readInt(u32, &slot.netrepl_hdr_buf, .little);
                slot.netrepl_hdr_len = 0;

                if (slot.netrepl_msg_len.? > IPC_BUF_SIZE) {
                    log.warn("ipc: netrepl message too large ({d} bytes)", .{slot.netrepl_msg_len.?});
                    self.closeIpcSlot(slot, true);
                    return;
                }
            }

            const msg_len = slot.netrepl_msg_len.?;
            if (slot.recv_len < msg_len) break; // need more data

            // Have complete message
            const payload = slot.recv_buf[0..msg_len];
            self.enqueueIpcMessage(slot, payload, .netrepl);

            // Consume message from buffer
            const remaining = slot.recv_len - msg_len;
            if (remaining > 0) {
                std.mem.copyForwards(u8, slot.recv_buf[0..remaining], slot.recv_buf[msg_len..slot.recv_len]);
            }
            slot.recv_len = remaining;
            slot.netrepl_msg_len = null;
        }
    }

    /// Enqueue a received IPC message as an event.
    /// Line mode: [:event-id "line"]
    /// Netrepl mode: [:event-id :output/:return/:text "payload"]
    fn enqueueIpcMessage(self: *Dispatch, slot: *IpcSlot, data: []const u8, framing: IpcFraming) void {
        if (framing == .netrepl and data.len > 0) {
            // Classify by first byte
            const type_kw = switch (data[0]) {
                0xFF => kw("output"),
                0xFE => kw("return"),
                else => kw("text"),
            };
            const payload = if (data[0] == 0xFF or data[0] == 0xFE) data[1..] else data;
            const payload_str = c.janet_string(payload.ptr, @intCast(payload.len));
            const items = [3]Janet{ slot.event_id, type_kw, c.janet_wrap_string(payload_str) };
            self.enqueue(makeTuple(&items));
        } else {
            const data_str = c.janet_string(data.ptr, @intCast(data.len));
            const items = [2]Janet{ slot.event_id, c.janet_wrap_string(data_str) };
            self.enqueue(makeTuple(&items));
        }
    }

    /// Fill a poll fd buffer with active IPC connection fds. Returns count added.
    pub fn fillIpcPollFds(self: *Dispatch, buf: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (self.ipcs) |slot| {
            if (slot.active and slot.fd >= 0 and count < buf.len) {
                buf[count] = .{ .fd = slot.fd, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        return count;
    }

    fn freeIpcSlot(_: *Dispatch, slot: *IpcSlot) void {
        if (c.janet_checktype(slot.name, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.name);
        }
        if (c.janet_checktype(slot.event_id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.event_id);
        }
        if (c.janet_checktype(slot.connected_id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.connected_id);
        }
        if (c.janet_checktype(slot.disconnected_id, c.JANET_KEYWORD) != 0) {
            _ = c.janet_gcunroot(slot.disconnected_id);
        }
        if (slot.handshake != null) {
            _ = c.janet_gcunroot(slot.handshake_janet);
        }
        slot.active = false;
        slot.fd = -1;
    }

    /// Update the db, managing GC roots.
    fn setDb(self: *Dispatch, new_db: Janet) void {
        _ = c.janet_gcunroot(self.db);
        self.db = new_db;
        c.janet_gcroot(new_db);
    }

    /// Set the current db for subscription evaluation. Call before view fn.
    pub fn prepareRender(self: *Dispatch) void {
        _ = self.pcall1(self.fn_set_current_db, self.db);
    }

    /// Call the registered view function and walk the resulting hiccup tree.
    /// Call prepareRender() first to set up the db for subscriptions.
    /// Returns true if a view was rendered, false if no view fn registered.
    pub fn renderView(self: *Dispatch) bool {
        // Get the view function
        const view_fn_val = self.pcall0(self.fn_get_view_fn) orelse return false;
        if (c.janet_checktype(view_fn_val, c.JANET_NIL) != 0) return false;

        // Call the view function (no args) → hiccup tree
        const hiccup_tree = self.pcall0(view_fn_val) orelse return false;

        // Walk the hiccup tree, emitting Clay calls
        hiccup.walkHiccup(hiccup_tree);
        return true;
    }

    /// Protected call with 0 arguments. Returns result or null on error.
    fn pcall0(self: *Dispatch, func: Janet) ?Janet {
        _ = self;
        if (c.janet_checktype(func, c.JANET_FUNCTION) == 0) {
            log.warn("pcall0: not a function", .{});
            return null;
        }
        var out: Janet = undefined;
        const fiber = c.janet_fiber(c.janet_unwrap_function(func), 64, 0, null);
        if (fiber == null) {
            log.warn("pcall0: could not create fiber", .{});
            return null;
        }
        const signal = c.janet_continue(fiber, c.janet_wrap_nil(), &out);
        if (signal != c.JANET_SIGNAL_OK) {
            log.warn("pcall0: Janet error: {s}", .{janetToStr(out)});
            return null;
        }
        return out;
    }

    /// Protected call with 1 argument. Returns result or null on error.
    fn pcall1(self: *Dispatch, func: Janet, arg: Janet) ?Janet {
        _ = self;
        if (c.janet_checktype(func, c.JANET_FUNCTION) == 0) {
            log.warn("pcall1: not a function", .{});
            return null;
        }
        var out: Janet = undefined;
        const fiber = c.janet_fiber(c.janet_unwrap_function(func), 64, 1, &arg);
        if (fiber == null) {
            log.warn("pcall1: could not create fiber", .{});
            return null;
        }
        const signal = c.janet_continue(fiber, c.janet_wrap_nil(), &out);
        if (signal != c.JANET_SIGNAL_OK) {
            log.warn("pcall1: Janet error: {s}", .{janetToStr(out)});
            return null;
        }
        return out;
    }

    /// Protected call with 2 arguments. Returns result or null on error.
    fn pcall2(self: *Dispatch, func: Janet, arg1: Janet, arg2: Janet) ?Janet {
        _ = self;
        if (c.janet_checktype(func, c.JANET_FUNCTION) == 0) {
            log.warn("pcall2: not a function", .{});
            return null;
        }
        var args = [2]Janet{ arg1, arg2 };
        var out: Janet = undefined;
        const fiber = c.janet_fiber(c.janet_unwrap_function(func), 64, 2, &args);
        if (fiber == null) {
            log.warn("pcall2: could not create fiber", .{});
            return null;
        }
        const signal = c.janet_continue(fiber, c.janet_wrap_nil(), &out);
        if (signal != c.JANET_SIGNAL_OK) {
            log.warn("pcall2: Janet error: {s}", .{janetToStr(out)});
            return null;
        }
        return out;
    }

    /// Evaluate Janet source in the dispatch environment.
    pub fn eval(self: *Dispatch, source: [:0]const u8, source_path: [:0]const u8) !Janet {
        return doString(self.env, source, source_path);
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
        for (&self.spawns) |*slot| {
            if (slot.active) self.killSpawn(slot);
        }
        // Close IPC connections
        for (&self.ipcs) |*slot| {
            if (slot.active) {
                if (slot.fd >= 0) {
                    std.posix.close(slot.fd);
                    slot.fd = -1;
                }
                self.freeIpcSlot(slot);
            }
        }
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

const anim_cfun = [_]c.JanetReg{
    .{ .name = "anim", .cfun = janetAnimFn, .documentation = "(anim :id) — get current animated value" },
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
// Helpers
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

/// Look up a keyword-keyed value in a Janet table or struct.
pub fn janetGet(collection: Janet, key: Janet) Janet {
    if (c.janet_checktype(collection, c.JANET_TABLE) != 0) {
        const tbl = c.janet_unwrap_table(collection);
        return c.janet_table_get(tbl, key);
    } else if (c.janet_checktype(collection, c.JANET_STRUCT) != 0) {
        const s = c.janet_unwrap_struct(collection);
        return c.janet_struct_get(s, key);
    }
    return c.janet_wrap_nil();
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
    // In Janet, environment entries are tables with a :value key
    if (c.janet_checktype(binding, c.JANET_TABLE) != 0) {
        const val = c.janet_table_get(c.janet_unwrap_table(binding), kw("value"));
        if (c.janet_checktype(val, c.JANET_NIL) != 0) return null;
        return val;
    }
    return null;
}

/// Wrap a Zig string as a Janet keyword.
pub fn kw(name: [:0]const u8) Janet {
    return c.janet_ckeywordv(name.ptr);
}

/// Get current monotonic time in seconds.
fn monotonicNow() f64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
}

/// Convert a Janet value to a string for logging.
fn janetToStr(val: Janet) [*:0]const u8 {
    return @ptrCast(c.janet_to_string(val));
}

/// Construct a Janet tuple from a slice of values.
pub fn makeTuple(items: []const Janet) Janet {
    const buf = c.janet_tuple_begin(@intCast(items.len));
    for (items, 0..) |item, i| {
        buf[@intCast(i)] = item;
    }
    return c.janet_wrap_tuple(c.janet_tuple_end(buf));
}

/// Construct a single-keyword event tuple like [:init]
pub fn makeEvent(name: [:0]const u8) Janet {
    const items = [1]Janet{kw(name)};
    return makeTuple(&items);
}

/// Construct an event tuple with arguments like [:event-id arg1 arg2 ...]
pub fn makeEventArgs(name: [:0]const u8, args: []const Janet) Janet {
    const n = args.len + 1;
    const buf = c.janet_tuple_begin(@intCast(n));
    buf[0] = kw(name);
    for (args, 0..) |arg, i| {
        buf[@intCast(i + 1)] = arg;
    }
    return c.janet_wrap_tuple(c.janet_tuple_end(buf));
}

const IndexedView = struct {
    items: ?[*c]const Janet,
    len: i32,
};

/// Get an indexed view (items + len) from a tuple or array.
fn janetIndexedView(val: Janet) IndexedView {
    var items: [*c]const Janet = null;
    var len: i32 = 0;
    if (c.janet_indexed_view(val, &items, &len) != 0) {
        return .{ .items = items, .len = len };
    }
    return .{ .items = null, .len = 0 };
}

