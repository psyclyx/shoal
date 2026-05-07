const std = @import("std");
const jt = @import("jutil.zig");
const trace = @import("trace.zig");
const c = jt.c;
const Janet = jt.Janet;
const log = std.log.scoped(.spawn);

pub const MAX_SPAWNS = 16;
const BUF_SIZE = 4096;
const CMD_LABEL_SIZE = 512;

pub const SpawnSlot = struct {
    active: bool = false,
    child: std.process.Child = undefined,
    stdout_fd: std.posix.fd_t = -1,
    event_id: Janet = undefined, // keyword, GC-rooted when active
    done_id: Janet = undefined, // keyword or nil, GC-rooted if keyword
    cmd_label: [CMD_LABEL_SIZE]u8 = undefined,
    cmd_label_len: usize = 0,
    line_buf: [BUF_SIZE]u8 = undefined,
    line_len: usize = 0,

    fn cmdLabel(self: *const SpawnSlot) []const u8 {
        return self.cmd_label[0..self.cmd_label_len];
    }
};

pub const SpawnPool = struct {
    io: std.Io = undefined,
    slots: [MAX_SPAWNS]SpawnSlot = [_]SpawnSlot{.{}} ** MAX_SPAWNS,

    /// Handle :spawn fx value. Spec: {:cmd ["cmd" "arg1"] :event :event-id :done :done-id}
    pub fn handleFx(self: *SpawnPool, val: Janet, _: jt.EventSink) void {
        const start_ns = trace.nowNs();
        if (c.janet_checktype(val, c.JANET_TABLE) == 0 and
            c.janet_checktype(val, c.JANET_STRUCT) == 0)
        {
            log.warn("spawn fx: expected table", .{});
            return;
        }

        const cmd_val = jt.janetGet(val, jt.kw("cmd"));
        const event_val = jt.janetGet(val, jt.kw("event"));
        const done_val = jt.janetGet(val, jt.kw("done"));

        const cmd_view = jt.janetIndexedView(cmd_val);
        if (cmd_view.items == null or cmd_view.len == 0) {
            log.warn("spawn fx: empty or missing :cmd", .{});
            return;
        }

        if (c.janet_checktype(event_val, c.JANET_KEYWORD) == 0) {
            log.warn("spawn fx: missing :event keyword", .{});
            return;
        }

        // Kill existing spawn with same event id (replacement semantics)
        self.killByEvent(event_val);

        // Build argv (max 32 args)
        const argc: usize = @intCast(cmd_view.len);
        if (argc > 32) {
            log.warn("spawn fx: too many args (max 32)", .{});
            return;
        }
        var argv: [32][]const u8 = undefined;
        for (0..argc) |i| {
            const s = cmd_view.items.?[i];
            if (c.janet_checktype(s, c.JANET_STRING) != 0) {
                const str = c.janet_unwrap_string(s);
                argv[i] = str[0..@intCast(c.janet_string_length(str))];
            } else if (c.janet_checktype(s, c.JANET_KEYWORD) != 0) {
                argv[i] = std.mem.span(c.janet_unwrap_keyword(s));
            } else if (c.janet_checktype(s, c.JANET_SYMBOL) != 0) {
                argv[i] = std.mem.span(c.janet_unwrap_symbol(s));
            } else {
                log.warn("spawn fx: cmd element is not a string/keyword/symbol", .{});
                return;
            }
        }

        var child = std.process.spawn(self.io, .{
            .argv = argv[0..argc],
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            log.warn("spawn fx: spawn failed: {}", .{err});
            trace.log("spawn.start-error event={s} err={} dur_ms={d:.3}", .{
                keywordName(event_val),
                err,
                trace.elapsedMs(start_ns),
            });
            return;
        };

        // Find free slot
        for (&self.slots) |*slot| {
            if (!slot.active) {
                const stdout = child.stdout.?;
                slot.* = .{
                    .active = true,
                    .child = child,
                    .stdout_fd = stdout.handle,
                    .event_id = event_val,
                    .done_id = done_val,
                    .cmd_label_len = 0,
                    .line_len = 0,
                };
                slot.cmd_label_len = formatCmdLabel(&slot.cmd_label, argv[0..argc]);
                c.janet_gcroot(event_val);
                if (c.janet_checktype(done_val, c.JANET_KEYWORD) != 0) {
                    c.janet_gcroot(done_val);
                }
                log.debug("spawn: pid={d} event=:{s} cmd=\"{s}\" started", .{
                    child.id.?,
                    keywordName(event_val),
                    slot.cmdLabel(),
                });
                trace.log("spawn.start pid={d} event={s} cmd=\"{s}\" active={d} dur_ms={d:.3}", .{
                    child.id.?,
                    keywordName(event_val),
                    slot.cmdLabel(),
                    self.activeCount(),
                    trace.elapsedMs(start_ns),
                });
                return;
            }
        }

        log.warn("spawn fx: no free slots", .{});
        trace.log("spawn.start-drop event={s} reason=no-free active={d} dur_ms={d:.3}", .{
            keywordName(event_val),
            self.activeCount(),
            trace.elapsedMs(start_ns),
        });
        child.kill(self.io);
    }

    fn killByEvent(self: *SpawnPool, event_id: Janet) void {
        for (&self.slots) |*slot| {
            if (slot.active and c.janet_equals(slot.event_id, event_id) != 0) {
                self.kill(slot);
                return;
            }
        }
    }

    pub fn kill(self: *SpawnPool, slot: *SpawnSlot) void {
        slot.child.kill(self.io);
        self.freeSlot(slot);
    }

    /// Called from main loop when poll indicates a spawn fd is readable.
    pub fn onReadable(self: *SpawnPool, fd: std.posix.fd_t, sink: jt.EventSink) void {
        const start_ns = trace.nowNs();
        for (&self.slots) |*slot| {
            if (slot.active and slot.stdout_fd == fd) {
                self.readSlot(slot, sink);
                trace.log("spawn.readable fd={d} event={s} dur_ms={d:.3}", .{
                    fd,
                    keywordName(slot.event_id),
                    trace.elapsedMs(start_ns),
                });
                return;
            }
        }
        trace.log("spawn.readable-miss fd={d} dur_ms={d:.3}", .{ fd, trace.elapsedMs(start_ns) });
    }

    fn readSlot(self: *SpawnPool, slot: *SpawnSlot, sink: jt.EventSink) void {
        const start_ns = trace.nowNs();
        const available = BUF_SIZE - slot.line_len;
        if (available == 0) {
            // Buffer full with no newline — flush as a line
            enqueueLine(slot, slot.line_buf[0..slot.line_len], sink);
            slot.line_len = 0;
            return;
        }
        const stdout = slot.child.stdout orelse return self.finish(slot, sink);
        const n = stdout.readStreaming(self.io, &.{slot.line_buf[slot.line_len..]}) catch |err| switch (err) {
            error.EndOfStream => {
                self.finish(slot, sink);
                return;
            },
            else => {
                self.finish(slot, sink);
                return;
            },
        };
        if (n == 0) {
            self.finish(slot, sink);
            return;
        }
        slot.line_len += n;
        drainLines(slot, sink);
        trace.log("spawn.read event={s} bytes={d} buffered={d} dur_ms={d:.3}", .{
            keywordName(slot.event_id),
            n,
            slot.line_len,
            trace.elapsedMs(start_ns),
        });
    }

    fn drainLines(slot: *SpawnSlot, sink: jt.EventSink) void {
        var start: usize = 0;
        for (0..slot.line_len) |i| {
            if (slot.line_buf[i] == '\n') {
                if (i > start) {
                    enqueueLine(slot, slot.line_buf[start..i], sink);
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

    fn enqueueLine(slot: *SpawnSlot, line: []const u8, sink: jt.EventSink) void {
        const start_ns = trace.nowNs();
        const line_str = c.janet_string(line.ptr, @intCast(line.len));
        const str_val = c.janet_wrap_string(line_str);
        c.janet_gcroot(str_val);
        defer _ = c.janet_gcunroot(str_val);
        const items = [2]Janet{ slot.event_id, str_val };
        sink.enqueue(sink.ctx, jt.makeTuple(&items));
        trace.log("spawn.enqueue-line event={s} bytes={d} dur_ms={d:.3}", .{
            keywordName(slot.event_id),
            line.len,
            trace.elapsedMs(start_ns),
        });
    }

    fn finish(self: *SpawnPool, slot: *SpawnSlot, sink: jt.EventSink) void {
        const start_ns = trace.nowNs();
        const pid = slot.child.id;

        // Flush remaining buffered data
        if (slot.line_len > 0) {
            enqueueLine(slot, slot.line_buf[0..slot.line_len], sink);
            slot.line_len = 0;
        }

        // Reap child
        const term = slot.child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 };
        const exit_code = exitCode(term);

        // Enqueue done event if configured
        if (c.janet_checktype(slot.done_id, c.JANET_KEYWORD) != 0) {
            const items = [2]Janet{ slot.done_id, c.janet_wrap_number(@floatFromInt(exit_code)) };
            sink.enqueue(sink.ctx, jt.makeTuple(&items));
        }

        logTerm(pid, slot.event_id, slot.cmdLabel(), term, exit_code);
        trace.log("spawn.finish pid={d} event={s} code={d} active_before={d} dur_ms={d:.3}", .{
            pid orelse 0,
            keywordName(slot.event_id),
            exit_code,
            self.activeCount(),
            trace.elapsedMs(start_ns),
        });
        self.freeSlot(slot);
    }

    fn freeSlot(_: *SpawnPool, slot: *SpawnSlot) void {
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
    pub fn fillPollFds(self: *SpawnPool, buf: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active and slot.stdout_fd >= 0 and count < buf.len) {
                buf[count] = .{ .fd = slot.stdout_fd, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        return count;
    }

    fn formatCmdLabel(dst: *[CMD_LABEL_SIZE]u8, argv: []const []const u8) usize {
        var len: usize = 0;
        for (argv, 0..) |arg, i| {
            if (i > 0) appendCmdLabel(dst, &len, " ");
            appendCmdLabel(dst, &len, arg);
        }
        return len;
    }

    fn appendCmdLabel(dst: *[CMD_LABEL_SIZE]u8, len: *usize, src: []const u8) void {
        if (len.* >= dst.len) return;

        const room = dst.len - len.*;
        if (src.len <= room) {
            @memcpy(dst[len.*..][0..src.len], src);
            len.* += src.len;
            return;
        }

        if (room > 3) {
            const keep = room - 3;
            @memcpy(dst[len.*..][0..keep], src[0..keep]);
            @memcpy(dst[len.* + keep ..][0..3], "...");
            len.* = dst.len;
        }
    }

    fn activeCount(self: *const SpawnPool) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    fn keywordName(value: Janet) []const u8 {
        if (c.janet_checktype(value, c.JANET_KEYWORD) == 0) return "nil";
        return std.mem.span(c.janet_unwrap_keyword(value));
    }

    fn exitCode(term: std.process.Child.Term) i32 {
        return switch (term) {
            .exited => |code| @intCast(code),
            else => -1,
        };
    }

    fn logTerm(pid: ?std.process.Child.Id, event_id: Janet, cmd: []const u8, term: std.process.Child.Term, code: i32) void {
        const event_name = keywordName(event_id);
        if (pid) |p| {
            switch (term) {
                .exited => log.debug("spawn: pid={d} event=:{s} cmd=\"{s}\" exited code={d}", .{ p, event_name, cmd, code }),
                .signal => |sig| log.debug("spawn: pid={d} event=:{s} cmd=\"{s}\" signaled sig={}", .{ p, event_name, cmd, sig }),
                .stopped => |sig| log.debug("spawn: pid={d} event=:{s} cmd=\"{s}\" stopped sig={}", .{ p, event_name, cmd, sig }),
                .unknown => |status| log.debug("spawn: pid={d} event=:{s} cmd=\"{s}\" exited status={d}", .{ p, event_name, cmd, status }),
            }
        } else {
            log.debug("spawn: pid=? event=:{s} cmd=\"{s}\" exited code={d}", .{ event_name, cmd, code });
        }
    }
};
