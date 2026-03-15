const std = @import("std");
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

pub const Dispatch = struct {
    env: *JanetTable,
    db: Janet,
    render_dirty: bool = false,

    // Cached function references (set by initBoot)
    fn_get_handler: Janet = undefined,
    fn_get_cofx_injector: Janet = undefined,
    fn_get_fx_executor: Janet = undefined,

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

        // GC root the db so it survives between event cycles
        c.janet_gcroot(self.db);

        log.info("shoal boot loaded, dispatch ready", .{});
    }

    /// Dispatch a single event. Looks up handler, builds cofx, calls handler,
    /// executes returned fx. Sets render_dirty if :render fx is truthy.
    pub fn dispatch(self: *Dispatch, event: Janet) void {
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
            } else if (std.mem.eql(u8, fx_name, "render")) {
                self.render_dirty = true;
            } else if (std.mem.eql(u8, fx_name, "dispatch")) {
                // Queue a follow-up event (recursive dispatch after current fx)
                self.dispatch(fx_val);
            } else if (std.mem.eql(u8, fx_name, "dispatch-n")) {
                self.dispatchMultiple(fx_val);
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

    fn dispatchMultiple(self: *Dispatch, events: Janet) void {
        const view = janetIndexedView(events);
        if (view.items) |items| {
            for (0..@intCast(view.len)) |i| {
                self.dispatch(items[i]);
            }
        }
    }

    /// Update the db, managing GC roots.
    fn setDb(self: *Dispatch, new_db: Janet) void {
        _ = c.janet_gcunroot(self.db);
        self.db = new_db;
        c.janet_gcroot(new_db);
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

