const std = @import("std");
const clay = @import("clay");
const Renderer = @import("renderer.zig").Renderer;
const TextRenderer = @import("text.zig").TextRenderer;
const hiccup = @import("hiccup.zig");

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

        const arena = clay.createArenaWithCapacityAndMemory(clay_memory);

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
        clay.beginLayout();
    }

    /// End layout, process render commands through the GL renderer.
    pub fn endLayout(self: *Layout) void {
        const commands = clay.endLayout();
        self.processRenderCommands(commands);
    }

    fn processRenderCommands(self: *Layout, commands: []clay.RenderCommand) void {
        var max_bottom: f32 = 0;
        for (commands) |cmd| {
            const bb = cmd.bounding_box;
            const bottom = bb.y + bb.height;
            if (bottom > max_bottom) max_bottom = bottom;
            switch (cmd.command_type) {
                .rectangle => {
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
                    const td = cmd.render_data.text;
                    const text_slice = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.renderText(
                        bb.x,
                        bb.y,
                        text_slice,
                        td.font_id,
                        td.font_size,
                        clayToGlColor(td.text_color),
                    );
                },
                .border => {
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
                    self.renderer.flush();
                    self.renderer.setScissor(bb.x, bb.y, bb.width, bb.height);
                },
                .scissor_end => {
                    self.renderer.flush();
                    self.renderer.clearScissor();
                },
                .image => {
                    // TODO: image rendering
                },
                .custom => {
                    const cd = cmd.render_data.custom;
                    if (cd.custom_data) |ptr| {
                        const curve: *const hiccup.CurveData = @ptrCast(@alignCast(ptr));
                        self.renderer.drawCurve(
                            bb.x,
                            bb.y,
                            bb.width,
                            bb.height,
                            curve.values[0..curve.value_count],
                            curve.value_count,
                            curve.color,
                            curve.color2,
                            curve.fill,
                            curve.thickness,
                            curve.smooth,
                            curve.is_line,
                        );
                    }
                },
                .none => {},
            }
        }
        self.content_height = max_bottom;
    }

    fn renderText(self: *Layout, x: f32, y: f32, text: []const u8, font_id: u16, font_size: u16, color: [4]f32) void {
        _ = font_size;
        const shaped = self.text_renderer.shapeText(font_id, text) catch return;
        defer shaped.deinit(self.text_renderer.allocator);

        const metrics = self.text_renderer.getFontMetrics(font_id) orelse return;
        const baseline_y = y + metrics.ascender;

        var cursor_x = x;
        for (shaped.glyphs) |glyph| {
            const info = self.text_renderer.getGlyphInfo(glyph.font_id, glyph.glyph_index) catch continue;

            const gx = @round(cursor_x + glyph.x_offset + info.bearing_x);
            const gy = @round(baseline_y - glyph.y_offset - info.bearing_y);

            self.renderer.drawTexturedQuad(
                gx,
                gy,
                info.width,
                info.height,
                color,
                info.region.u0,
                info.region.v0,
                info.region.u1 - info.region.u0,
                info.region.v1 - info.region.v0,
            );

            cursor_x += glyph.x_advance;
        }
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
