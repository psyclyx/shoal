const std = @import("std");
const jt = @import("jutil.zig");
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
    // Request queue: main → worker
    req_queue: [QUEUE_SIZE]Request = undefined,
    req_head: usize = 0,
    req_tail: usize = 0,
    req_mutex: std.Thread.Mutex = .{},
    req_cond: std.Thread.Condition = .{},

    // Result queue: worker → main
    res_queue: [QUEUE_SIZE]Result = undefined,
    res_head: usize = 0,
    res_tail: usize = 0,
    res_mutex: std.Thread.Mutex = .{},

    // Notification pipe (worker writes 1 byte when result ready)
    pipe_read: std.posix.fd_t = -1,
    pipe_write: std.posix.fd_t = -1,

    // Worker thread
    thread: ?std.Thread = null,
    shutdown: bool = false,

    pub fn init() AsyncReader {
        const fds = std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch
            return AsyncReader{};
        return AsyncReader{
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
        self.req_mutex.lock();
        self.shutdown = true;
        self.req_cond.signal();
        self.req_mutex.unlock();

        if (self.thread) |t| t.join();

        // Free any pending results
        self.res_mutex.lock();
        while (self.res_head != self.res_tail) {
            const r = &self.res_queue[self.res_head % QUEUE_SIZE];
            if (r.data) |d| alloc.free(d);
            _ = c.janet_gcunroot(r.event_id);
            self.res_head +%= 1;
        }
        self.res_mutex.unlock();

        if (self.pipe_read >= 0) std.posix.close(self.pipe_read);
        if (self.pipe_write >= 0) std.posix.close(self.pipe_write);
    }

    /// Queue an async file read. Called from the main thread.
    pub fn request(self: *AsyncReader, path: []const u8, event_id: Janet) void {
        if (path.len > MAX_PATH) {
            log.warn("async-slurp: path too long", .{});
            return;
        }

        self.req_mutex.lock();
        defer self.req_mutex.unlock();

        const idx = self.req_tail % QUEUE_SIZE;
        if (self.req_tail -% self.req_head >= QUEUE_SIZE) {
            log.warn("async-slurp: request queue full", .{});
            return;
        }

        c.janet_gcroot(event_id);
        var req = &self.req_queue[idx];
        @memcpy(req.path[0..path.len], path);
        req.path_len = path.len;
        req.event_id = event_id;
        self.req_tail +%= 1;

        self.req_cond.signal();
    }

    /// Called from main loop when pipe_read is readable.
    /// Drains results and dispatches events.
    pub fn onReadable(self: *AsyncReader, sink: jt.EventSink) void {
        // Drain notification pipe
        var buf: [64]u8 = undefined;
        _ = std.posix.read(self.pipe_read, &buf) catch {};

        // Drain result queue
        self.res_mutex.lock();
        defer self.res_mutex.unlock();

        while (self.res_head != self.res_tail) {
            const r = self.res_queue[self.res_head % QUEUE_SIZE];
            self.res_head +%= 1;

            if (r.data) |data| {
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
                self.req_mutex.lock();
                defer self.req_mutex.unlock();

                while (self.req_head == self.req_tail and !self.shutdown) {
                    self.req_cond.wait(&self.req_mutex);
                }

                if (self.shutdown and self.req_head == self.req_tail) return;

                req = self.req_queue[self.req_head % QUEUE_SIZE];
                self.req_head +%= 1;
            }

            // Read the file (this is the blocking part — runs off main thread)
            const path = req.path[0..req.path_len];
            const data = readFile(path);

            // Enqueue result
            {
                self.res_mutex.lock();
                defer self.res_mutex.unlock();

                if (self.res_tail -% self.res_head < QUEUE_SIZE) {
                    self.res_queue[self.res_tail % QUEUE_SIZE] = .{
                        .event_id = req.event_id,
                        .data = data,
                    };
                    self.res_tail +%= 1;
                } else {
                    // Queue full — drop result
                    if (data) |d| alloc.free(d);
                    _ = c.janet_gcunroot(req.event_id);
                }
            }

            // Notify main loop
            _ = std.posix.write(self.pipe_write, &[_]u8{1}) catch {};
        }
    }

    fn readFile(path: []const u8) ?[]const u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        const data = file.readToEndAlloc(alloc, MAX_RESULT) catch return null;
        return data;
    }
};
