// Streaming stdin reader. Lines are dispatched as :stdin/line events
// and EOF as :stdin/eof. The fd polls in the main loop; once started
// the reader stays attached until EOF.

const std = @import("std");
const jt = @import("jutil.zig");
const trace = @import("trace.zig");
const c = jt.c;
const Janet = jt.Janet;
const log = std.log.scoped(.stdin);

const alloc = std.heap.c_allocator;
const MAX_LINE = 64 * 1024;

pub const StdinReader = struct {
    io: std.Io,
    fd: std.posix.fd_t = -1,
    started: bool = false,
    eof: bool = false,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(io: std.Io) StdinReader {
        return .{ .io = io };
    }

    pub fn deinit(self: *StdinReader) void {
        self.buffer.deinit(alloc);
    }

    /// Begin polling stdin. Idempotent.
    pub fn start(self: *StdinReader) void {
        if (self.started or self.eof) return;
        const fd = std.posix.STDIN_FILENO;
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0) {
            log.warn("stdin: fcntl(GETFL) failed", .{});
            return;
        }
        const new_flags = flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }));
        if (std.c.fcntl(fd, std.c.F.SETFL, new_flags) < 0) {
            log.warn("stdin: fcntl(SETFL) failed", .{});
            return;
        }
        self.fd = fd;
        self.started = true;
    }

    pub fn getPollFd(self: *StdinReader) ?std.posix.fd_t {
        if (!self.started or self.eof) return null;
        return self.fd;
    }

    /// Drain available stdin bytes, dispatch :stdin/line for each complete
    /// line and :stdin/eof when EOF is reached.
    pub fn onReadable(self: *StdinReader, sink: jt.EventSink) void {
        if (!self.started or self.eof) return;
        const start_ns = trace.nowNs();

        var lines_emitted: usize = 0;
        var bytes_read: usize = 0;

        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = std.posix.read(self.fd, &chunk) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("stdin read failed: {}", .{err});
                    self.eof = true;
                    break;
                },
            };
            if (n == 0) {
                self.eof = true;
                break;
            }
            bytes_read += n;
            self.buffer.appendSlice(alloc, chunk[0..n]) catch {
                log.warn("stdin: buffer alloc failed", .{});
                self.eof = true;
                break;
            };

            // Drain complete lines from buffer
            while (true) {
                const idx = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse break;
                const line = self.buffer.items[0..idx];
                if (line.len < MAX_LINE) emitLine(sink, line);
                lines_emitted += 1;
                // Shift remainder forward
                const rest = self.buffer.items[idx + 1 ..];
                std.mem.copyForwards(u8, self.buffer.items[0..rest.len], rest);
                self.buffer.shrinkRetainingCapacity(rest.len);
            }
        }

        if (self.eof) {
            // Flush any trailing partial line without a newline
            if (self.buffer.items.len > 0 and self.buffer.items.len < MAX_LINE) {
                emitLine(sink, self.buffer.items);
                lines_emitted += 1;
            }
            self.buffer.clearRetainingCapacity();
            const eof_ev = jt.makeEvent("stdin/eof");
            sink.enqueue(sink.ctx, eof_ev);
        }

        trace.log("stdin.readable bytes={d} lines={d} eof={} dur_ms={d:.3}", .{
            bytes_read,
            lines_emitted,
            self.eof,
            trace.elapsedMs(start_ns),
        });
    }
};

fn emitLine(sink: jt.EventSink, line: []const u8) void {
    const s = c.janet_string(@ptrCast(line.ptr), @intCast(line.len));
    const items = [2]Janet{ jt.kw("stdin/line"), c.janet_wrap_string(s) };
    sink.enqueue(sink.ctx, jt.makeTuple(&items));
}
