const std = @import("std");
const clay = @import("clay");
const Renderer = @import("renderer.zig").Renderer;
const TextRenderer = @import("text.zig").TextRenderer;
const hiccup = @import("hiccup.zig");
const trace = @import("trace.zig");

const log = std.log.scoped(.layout);

pub const Layout = struct {
    clay_memory: []u8,
    text_renderer: *TextRenderer,
    renderer: *Renderer,
    width: f32,
    height: f32,
    content_height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, text_renderer: *TextRenderer, renderer: *Renderer) !Layout {
        const min_memory = clay.minMemorySize();
        const clay_memory = try allocator.alloc(u8, min_memory);

        const arena = clay.Arena.init(clay_memory);

        _ = clay.initialize(arena, .{ .w = 0, .h = 0 }, .{
            .error_handler_function = handleClayError,
        });

        clay.setMeasureTextFunction(*TextRenderer, text_renderer, measureText);

        return .{
            .clay_memory = clay_memory,
            .text_renderer = text_renderer,
            .renderer = renderer,
            .width = 0,
            .height = 0,
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.clay_memory);
    }

    pub fn setDimensions(self: *Layout, width: f32, height: f32) void {
        self.width = width;
        self.height = height;
        clay.setLayoutDimensions(.{ .w = width, .h = height });
    }

    pub fn setPointerState(position: [2]f32, pressed: bool) void {
        clay.setPointerState(.{ .x = position[0], .y = position[1] }, pressed);
    }

    pub fn updateScroll(delta: [2]f32, dt: f32) void {
        clay.updateScrollContainers(true, .{ .x = delta[0], .y = delta[1] }, dt);
    }

    /// Call between beginLayout/endLayout to declare UI.
    /// Returns the render command slice from Clay.
    pub fn beginLayout(_: *Layout) void {
        const start_ns = trace.nowNs();
        clay.beginLayout();
        trace.log("layout.begin dur_ms={d:.3}", .{trace.elapsedMs(start_ns)});
    }

    /// End layout, process render commands through the GL renderer.
    pub fn endLayout(self: *Layout) void {
        const clay_start_ns = trace.nowNs();
        const commands = clay.endLayout();
        trace.log("layout.clay-end commands={d} dur_ms={d:.3}", .{
            commands.len,
            trace.elapsedMs(clay_start_ns),
        });
        const process_start_ns = trace.nowNs();
        self.processRenderCommands(commands);
        trace.log("layout.process-commands commands={d} content_h={d:.1} dur_ms={d:.3}", .{
            commands.len,
            self.content_height,
            trace.elapsedMs(process_start_ns),
        });
    }

    fn processRenderCommands(self: *Layout, commands: []clay.RenderCommand) void {
        var max_bottom: f32 = 0;
        var rectangles: usize = 0;
        var texts: usize = 0;
        var borders: usize = 0;
        var scissors: usize = 0;
        var custom: usize = 0;
        for (commands) |cmd| {
            const bb = cmd.bounding_box;
            const bottom = bb.y + bb.height;
            if (bottom > max_bottom) max_bottom = bottom;
            switch (cmd.command_type) {
                .rectangle => {
                    rectangles += 1;
                    const rect = cmd.render_data.rectangle;
                    self.renderer.drawRect(
                        bb.x,
                        bb.y,
                        bb.width,
                        bb.height,
                        clayToGlColor(rect.background_color),
                        .{
                            rect.corner_radius.top_left,
                            rect.corner_radius.top_right,
                            rect.corner_radius.bottom_left,
                            rect.corner_radius.bottom_right,
                        },
                    );
                },
                .text => {
                    texts += 1;
                    const td = cmd.render_data.text;
                    const text_slice = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    var text_x = bb.x;
                    var text_y = bb.y;
                    if (cmd.user_data) |ptr| {
                        const tweak: *const hiccup.TextTweak = @ptrCast(@alignCast(ptr));
                        text_x += tweak.dx;
                        text_y += tweak.dy + tweak.baseline_shift_px;
                        text_y += tweak.baseline_shift_line *
                            self.text_renderer.lineHeightForFont(td.font_id, td.font_size);
                    }
                    self.renderer.drawText(
                        self.text_renderer,
                        text_x,
                        text_y,
                        text_slice,
                        td.font_id,
                        td.font_size,
                        clayToGlColor(td.text_color),
                    );
                },
                .border => {
                    borders += 1;
                    const bd = cmd.render_data.border;
                    const color = clayToGlColor(bd.color);
                    const radii = [4]f32{
                        bd.corner_radius.top_left,
                        bd.corner_radius.top_right,
                        bd.corner_radius.bottom_left,
                        bd.corner_radius.bottom_right,
                    };
                    self.renderer.drawBorder(
                        bb.x,
                        bb.y,
                        bb.width,
                        bb.height,
                        color,
                        .{
                            @floatFromInt(bd.width.top),
                            @floatFromInt(bd.width.right),
                            @floatFromInt(bd.width.bottom),
                            @floatFromInt(bd.width.left),
                        },
                        radii,
                    );
                },
                .scissor_start => {
                    scissors += 1;
                    self.renderer.flush();
                    self.renderer.setScissor(bb.x, bb.y, bb.width, bb.height);
                },
                .scissor_end => {
                    scissors += 1;
                    self.renderer.flush();
                    self.renderer.clearScissor();
                },
                .image => {
                    // TODO: image rendering
                },
                .custom => {
                    custom += 1;
                    const cd = cmd.render_data.custom;
                    if (cd.custom_data) |ptr| {
                        const header: *const hiccup.CustomHeader = @ptrCast(@alignCast(ptr));
                        switch (header.kind) {
                            .curve => {
                                const curve: *const hiccup.CurveData = @ptrCast(@alignCast(ptr));
                                self.renderer.setScissor(bb.x, bb.y, bb.width, bb.height);
                                self.renderer.drawCurve(
                                    bb.x,
                                    bb.y,
                                    bb.width,
                                    bb.height,
                                    curve.values[0..curve.value_count],
                                    curve.value_count,
                                    curve.values2[0..curve.value_count2],
                                    curve.value_count2,
                                    curve.color,
                                    curve.color2,
                                    curve.fill,
                                    curve.thickness,
                                    curve.smooth,
                                    curve.mirror,
                                    curve.scroll,
                                    curve.grid_lines,
                                    curve.grid_count,
                                    curve.is_line,
                                );
                                self.renderer.clearScissor();
                            },
                            .skew_bg => {
                                const sk: *const hiccup.SkewBgData = @ptrCast(@alignCast(ptr));
                                self.renderer.drawSlantRect(
                                    bb.x,
                                    bb.y,
                                    bb.width,
                                    bb.height,
                                    sk.color,
                                    sk.skew,
                                );
                            },
                            .triangle => {
                                const tri: *const hiccup.TriData = @ptrCast(@alignCast(ptr));
                                self.renderer.drawTriangle(
                                    bb.x,
                                    bb.y,
                                    bb.width,
                                    bb.height,
                                    tri.color,
                                    tri.dir,
                                );
                            },
                            .net_spark => {
                                const spark: *const hiccup.NetSparkData = @ptrCast(@alignCast(ptr));
                                self.renderer.drawNetSpark(
                                    bb.x,
                                    bb.y,
                                    bb.width,
                                    bb.height,
                                    spark.values[0..spark.value_count],
                                    spark.value_count,
                                    spark.values2[0..spark.value_count2],
                                    spark.value_count2,
                                    spark.color,
                                    spark.color2,
                                    spark.skew,
                                    spark.bar_width,
                                    spark.bar_gap,
                                    spark.min_bar_height,
                                    spark.fade_start,
                                );
                            },
                        }
                    }
                },
                .none => {},
            }
        }
        self.content_height = max_bottom;
        trace.log("layout.command-counts total={d} rect={d} text={d} border={d} scissor={d} custom={d}", .{
            commands.len,
            rectangles,
            texts,
            borders,
            scissors,
            custom,
        });
    }

    fn measureText(
        text_slice: []const u8,
        config: *clay.TextElementConfig,
        text_renderer: *TextRenderer,
    ) clay.Dimensions {
        const size = text_renderer.measureText(text_slice, config.font_id, config.font_size);
        return .{ .w = size[0], .h = size[1] };
    }

    fn handleClayError(err: clay.ErrorData) callconv(.c) void {
        const msg = err.error_text.chars[0..@intCast(err.error_text.length)];
        log.err("clay: {s}", .{msg});
    }
};

/// Convert Clay color (0-255) to GL color (0-1)
fn clayToGlColor(c: [4]f32) [4]f32 {
    return .{
        c[0] / 255.0,
        c[1] / 255.0,
        c[2] / 255.0,
        c[3] / 255.0,
    };
}
