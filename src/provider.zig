const std = @import("std");
const cs = @import("compositor_state.zig");
const tidepool = @import("tidepool.zig");

const log = std.log.scoped(.provider);

pub const DataProvider = union(enum) {
    tidepool: *tidepool.TidepoolClient,
    none,

    pub fn update(self: DataProvider) bool {
        return switch (self) {
            .tidepool => |c| c.tryRead(),
            .none => false,
        };
    }

    pub fn getFd(self: DataProvider) ?std.posix.fd_t {
        return switch (self) {
            .tidepool => |c| c.socket_fd,
            .none => null,
        };
    }

    pub fn getState(self: DataProvider) ?cs.CompositorState {
        return switch (self) {
            .tidepool => |c| if (c.state.connected) c.toCompositorState() else null,
            .none => null,
        };
    }

    pub fn consumeSignal(self: DataProvider) void {
        switch (self) {
            .tidepool => |c| c.consumeSignal(),
            .none => {},
        }
    }

    pub fn deinit(self: DataProvider, allocator: std.mem.Allocator) void {
        switch (self) {
            .tidepool => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .none => {},
        }
    }
};

pub fn createTidepoolProvider(allocator: std.mem.Allocator) !DataProvider {
    const c = try allocator.create(tidepool.TidepoolClient);
    c.* = tidepool.TidepoolClient.init(allocator);
    c.start() catch |err| {
        log.warn("tidepool start failed: {}, will retry", .{err});
    };
    return .{ .tidepool = c };
}
