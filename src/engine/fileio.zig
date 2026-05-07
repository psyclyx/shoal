const std = @import("std");
const jt = @import("jutil.zig");
const trace = @import("trace.zig");
const c = jt.c;
const Janet = jt.Janet;
const log = std.log.scoped(.fileio);

const alloc = std.heap.c_allocator;

const MAX_PATH = 256;
const MAX_RESULT = 64 * 1024; // 64KB per file read

const Request = struct {
    path: [MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    event_id: Janet = undefined, // GC-rooted keyword
};

const Result = struct {
    event_id: Janet, // GC-rooted keyword
    data: ?[]const u8, // null on error, alloc'd slice on success
};

const QUEUE_SIZE = 64;

pub const AsyncReader = struct {
    io: std.Io,

    // Request queue: main → worker
    req_queue: [QUEUE_SIZE]Request = undefined,
    req_head: usize = 0,
    req_tail: usize = 0,
    req_mutex: std.Io.Mutex = .init,
    req_cond: std.Io.Condition = .init,

    // Result queue: worker → main
    res_queue: [QUEUE_SIZE]Result = undefined,
    res_head: usize = 0,
    res_tail: usize = 0,
    res_mutex: std.Io.Mutex = .init,

    // Notification pipe (worker writes 1 byte when result ready)
    pipe_read: std.posix.fd_t = -1,
    pipe_write: std.posix.fd_t = -1,

    // Worker thread
    thread: ?std.Thread = null,
    shutdown: bool = false,

    pub fn init(io: std.Io) AsyncReader {
        const fds = makeNotifyPipe() catch
            return AsyncReader{ .io = io };
        return AsyncReader{
            .io = io,
            .pipe_read = fds[0],
            .pipe_write = fds[1],
        };
    }

    /// Spawn the worker thread. Must be called after the struct is at its
    /// final memory location (not a stack temporary that will be moved).
    pub fn startWorker(self: *AsyncReader) void {
        if (self.pipe_read < 0) return; // init failed
        self.thread = std.Thread.spawn(.{}, workerLoop, .{self}) catch {
            log.err("async-slurp: failed to spawn worker thread", .{});
            return;
        };
    }

    pub fn deinit(self: *AsyncReader) void {
        // Signal shutdown
        self.req_mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.req_cond.signal(self.io);
        self.req_mutex.unlock(self.io);

        if (self.thread) |t| t.join();

        // Free any pending results
        self.res_mutex.lockUncancelable(self.io);
        while (self.res_head != self.res_tail) {
            const r = &self.res_queue[self.res_head % QUEUE_SIZE];
            if (r.data) |d| alloc.free(d);
            _ = c.janet_gcunroot(r.event_id);
            self.res_head +%= 1;
        }
        self.res_mutex.unlock(self.io);

        if (self.pipe_read >= 0) self.pipeFile(self.pipe_read).close(self.io);
        if (self.pipe_write >= 0) self.pipeFile(self.pipe_write).close(self.io);
    }

    /// Queue an async file read. Called from the main thread.
    pub fn request(self: *AsyncReader, path: []const u8, event_id: Janet) void {
        const start_ns = trace.nowNs();
        if (path.len > MAX_PATH) {
            log.warn("async-slurp: path too long", .{});
            trace.log("fileio.request-drop reason=path-too-long path_len={d}", .{path.len});
            return;
        }

        self.req_mutex.lockUncancelable(self.io);
        defer self.req_mutex.unlock(self.io);

        const idx = self.req_tail % QUEUE_SIZE;
        if (self.req_tail -% self.req_head >= QUEUE_SIZE) {
            log.warn("async-slurp: request queue full", .{});
            trace.log("fileio.request-drop reason=req-full event={s} req_depth={d} capacity={d} dur_ms={d:.3}", .{
                keywordName(event_id),
                self.req_tail -% self.req_head,
                QUEUE_SIZE,
                trace.elapsedMs(start_ns),
            });
            return;
        }

        c.janet_gcroot(event_id);
        var req = &self.req_queue[idx];
        @memcpy(req.path[0..path.len], path);
        req.path_len = path.len;
        req.event_id = event_id;
        self.req_tail +%= 1;

        self.req_cond.signal(self.io);
        trace.log("fileio.request event={s} path={s} req_depth={d} capacity={d} dur_ms={d:.3}", .{
            keywordName(event_id),
            path,
            self.req_tail -% self.req_head,
            QUEUE_SIZE,
            trace.elapsedMs(start_ns),
        });
    }

    /// Called from main loop when pipe_read is readable.
    /// Drains results and dispatches events.
    pub fn onReadable(self: *AsyncReader, sink: jt.EventSink) void {
        const start_ns = trace.nowNs();
        // Drain notification pipe
        var buf: [64]u8 = undefined;
        const notify_bytes = self.pipeFile(self.pipe_read).readStreaming(self.io, &.{&buf}) catch 0;

        // Drain result queue
        self.res_mutex.lockUncancelable(self.io);
        defer self.res_mutex.unlock(self.io);

        var drained: usize = 0;
        var bytes: usize = 0;
        while (self.res_head != self.res_tail) {
            const r = self.res_queue[self.res_head % QUEUE_SIZE];
            self.res_head +%= 1;
            drained += 1;

            if (r.data) |data| {
                bytes += data.len;
                const str = c.janet_string(data.ptr, @intCast(data.len));
                const str_val = c.janet_wrap_string(str);
                c.janet_gcroot(str_val);
                defer _ = c.janet_gcunroot(str_val);
                const items = [2]Janet{ r.event_id, str_val };
                sink.enqueue(sink.ctx, jt.makeTuple(&items));
                alloc.free(data);
            }
            _ = c.janet_gcunroot(r.event_id);
        }
        trace.log("fileio.readable notify_bytes={d} drained={d} data_bytes={d} res_depth={d} dur_ms={d:.3}", .{
            notify_bytes,
            drained,
            bytes,
            self.res_tail -% self.res_head,
            trace.elapsedMs(start_ns),
        });
    }

    /// Get the poll fd for the main loop.
    pub fn getPollFd(self: *AsyncReader) std.posix.fd_t {
        return self.pipe_read;
    }

    // -- Worker thread --

    fn workerLoop(self: *AsyncReader) void {
        while (true) {
            var req: Request = undefined;

            {
                self.req_mutex.lockUncancelable(self.io);
                defer self.req_mutex.unlock(self.io);

                while (self.req_head == self.req_tail and !self.shutdown) {
                    self.req_cond.waitUncancelable(self.io, &self.req_mutex);
                }

                if (self.shutdown and self.req_head == self.req_tail) return;

                req = self.req_queue[self.req_head % QUEUE_SIZE];
                self.req_head +%= 1;
            }

            // Read the file (this is the blocking part — runs off main thread)
            const path = req.path[0..req.path_len];
            const read_start_ns = trace.nowNs();
            const data = self.readFile(path);
            const read_ms = trace.elapsedMs(read_start_ns);

            // Enqueue result
            {
                self.res_mutex.lockUncancelable(self.io);
                defer self.res_mutex.unlock(self.io);

                if (self.res_tail -% self.res_head < QUEUE_SIZE) {
                    self.res_queue[self.res_tail % QUEUE_SIZE] = .{
                        .event_id = req.event_id,
                        .data = data,
                    };
                    self.res_tail +%= 1;
                    trace.log("fileio.worker-result event={s} path={s} bytes={d} res_depth={d} read_ms={d:.3}", .{
                        keywordName(req.event_id),
                        path,
                        if (data) |d| d.len else 0,
                        self.res_tail -% self.res_head,
                        read_ms,
                    });
                } else {
                    // Queue full — drop result
                    if (data) |d| alloc.free(d);
                    _ = c.janet_gcunroot(req.event_id);
                    trace.log("fileio.worker-drop event={s} path={s} reason=res-full depth={d} read_ms={d:.3}", .{
                        keywordName(req.event_id),
                        path,
                        self.res_tail -% self.res_head,
                        read_ms,
                    });
                }
            }

            // Notify main loop
            self.pipeFile(self.pipe_write).writeStreamingAll(self.io, &[_]u8{1}) catch |err| {
                trace.log("fileio.notify-error event={s} err={}", .{ keywordName(req.event_id), err });
            };
        }
    }

    fn readFile(self: *AsyncReader, path: []const u8) ?[]const u8 {
        var file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);

        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(alloc);

        var buf: [4096]u8 = undefined;
        read_loop: while (data.items.len < MAX_RESULT) {
            const chunk = buf[0..@min(buf.len, MAX_RESULT - data.items.len)];
            const n = file.readStreaming(self.io, &.{chunk}) catch |err| switch (err) {
                error.EndOfStream => break :read_loop,
                else => return null,
            };
            if (n == 0) break;
            data.appendSlice(alloc, chunk[0..n]) catch return null;
        }

        return data.toOwnedSlice(alloc) catch null;
    }

    fn pipeFile(_: *AsyncReader, fd: std.posix.fd_t) std.Io.File {
        return .{ .handle = fd, .flags = .{ .nonblocking = true } };
    }

    fn makeNotifyPipe() ![2]std.posix.fd_t {
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }))) {
            .SUCCESS => return fds,
            else => return error.PipeFailed,
        }
    }
};

fn keywordName(value: Janet) []const u8 {
    if (c.janet_checktype(value, c.JANET_KEYWORD) == 0) return "nil";
    return std.mem.span(c.janet_unwrap_keyword(value));
}
