const std = @import("std");
const jt = @import("jutil.zig");
const c = jt.c;
const Janet = jt.Janet;
const log = std.log.scoped(.spawn);

const posix_c = @cImport({
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

pub const MAX_SPAWNS = 16;
const BUF_SIZE = 4096;

pub const SpawnSlot = struct {
    active: bool = false,
    pid: posix_c.pid_t = 0,
    stdout_fd: std.posix.fd_t = -1,
    event_id: Janet = undefined, // keyword, GC-rooted when active
    done_id: Janet = undefined, // keyword or nil, GC-rooted if keyword
    line_buf: [BUF_SIZE]u8 = undefined,
    line_len: usize = 0,
};

pub const SpawnPool = struct {
    slots: [MAX_SPAWNS]SpawnSlot = [_]SpawnSlot{.{}} ** MAX_SPAWNS,

    /// Handle :spawn fx value. Spec: {:cmd ["cmd" "arg1"] :event :event-id :done :done-id}
    pub fn handleFx(self: *SpawnPool, val: Janet, _: jt.EventSink) void {
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

        // Create pipe for child stdout (CLOEXEC so children don't inherit read end)
        const pipe_fds = std.posix.pipe2(.{ .CLOEXEC = true }) catch {
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
        for (&self.slots) |*slot| {
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

    fn killByEvent(self: *SpawnPool, event_id: Janet) void {
        for (&self.slots) |*slot| {
            if (slot.active and c.janet_equals(slot.event_id, event_id) != 0) {
                self.kill(slot);
                return;
            }
        }
    }

    pub fn kill(self: *SpawnPool, slot: *SpawnSlot) void {
        if (slot.stdout_fd >= 0) {
            std.posix.close(slot.stdout_fd);
            slot.stdout_fd = -1;
        }
        _ = posix_c.kill(slot.pid, posix_c.SIGKILL);
        _ = posix_c.waitpid(slot.pid, null, 0);
        self.freeSlot(slot);
    }

    /// Called from main loop when poll indicates a spawn fd is readable.
    pub fn onReadable(self: *SpawnPool, fd: std.posix.fd_t, sink: jt.EventSink) void {
        for (&self.slots) |*slot| {
            if (slot.active and slot.stdout_fd == fd) {
                self.readSlot(slot, sink);
                return;
            }
        }
    }

    fn readSlot(self: *SpawnPool, slot: *SpawnSlot, sink: jt.EventSink) void {
        const available = BUF_SIZE - slot.line_len;
        if (available == 0) {
            // Buffer full with no newline — flush as a line
            enqueueLine(slot, slot.line_buf[0..slot.line_len], sink);
            slot.line_len = 0;
            return;
        }
        const n = std.posix.read(slot.stdout_fd, slot.line_buf[slot.line_len..]) catch {
            self.finish(slot, sink);
            return;
        };
        if (n == 0) {
            self.finish(slot, sink);
            return;
        }
        slot.line_len += n;
        drainLines(slot, sink);
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
        const line_str = c.janet_string(line.ptr, @intCast(line.len));
        const str_val = c.janet_wrap_string(line_str);
        c.janet_gcroot(str_val);
        defer _ = c.janet_gcunroot(str_val);
        const items = [2]Janet{ slot.event_id, str_val };
        sink.enqueue(sink.ctx, jt.makeTuple(&items));
    }

    fn finish(self: *SpawnPool, slot: *SpawnSlot, sink: jt.EventSink) void {
        const pid = slot.pid;
        if (slot.stdout_fd >= 0) {
            std.posix.close(slot.stdout_fd);
            slot.stdout_fd = -1;
        }

        // Flush remaining buffered data
        if (slot.line_len > 0) {
            enqueueLine(slot, slot.line_buf[0..slot.line_len], sink);
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
            sink.enqueue(sink.ctx, jt.makeTuple(&items));
        }

        self.freeSlot(slot);
        log.debug("spawn: pid={d} exited code={d}", .{ pid, exit_code });
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
};
