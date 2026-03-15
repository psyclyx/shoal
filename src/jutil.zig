const std = @import("std");

pub const c = @cImport({
    @cInclude("janet.h");
});

pub const Janet = c.Janet;
pub const JanetTable = c.JanetTable;

/// Wrap a Zig string as a Janet keyword.
pub fn kw(name: [:0]const u8) Janet {
    return c.janet_ckeywordv(name.ptr);
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

pub const IndexedView = struct {
    items: ?[*c]const Janet,
    len: i32,
};

/// Get an indexed view (items + len) from a tuple or array.
pub fn janetIndexedView(val: Janet) IndexedView {
    var items: [*c]const Janet = null;
    var len: i32 = 0;
    if (c.janet_indexed_view(val, &items, &len) != 0) {
        return .{ .items = items, .len = len };
    }
    return .{ .items = null, .len = 0 };
}

/// Convert a Janet value to a string for logging.
pub fn janetToStr(val: Janet) [*:0]const u8 {
    return @ptrCast(c.janet_to_string(val));
}

/// Callback interface for enqueuing events and scheduling timers.
pub const EventSink = struct {
    ctx: *anyopaque,
    enqueue: *const fn (*anyopaque, Janet) void,
    timer: ?*const fn (*anyopaque, Janet) void = null,
};
