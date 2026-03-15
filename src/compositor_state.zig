const std = @import("std");

pub const TagInfo = struct {
    focused: bool = false,
    occupied: bool = false,
};

pub const WindowInfo = struct {
    wid: u32 = 0,
    app_id: [128]u8 = undefined,
    app_id_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    tag: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    focused: bool = false,
    float: bool = false,
    fullscreen: bool = false,
    visible: bool = false,
    row: u8 = 0,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    column: u8 = 0,
    column_total: u8 = 0,
    row_in_col: u8 = 0,
    row_in_col_total: u8 = 0,

    pub fn getAppId(self: *const WindowInfo) []const u8 {
        return self.app_id[0..self.app_id_len];
    }
    pub fn getTitle(self: *const WindowInfo) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn getLayout(self: *const WindowInfo) []const u8 {
        return self.layout[0..self.layout_len];
    }
};

pub const OutputInfo = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    tags: [11]TagInfo = [_]TagInfo{.{}} ** 11,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    active_row: u8 = 0,
    focused: bool = false,
    usable_x: i32 = 0,
    usable_y: i32 = 0,
    usable_w: i32 = 0,
    usable_h: i32 = 0,
    scroll_offset: f32 = 0,
    total_content_w: f32 = 0,
    column_widths: [32]f32 = [_]f32{0} ** 32,
    column_count: usize = 0,

    pub fn getLayout(self: *const OutputInfo) []const u8 {
        return self.layout[0..self.layout_len];
    }
};

pub const SignalEvent = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    pending: bool = false,

    pub fn getName(self: *const SignalEvent) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn consume(self: *SignalEvent) ?[]const u8 {
        if (!self.pending) return null;
        self.pending = false;
        return self.name[0..self.name_len];
    }
};

pub const CompositorState = struct {
    outputs: [8]OutputInfo = [_]OutputInfo{.{}} ** 8,
    output_count: usize = 0,
    tags: [11]TagInfo = [_]TagInfo{.{}} ** 11,
    layout: [32]u8 = undefined,
    layout_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    app_id: [128]u8 = undefined,
    app_id_len: usize = 0,
    windows: [64]WindowInfo = [_]WindowInfo{.{}} ** 64,
    window_count: usize = 0,
    windows_changed: bool = false,
    signal: SignalEvent = .{},
    connected: bool = false,

    pub fn getLayout(self: *const CompositorState) []const u8 {
        return self.layout[0..self.layout_len];
    }

    pub fn getTitle(self: *const CompositorState) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getAppId(self: *const CompositorState) []const u8 {
        return self.app_id[0..self.app_id_len];
    }

    pub fn getFocusedOutput(self: *const CompositorState) ?*const OutputInfo {
        for (self.outputs[0..self.output_count]) |*o| {
            if (o.focused) return o;
        }
        return null;
    }

    pub fn getOutput(self: *const CompositorState, x: i32, y: i32) ?*const OutputInfo {
        for (self.outputs[0..self.output_count]) |*o| {
            if (o.x == x and o.y == y) return o;
        }
        return null;
    }
};
