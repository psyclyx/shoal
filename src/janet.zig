const std = @import("std");
const hiccup = @import("hiccup.zig");
const log = std.log.scoped(.janet);

pub const c = @cImport({
    @cInclude("janet.h");
});

pub const Janet = c.Janet;
pub const JanetTable = c.JanetTable;

const boot_source = @embedFile("shoal.janet");

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

    // Cached function references (set by initBoot)
    fn_get_handler: Janet = undefined,
    fn_get_cofx_injector: Janet = undefined,
    fn_get_fx_executor: Janet = undefined,
    fn_bump_generation: Janet = undefined,
    fn_set_current_db: Janet = undefined,
    fn_get_view_fn: Janet = undefined,

    /// Load the shoal boot file into a fresh environment. Sets up registries.
    pub fn initBoot(self: *Dispatch) !void {
        // Evaluate boot source
        var out: Janet = undefined;
        const status = c.janet_dostring(
            self.env,
            boot_source.ptr,
            "shoal.janet",
            &out,
        );
        if (status != 0) return error.BootFailed;

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
            } else if (std.mem.eql(u8, fx_name, "render")) {
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "dispatch")) {
                self.enqueue(fx_val);
            } else if (std.mem.eql(u8, fx_name, "dispatch-n")) {
                self.enqueueMultiple(fx_val);
            } else if (std.mem.eql(u8, fx_name, "timer")) {
                self.handleTimerFx(fx_val);
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
        _ = c.janet_gcunroot(self.db);
    }
};

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

