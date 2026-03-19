const std = @import("std");
const jt = @import("jutil.zig");
const c = jt.c;
const Janet = jt.Janet;
const log = std.log.scoped(.ipc);

pub const MAX_IPC_CONNS = 8;
const BUF_SIZE = 65536;

pub const IpcFraming = enum { line, netrepl };

pub const IpcSlot = struct {
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
    recv_buf: [BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,

    // Netrepl framing state
    netrepl_msg_len: ?u32 = null, // expected message length (null = reading header)
    netrepl_hdr_buf: [4]u8 = undefined, // partial header bytes
    netrepl_hdr_len: usize = 0,
};

pub const IpcPool = struct {
    slots: [MAX_IPC_CONNS]IpcSlot = [_]IpcSlot{.{}} ** MAX_IPC_CONNS,

    /// Handle :ipc fx value. Dispatches to connect/send/disconnect.
    pub fn handleFx(self: *IpcPool, val: Janet, sink: jt.EventSink) void {
        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc fx: expected table", .{});
            return;
        }

        const connect_val = jt.janetGet(val, jt.kw("connect"));
        if (c.janet_checktype(connect_val, c.JANET_NIL) == 0) {
            self.handleConnect(connect_val, sink);
        }

        const send_val = jt.janetGet(val, jt.kw("send"));
        if (c.janet_checktype(send_val, c.JANET_NIL) == 0) {
            self.handleSend(send_val);
        }

        const disconnect_val = jt.janetGet(val, jt.kw("disconnect"));
        if (c.janet_checktype(disconnect_val, c.JANET_NIL) == 0) {
            self.handleDisconnect(disconnect_val, sink);
        }
    }

    /// Handle {:connect {:path "..." :name :id :framing :line/:netrepl :event :id ...}}
    fn handleConnect(self: *IpcPool, spec: Janet, sink: jt.EventSink) void {
        if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
            c.janet_checktype(spec, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc connect: expected table", .{});
            return;
        }

        const name_val = jt.janetGet(spec, jt.kw("name"));
        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc connect: missing :name keyword", .{});
            return;
        }

        const path_val = jt.janetGet(spec, jt.kw("path"));
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

        const event_val = jt.janetGet(spec, jt.kw("event"));
        if (c.janet_checktype(event_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc connect: missing :event keyword", .{});
            return;
        }

        // Parse framing mode
        const framing_val = jt.janetGet(spec, jt.kw("framing"));
        const framing: IpcFraming = blk: {
            if (c.janet_checktype(framing_val, c.JANET_KEYWORD) != 0) {
                const s = std.mem.span(c.janet_unwrap_keyword(framing_val));
                if (std.mem.eql(u8, s, "netrepl")) break :blk .netrepl;
            }
            break :blk .line;
        };

        // Optional event ids
        const connected_val = jt.janetGet(spec, jt.kw("connected"));
        const disconnected_val = jt.janetGet(spec, jt.kw("disconnected"));

        // Reconnect delay
        const reconnect_val = jt.janetGet(spec, jt.kw("reconnect"));
        const reconnect_delay: f64 = if (c.janet_checktype(reconnect_val, c.JANET_NUMBER) != 0)
            c.janet_unwrap_number(reconnect_val)
        else
            0;

        // Handshake (for netrepl)
        const handshake_val = jt.janetGet(spec, jt.kw("handshake"));

        // Disconnect any existing connection with this name
        self.disconnectByName(name_val, sink);

        // Create Unix socket and connect
        const fd = socketConnect(path_str[0..path_len]) orelse {
            log.warn("ipc connect: failed to connect to {s}", .{path_str[0..path_len]});
            // Schedule reconnect if configured — root spec first since
            // scheduleReconnect allocates (makeTuple) and spec is only on
            // the C stack (unrooted fx map value, invisible to GC).
            if (reconnect_delay > 0) {
                c.janet_gcroot(spec);
                defer _ = c.janet_gcunroot(spec);
                scheduleReconnect(spec, reconnect_delay, sink);
            }
            return;
        };

        // Find a free slot
        for (&self.slots) |*slot| {
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
                    sendRaw(slot, hs);
                }

                // Enqueue connected event
                if (c.janet_checktype(connected_val, c.JANET_KEYWORD) != 0) {
                    sink.enqueue(sink.ctx, jt.makeEvent(std.mem.span(c.janet_unwrap_keyword(connected_val))));
                }

                return;
            }
        }

        log.warn("ipc connect: no free slots", .{});
        std.posix.close(fd);
    }

    /// Create a Unix socket and connect to the given path. Returns fd or null.
    fn socketConnect(path: []const u8) ?std.posix.fd_t {
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch {
            return null;
        };

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) {
            std.posix.close(fd);
            return null;
        }
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
    fn sendRaw(slot: *IpcSlot, data: []const u8) void {
        if (slot.framing == .netrepl) {
            // Netrepl: 4-byte LE length prefix
            const len: u32 = @intCast(data.len);
            const hdr = std.mem.toBytes(std.mem.nativeToLittle(u32, len));
            writeAll(slot.fd, &hdr) catch {
                log.warn("ipc send: write header failed", .{});
                return;
            };
        }
        writeAll(slot.fd, data) catch {
            log.warn("ipc send: write failed", .{});
        };
    }

    /// Write all bytes to fd, retrying on partial writes.
    fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            remaining = remaining[std.posix.write(fd, remaining) catch |err| return err..];
        }
    }

    /// Handle {:send {:name :id :data "..."}}
    fn handleSend(self: *IpcPool, spec: Janet) void {
        if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
            c.janet_checktype(spec, c.JANET_STRUCT) == 0)
        {
            log.warn("ipc send: expected table", .{});
            return;
        }

        const name_val = jt.janetGet(spec, jt.kw("name"));
        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc send: missing :name keyword", .{});
            return;
        }

        const data_val = jt.janetGet(spec, jt.kw("data"));
        if (c.janet_checktype(data_val, c.JANET_STRING) == 0) {
            log.warn("ipc send: missing :data string", .{});
            return;
        }
        const data_str = c.janet_unwrap_string(data_val);
        const data_len: usize = @intCast(c.janet_string_length(data_str));

        for (&self.slots) |*slot| {
            if (slot.active and c.janet_equals(slot.name, name_val) != 0) {
                sendRaw(slot, data_str[0..data_len]);
                return;
            }
        }

        log.warn("ipc send: no connection named :{s}", .{
            std.mem.span(c.janet_unwrap_keyword(name_val)),
        });
    }

    /// Handle {:disconnect {:name :id}}
    fn handleDisconnect(self: *IpcPool, spec: Janet, sink: jt.EventSink) void {
        const name_val = if (c.janet_checktype(spec, c.JANET_KEYWORD) != 0)
            spec
        else blk: {
            if (c.janet_checktype(spec, c.JANET_TABLE) == 0 and
                c.janet_checktype(spec, c.JANET_STRUCT) == 0)
            {
                log.warn("ipc disconnect: expected table or keyword", .{});
                return;
            }
            break :blk jt.janetGet(spec, jt.kw("name"));
        };

        if (c.janet_checktype(name_val, c.JANET_KEYWORD) == 0) {
            log.warn("ipc disconnect: missing :name keyword", .{});
            return;
        }

        self.disconnectByName(name_val, sink);
    }

    /// Disconnect and free an IPC connection by name. Does not schedule reconnect.
    fn disconnectByName(self: *IpcPool, name: Janet, sink: jt.EventSink) void {
        for (&self.slots) |*slot| {
            if (slot.active and c.janet_equals(slot.name, name) != 0) {
                self.closeSlot(slot, false, sink);
                return;
            }
        }
    }

    /// Close an IPC connection. If `reconnect` is true and the slot has reconnect
    /// configured, schedules a reconnect timer.
    fn closeSlot(_: *IpcPool, slot: *IpcSlot, reconnect: bool, sink: jt.EventSink) void {
        if (slot.fd >= 0) {
            std.posix.close(slot.fd);
            slot.fd = -1;
        }

        log.info("ipc: disconnected :{s}", .{
            std.mem.span(c.janet_unwrap_keyword(slot.name)),
        });

        // Enqueue disconnected event
        if (c.janet_checktype(slot.disconnected_id, c.JANET_KEYWORD) != 0) {
            sink.enqueue(sink.ctx, jt.makeEvent(std.mem.span(c.janet_unwrap_keyword(slot.disconnected_id))));
        }

        // Schedule reconnect if applicable
        if (reconnect and slot.reconnect_delay > 0) {
            reconnectFromSlot(slot, sink);
        }

        freeSlot(slot);
    }

    /// Schedule a reconnect by creating a timer that dispatches an internal
    /// reconnect event.
    fn scheduleReconnect(spec: Janet, delay: f64, sink: jt.EventSink) void {
        const timer_fn = sink.timer orelse {
            log.warn("ipc: no timer callback for reconnect", .{});
            return;
        };

        // Create timer: {:delay N :event [:_ipc-reconnect spec] :id name}
        const reconnect_event_items = [2]Janet{ jt.kw("_ipc-reconnect"), spec };
        const reconnect_event = jt.makeTuple(&reconnect_event_items);

        // Root the event tuple before further allocations — janet_table below
        // can trigger GC, and reconnect_event/spec are only on the C stack.
        c.janet_gcroot(reconnect_event);
        defer _ = c.janet_gcunroot(reconnect_event);

        // Use the connection name as timer id so repeated failures replace
        // rather than stack timers
        const name_val = jt.janetGet(spec, jt.kw("name"));

        const timer_spec = c.janet_table(4);
        const timer_spec_val = c.janet_wrap_table(timer_spec);
        c.janet_gcroot(timer_spec_val);
        defer _ = c.janet_gcunroot(timer_spec_val);
        c.janet_table_put(timer_spec, jt.kw("delay"), c.janet_wrap_number(delay));
        c.janet_table_put(timer_spec, jt.kw("event"), reconnect_event);
        if (c.janet_checktype(name_val, c.JANET_NIL) == 0) {
            c.janet_table_put(timer_spec, jt.kw("id"), name_val);
        }
        timer_fn(sink.ctx, timer_spec_val);
    }

    /// Schedule reconnect from a slot that's about to be freed.
    fn reconnectFromSlot(slot: *IpcSlot, sink: jt.EventSink) void {
        // Reconstruct the connect spec from the slot's stored values
        // Pre-intern all keywords before any Janet allocation — janet_string
        // below allocates a GC-managed string, and interleaving kw() calls
        // (which can allocate) would leave the string unrooted on the C stack.
        const kw_path = jt.kw("path");
        const kw_name = jt.kw("name");
        const kw_event = jt.kw("event");
        const kw_framing = jt.kw("framing");
        const kw_reconnect = jt.kw("reconnect");
        const kw_connected = jt.kw("connected");
        const kw_disconnected = jt.kw("disconnected");
        const kw_handshake = jt.kw("handshake");
        const framing_kw = jt.kw(if (slot.framing == .netrepl) "netrepl" else "line");

        const spec = c.janet_table(8);
        const spec_val = c.janet_wrap_table(spec);
        c.janet_gcroot(spec_val);
        defer _ = c.janet_gcunroot(spec_val);
        const path_str = c.janet_string(slot.path[0..slot.path_len].ptr, @intCast(slot.path_len));
        c.janet_table_put(spec, kw_path, c.janet_wrap_string(path_str));
        c.janet_table_put(spec, kw_name, slot.name);
        c.janet_table_put(spec, kw_event, slot.event_id);
        c.janet_table_put(spec, kw_framing, framing_kw);
        c.janet_table_put(spec, kw_reconnect, c.janet_wrap_number(slot.reconnect_delay));
        if (c.janet_checktype(slot.connected_id, c.JANET_KEYWORD) != 0) {
            c.janet_table_put(spec, kw_connected, slot.connected_id);
        }
        if (c.janet_checktype(slot.disconnected_id, c.JANET_KEYWORD) != 0) {
            c.janet_table_put(spec, kw_disconnected, slot.disconnected_id);
        }
        if (slot.handshake != null) {
            c.janet_table_put(spec, kw_handshake, slot.handshake_janet);
        }

        scheduleReconnect(c.janet_wrap_table(spec), slot.reconnect_delay, sink);
    }

    /// Called from main loop when poll indicates an IPC fd is readable.
    pub fn onReadable(self: *IpcPool, fd: std.posix.fd_t, sink: jt.EventSink) void {
        for (&self.slots) |*slot| {
            if (slot.active and slot.fd == fd) {
                self.readSlot(slot, sink);
                return;
            }
        }
    }

    fn readSlot(self: *IpcPool, slot: *IpcSlot, sink: jt.EventSink) void {
        const available = BUF_SIZE - slot.recv_len;
        if (available == 0) {
            // Buffer full — for line mode, flush as oversized line; for netrepl, error
            if (slot.framing == .line) {
                enqueueMessage(slot, slot.recv_buf[0..slot.recv_len], .line, sink);
                slot.recv_len = 0;
            } else {
                log.warn("ipc: netrepl recv buffer overflow", .{});
                self.closeSlot(slot, true, sink);
            }
            return;
        }

        const n = std.posix.read(slot.fd, slot.recv_buf[slot.recv_len..]) catch {
            self.closeSlot(slot, true, sink);
            return;
        };
        if (n == 0) {
            // EOF — remote closed
            self.closeSlot(slot, true, sink);
            return;
        }

        slot.recv_len += n;

        switch (slot.framing) {
            .line => drainLines(slot, sink),
            .netrepl => self.drainNetrepl(slot, sink),
        }
    }

    /// Line framing: split on newlines, enqueue each complete line.
    fn drainLines(slot: *IpcSlot, sink: jt.EventSink) void {
        var start: usize = 0;
        for (0..slot.recv_len) |i| {
            if (slot.recv_buf[i] == '\n') {
                if (i > start) {
                    enqueueMessage(slot, slot.recv_buf[start..i], .line, sink);
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
    /// Uses a read cursor to avoid shifting the buffer per-byte/per-message.
    fn drainNetrepl(self: *IpcPool, slot: *IpcSlot, sink: jt.EventSink) void {
        var cursor: usize = 0;

        while (cursor < slot.recv_len) {
            if (slot.netrepl_msg_len == null) {
                // Reading header — need 4 bytes total (some may already be in hdr_buf)
                const need = 4 - slot.netrepl_hdr_len;
                const avail = slot.recv_len - cursor;
                const take = @min(need, avail);
                @memcpy(slot.netrepl_hdr_buf[slot.netrepl_hdr_len..][0..take], slot.recv_buf[cursor..][0..take]);
                slot.netrepl_hdr_len += take;
                cursor += take;

                if (slot.netrepl_hdr_len < 4) break; // need more data

                slot.netrepl_msg_len = std.mem.readInt(u32, &slot.netrepl_hdr_buf, .little);
                slot.netrepl_hdr_len = 0;

                if (slot.netrepl_msg_len.? > BUF_SIZE) {
                    log.warn("ipc: netrepl message too large ({d} bytes)", .{slot.netrepl_msg_len.?});
                    self.closeSlot(slot, true, sink);
                    return;
                }
            }

            const msg_len = slot.netrepl_msg_len.?;
            const avail = slot.recv_len - cursor;
            if (avail < msg_len) break; // need more data

            // Have complete message
            enqueueMessage(slot, slot.recv_buf[cursor..][0..msg_len], .netrepl, sink);
            cursor += msg_len;
            slot.netrepl_msg_len = null;
        }

        // Compact: shift unconsumed data to start of buffer
        if (cursor > 0) {
            const remaining = slot.recv_len - cursor;
            if (remaining > 0) {
                std.mem.copyForwards(u8, slot.recv_buf[0..remaining], slot.recv_buf[cursor..slot.recv_len]);
            }
            slot.recv_len = remaining;
        }
    }

    /// Enqueue a received IPC message as an event.
    fn enqueueMessage(slot: *IpcSlot, data: []const u8, framing: IpcFraming, sink: jt.EventSink) void {
        if (framing == .netrepl and data.len > 0) {
            // Classify by first byte
            const type_kw = switch (data[0]) {
                0xFF => jt.kw("output"),
                0xFE => jt.kw("return"),
                else => jt.kw("text"),
            };
            const payload = if (data[0] == 0xFF or data[0] == 0xFE) data[1..] else data;
            const payload_str = c.janet_string(payload.ptr, @intCast(payload.len));
            const str_val = c.janet_wrap_string(payload_str);
            c.janet_gcroot(str_val);
            defer _ = c.janet_gcunroot(str_val);
            const items = [3]Janet{ slot.event_id, type_kw, str_val };
            sink.enqueue(sink.ctx, jt.makeTuple(&items));
        } else {
            const data_str = c.janet_string(data.ptr, @intCast(data.len));
            const str_val = c.janet_wrap_string(data_str);
            c.janet_gcroot(str_val);
            defer _ = c.janet_gcunroot(str_val);
            const items = [2]Janet{ slot.event_id, str_val };
            sink.enqueue(sink.ctx, jt.makeTuple(&items));
        }
    }

    /// Fill a poll fd buffer with active IPC connection fds. Returns count added.
    pub fn fillPollFds(self: *IpcPool, buf: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active and slot.fd >= 0 and count < buf.len) {
                buf[count] = .{ .fd = slot.fd, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        return count;
    }

    fn freeSlot(slot: *IpcSlot) void {
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

    /// Close all active connections during cleanup. No reconnect.
    pub fn deinit(self: *IpcPool) void {
        for (&self.slots) |*slot| {
            if (slot.active) {
                if (slot.fd >= 0) {
                    std.posix.close(slot.fd);
                    slot.fd = -1;
                }
                freeSlot(slot);
            }
        }
    }
};
