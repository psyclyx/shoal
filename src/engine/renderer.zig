const std = @import("std");
const snail = @import("snail");
const TextRenderer = @import("text.zig").TextRenderer;
const trace = @import("trace.zig");

const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});

const log = std.log.scoped(.renderer);

pub const TriDir = enum(i32) {
    up = 0,
    right = 1,
    down = 2,
    left = 3,
};

const path_hash_seed: u64 = 0x53484f414c504154;
const path_run_max_ops: usize = 8;
const path_cache_max_entries: usize = 512;
const path_cache_retire_after_frames: u64 = 120;
const prepared_cache_seed: u64 = 0x53484f414c505245;
const prepared_cache_max_entries: usize = 16;
const prepared_cache_retire_after_frames: u64 = 600;
const net_spark_fade_slices: usize = 4;

const PathCacheEntry = struct {
    picture: *snail.PathPicture,
    last_used: u64,
};

const PreparedCacheEntry = struct {
    prepared: snail.PreparedResources,
    last_used: u64,
};

const NetSparkPictureEntry = struct {
    color_key: u32,
    picture: *snail.PathPicture,
};

const NetSparkInstanceBucket = struct {
    color_key: u32,
    color: [4]f32,
    instances: std.ArrayListUnmanaged(snail.Override) = .empty,
};

const RectOp = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    corner_radius: [4]f32,
};

const SlantRectOp = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    skew: f32,
};

const TriangleOp = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    dir: TriDir,
};

const CurveOp = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    values: []const f32,
    value_count: u32,
    values2: []const f32,
    value_count2: u32,
    color: [4]f32,
    color2: [4]f32,
    thickness: f32,
    mirror: bool,
    scroll: f32,
    grid_lines: [8]f32,
    grid_count: u32,
    is_line: bool,
};

const NetSparkOp = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    values: []const f32,
    value_count: u32,
    values2: []const f32,
    value_count2: u32,
    color: [4]f32,
    color2: [4]f32,
    skew: f32,
    bar_width: f32,
    bar_gap: f32,
    min_bar_height: f32,
    fade_start: f32,
};

const PathOp = union(enum) {
    rect: RectOp,
    slant_rect: SlantRectOp,
    triangle: TriangleOp,
    curve: CurveOp,
    net_spark: NetSparkOp,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gl: snail.GlRenderer,
    scene: snail.Scene,
    frame_arena: std.heap.ArenaAllocator,
    text_blobs: std.ArrayListUnmanaged(*snail.TextBlob),
    transient_path_pictures: std.ArrayListUnmanaged(*snail.PathPicture),
    path_ops: std.ArrayListUnmanaged(PathOp),
    path_cache: std.AutoHashMapUnmanaged(u64, PathCacheEntry),
    net_spark_pictures: std.ArrayListUnmanaged(NetSparkPictureEntry),
    prepared_cache: std.AutoHashMapUnmanaged(u64, PreparedCacheEntry),
    resource_entries: std.ArrayListUnmanaged(snail.ResourceSet.Entry),
    draw_words: std.ArrayListUnmanaged(u32),
    draw_segments: std.ArrayListUnmanaged(snail.DrawSegment),
    path_hash: std.hash.Wyhash,
    path_frame: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        var gl = try snail.GlRenderer.init(allocator);
        errdefer gl.deinit();

        return .{
            .allocator = allocator,
            .gl = gl,
            .scene = snail.Scene.init(allocator),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .text_blobs = .empty,
            .transient_path_pictures = .empty,
            .path_ops = .empty,
            .path_cache = .empty,
            .net_spark_pictures = .empty,
            .prepared_cache = .empty,
            .resource_entries = .empty,
            .draw_words = .empty,
            .draw_segments = .empty,
            .path_hash = std.hash.Wyhash.init(path_hash_seed),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.clearBatchResources();
        self.text_blobs.deinit(self.allocator);
        self.transient_path_pictures.deinit(self.allocator);
        self.path_ops.deinit(self.allocator);
        self.clearPathCache();
        self.path_cache.deinit(self.allocator);
        for (self.net_spark_pictures.items) |entry| {
            entry.picture.deinit();
            self.allocator.destroy(entry.picture);
        }
        self.net_spark_pictures.deinit(self.allocator);
        self.frame_arena.deinit();
        self.clearPreparedCache();
        self.prepared_cache.deinit(self.allocator);
        self.resource_entries.deinit(self.allocator);
        self.draw_words.deinit(self.allocator);
        self.draw_segments.deinit(self.allocator);
        self.scene.deinit();
        self.gl.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Renderer, width: f32, height: f32) void {
        const start_ns = trace.nowNs();
        self.path_frame +%= 1;
        self.clearBatchResources();
        self.sweepPathCache();
        self.sweepPreparedCache();
        self.width = width;
        self.height = height;

        c.glViewport(0, 0, @intFromFloat(width), @intFromFloat(height));
        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        trace.log("renderer.begin frame={d} size={d:.0}x{d:.0} dur_ms={d:.3}", .{
            self.path_frame,
            width,
            height,
            trace.elapsedMs(start_ns),
        });
    }

    pub fn end(self: *Renderer) void {
        const start_ns = trace.nowNs();
        self.flush();
        c.glDisable(c.GL_SCISSOR_TEST);
        trace.log("renderer.end frame={d} dur_ms={d:.3}", .{ self.path_frame, trace.elapsedMs(start_ns) });
    }

    pub fn drawText(
        self: *Renderer,
        text_renderer: *TextRenderer,
        x: f32,
        y: f32,
        text: []const u8,
        font_id: u16,
        font_size: u16,
        color: [4]f32,
    ) void {
        if (text.len == 0 or color[3] <= 0) return;

        self.flushPathRun() catch |err| {
            if (err != error.EmptyPicture) log.warn("flush paths before text failed: {}", .{err});
            self.clearBatchResources();
            return;
        };

        var blob = text_renderer.buildTextBlob(text, font_id, font_size, x, y, color) catch |err| {
            log.warn("draw text failed: {}", .{err});
            return;
        };
        self.addTextBlob(blob) catch |err| {
            blob.deinit();
            log.warn("queue text failed: {}", .{err});
        };
    }

    pub fn drawRect(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        corner_radius: [4]f32,
    ) void {
        if (w <= 0 or h <= 0 or color[3] <= 0) return;

        self.queuePathOp(.{ .rect = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = color,
            .corner_radius = corner_radius,
        } });
    }

    pub fn drawSlantRect(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        skew: f32,
    ) void {
        if (w <= 0 or h <= 0 or color[3] <= 0) return;

        self.queuePathOp(.{ .slant_rect = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = color,
            .skew = skew,
        } });
    }

    pub fn drawTriangle(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        dir: TriDir,
    ) void {
        if (w <= 0 or h <= 0 or color[3] <= 0) return;

        self.queuePathOp(.{ .triangle = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = color,
            .dir = dir,
        } });
    }

    pub fn drawBorder(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        widths: [4]f32,
        corner_radius: [4]f32,
    ) void {
        const top = widths[0];
        const right = widths[1];
        const bottom = widths[2];
        const left = widths[3];
        const no_radius = [4]f32{ 0, 0, 0, 0 };

        if (top > 0) self.drawRect(x, y, w, top, color, .{ corner_radius[0], corner_radius[1], 0, 0 });
        if (bottom > 0) self.drawRect(x, y + h - bottom, w, bottom, color, .{ 0, 0, corner_radius[2], corner_radius[3] });
        if (left > 0) self.drawRect(x, y + top, left, h - top - bottom, color, no_radius);
        if (right > 0) self.drawRect(x + w - right, y + top, right, h - top - bottom, color, no_radius);
    }

    pub fn drawCurve(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        values: []const f32,
        value_count: u32,
        values2: []const f32,
        value_count2: u32,
        color: [4]f32,
        color2: [4]f32,
        fill: f32,
        thickness: f32,
        smooth: bool,
        mirror: bool,
        scroll: f32,
        grid_lines: [8]f32,
        grid_count: u32,
        is_line: bool,
    ) void {
        _ = fill;
        _ = smooth;
        if (w <= 0 or h <= 0) return;

        self.queuePathOp(.{ .curve = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .values = values,
            .value_count = value_count,
            .values2 = values2,
            .value_count2 = value_count2,
            .color = color,
            .color2 = color2,
            .thickness = thickness,
            .mirror = mirror,
            .scroll = scroll,
            .grid_lines = grid_lines,
            .grid_count = grid_count,
            .is_line = is_line,
        } });
    }

    pub fn drawNetSpark(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        values: []const f32,
        value_count: u32,
        values2: []const f32,
        value_count2: u32,
        color: [4]f32,
        color2: [4]f32,
        skew: f32,
        bar_width: f32,
        bar_gap: f32,
        min_bar_height: f32,
        fade_start: f32,
    ) void {
        if (w <= 0 or h <= 0) return;

        const op = NetSparkOp{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .values = values,
            .value_count = value_count,
            .values2 = values2,
            .value_count2 = value_count2,
            .color = color,
            .color2 = color2,
            .skew = skew,
            .bar_width = bar_width,
            .bar_gap = bar_gap,
            .min_bar_height = min_bar_height,
            .fade_start = fade_start,
        };
        self.addNetSparkInstances(op) catch |err| {
            log.warn("draw net spark failed: {}", .{err});
        };
    }

    pub fn setScissor(self: *Renderer, x: f32, y: f32, w: f32, h: f32) void {
        self.flush();
        c.glEnable(c.GL_SCISSOR_TEST);
        c.glScissor(
            @intFromFloat(x),
            @intFromFloat(self.height - y - h),
            @intFromFloat(w),
            @intFromFloat(h),
        );
    }

    pub fn clearScissor(self: *Renderer) void {
        self.flush();
        c.glDisable(c.GL_SCISSOR_TEST);
    }

    pub fn flush(self: *Renderer) void {
        if (self.scene.commandCount() == 0 and self.path_ops.items.len == 0) return;

        const start_ns = trace.nowNs();
        const initial_commands = self.scene.commandCount();
        const initial_path_ops = self.path_ops.items.len;

        const path_start_ns = trace.nowNs();
        self.flushPathRun() catch |err| {
            if (err != error.EmptyPicture) log.warn("flush paths failed: {}", .{err});
            self.clearBatchResources();
            return;
        };
        const path_ms = trace.elapsedMs(path_start_ns);
        if (self.scene.commandCount() == 0) {
            trace.log("renderer.flush-empty frame={d} initial_commands={d} initial_path_ops={d} path_ms={d:.3} total_ms={d:.3}", .{
                self.path_frame,
                initial_commands,
                initial_path_ops,
                path_ms,
                trace.elapsedMs(start_ns),
            });
            return;
        }

        const command_count = self.scene.commandCount();
        const resource_entry_count = @max(command_count, 1);
        self.resource_entries.resize(self.allocator, resource_entry_count) catch |err| {
            log.warn("resource entry allocation failed: {}", .{err});
            self.clearBatchResources();
            return;
        };

        var resources = snail.ResourceSet.init(self.resource_entries.items[0..resource_entry_count]);
        const resource_start_ns = trace.nowNs();
        resources.addScene(&self.scene) catch |err| {
            log.warn("resource collection failed: {}", .{err});
            self.clearBatchResources();
            return;
        };
        const resource_ms = trace.elapsedMs(resource_start_ns);

        const resource_lookup_start_ns = trace.nowNs();
        var resource_changed_count: usize = resource_entry_count;
        var resource_uploaded = false;
        var upload_ms: f64 = 0;
        var prepared: *snail.PreparedResources = undefined;
        const manifest_key = resourceManifestKey(&resources);
        if (self.prepared_cache.getPtr(manifest_key)) |cached| {
            cached.last_used = self.path_frame;
            resource_changed_count = 0;
            prepared = &cached.prepared;
        } else {
            const upload_start_ns = trace.nowNs();
            const next_prepared = self.gl.uploadResourcesBlocking(self.allocator, &resources) catch |err| {
                log.warn("resource upload failed: {}", .{err});
                self.clearBatchResources();
                return;
            };
            upload_ms = trace.elapsedMs(upload_start_ns);
            self.prepared_cache.put(self.allocator, manifest_key, .{
                .prepared = next_prepared,
                .last_used = self.path_frame,
            }) catch |err| {
                var owned = next_prepared;
                owned.deinit();
                log.warn("prepared-resource cache allocation failed: {}", .{err});
                self.clearBatchResources();
                return;
            };
            prepared = &self.prepared_cache.getPtr(manifest_key).?.prepared;
            resource_uploaded = true;
        }
        const resource_lookup_ms = trace.elapsedMs(resource_lookup_start_ns);

        const options = snail.DrawOptions{
            .mvp = snail.Mat4.ortho(0, self.width, self.height, 0, -1, 1),
            .target = .{
                .pixel_width = self.width,
                .pixel_height = self.height,
                .subpixel_order = .none,
                .opaque_backdrop = false,
            },
        };
        const estimate_start_ns = trace.nowNs();
        const word_count = snail.DrawList.estimate(&self.scene, options);
        const segment_count = snail.DrawList.estimateSegments(&self.scene, options);
        const estimate_ms = trace.elapsedMs(estimate_start_ns);
        self.draw_words.resize(self.allocator, @max(word_count, 1)) catch |err| {
            log.warn("draw word allocation failed: {}", .{err});
            self.clearBatchResources();
            return;
        };
        self.draw_segments.resize(self.allocator, @max(segment_count, 1)) catch |err| {
            log.warn("draw segment allocation failed: {}", .{err});
            self.clearBatchResources();
            return;
        };

        const drawlist_start_ns = trace.nowNs();
        var draw = snail.DrawList.init(self.draw_words.items[0..word_count], self.draw_segments.items[0..segment_count]);
        draw.addScene(prepared, &self.scene, options) catch |err| {
            log.warn("draw list build failed: {}", .{err});
            self.clearBatchResources();
            return;
        };
        const drawlist_ms = trace.elapsedMs(drawlist_start_ns);
        const draw_start_ns = trace.nowNs();
        self.gl.draw(prepared, draw.slice(), options) catch |err| {
            log.warn("snail draw failed: {}", .{err});
        };
        const draw_ms = trace.elapsedMs(draw_start_ns);
        const cleanup_start_ns = trace.nowNs();
        self.clearBatchResources();
        const cleanup_ms = trace.elapsedMs(cleanup_start_ns);
        trace.log("renderer.flush frame={d} initial_commands={d} initial_path_ops={d} commands={d} resources={d} prepared_cache={d} resource_changed={d} resource_uploaded={} words={d} segments={d} path_ms={d:.3} resource_ms={d:.3} resource_lookup_ms={d:.3} upload_ms={d:.3} estimate_ms={d:.3} drawlist_ms={d:.3} draw_ms={d:.3} cleanup_ms={d:.3} total_ms={d:.3}", .{
            self.path_frame,
            initial_commands,
            initial_path_ops,
            command_count,
            resources.slice().len,
            self.prepared_cache.count(),
            resource_changed_count,
            resource_uploaded,
            word_count,
            segment_count,
            path_ms,
            resource_ms,
            resource_lookup_ms,
            upload_ms,
            estimate_ms,
            drawlist_ms,
            draw_ms,
            cleanup_ms,
            trace.elapsedMs(start_ns),
        });
    }

    fn addTextBlob(self: *Renderer, blob: snail.TextBlob) !void {
        const ptr = try self.allocator.create(snail.TextBlob);
        errdefer self.allocator.destroy(ptr);
        ptr.* = blob;
        errdefer ptr.deinit();
        try self.text_blobs.append(self.allocator, ptr);
        errdefer self.text_blobs.items.len -= 1;
        try self.scene.addText(.{ .blob = ptr });
    }

    fn ensureNetSparkPicture(self: *Renderer, color: [4]f32) !*snail.PathPicture {
        const key = colorKey(color);
        for (self.net_spark_pictures.items) |entry| {
            if (entry.color_key == key) return entry.picture;
        }

        var path = snail.Path.init(self.allocator);
        defer path.deinit();
        try path.moveTo(.{ .x = -0.5, .y = 0 });
        try path.lineTo(.{ .x = 0.5, .y = 0 });
        try path.lineTo(.{ .x = 0.5, .y = 1 });
        try path.lineTo(.{ .x = -0.5, .y = 1 });
        try path.close();

        var builder = snail.PathPictureBuilder.init(self.allocator);
        defer builder.deinit();
        try builder.addFilledPath(&path, .{ .color = color }, .identity);

        const picture = try self.allocator.create(snail.PathPicture);
        errdefer self.allocator.destroy(picture);
        picture.* = try builder.freeze(self.allocator);
        errdefer picture.deinit();
        try self.net_spark_pictures.append(self.allocator, .{
            .color_key = key,
            .picture = picture,
        });
        return picture;
    }

    fn addNetSparkInstances(self: *Renderer, op: NetSparkOp) !void {
        try self.flushPathRun();

        const frame_allocator = self.frame_arena.allocator();
        var buckets: std.ArrayListUnmanaged(NetSparkInstanceBucket) = .empty;
        try buildNetSparkInstances(frame_allocator, &buckets, op);

        for (buckets.items) |bucket| {
            if (bucket.instances.items.len == 0) continue;
            const picture = try self.ensureNetSparkPicture(bucket.color);
            try self.scene.addPath(.{
                .picture = picture,
                .instances = bucket.instances.items,
            });
        }
    }

    fn queuePathOp(self: *Renderer, op: PathOp) void {
        if (!pathOpCacheable(op) and self.path_ops.items.len > 0) {
            self.flushPathRun() catch |err| {
                if (err != error.EmptyPicture) log.warn("flush paths before dynamic op failed: {}", .{err});
                self.clearBatchResources();
            };
        }

        self.path_ops.append(self.allocator, op) catch |err| {
            log.warn("queue path op failed: {}", .{err});
            return;
        };
        hashPathOp(&self.path_hash, op);
        if (self.path_ops.items.len >= path_run_max_ops or !pathOpCacheable(op)) {
            self.flushPathRun() catch |err| {
                if (err != error.EmptyPicture) log.warn("flush path chunk failed: {}", .{err});
                self.clearBatchResources();
            };
        }
    }

    fn flushPathRun(self: *Renderer) !void {
        if (self.path_ops.items.len == 0) return;

        const start_ns = trace.nowNs();
        const cacheable = self.pathRunCacheable();
        const op_count = self.path_ops.items.len;
        const key = self.pathRunKey();
        if (cacheable) {
            if (self.path_cache.getPtr(key)) |entry| {
                entry.last_used = self.path_frame;
                try self.scene.addPath(.{ .picture = entry.picture });
                trace.log("renderer.path-cache-hit frame={d} ops={d} entries={d} dur_ms={d:.3}", .{
                    self.path_frame,
                    op_count,
                    self.path_cache.count(),
                    trace.elapsedMs(start_ns),
                });
                self.resetPathRun();
                return;
            }
        }

        var picture = try self.buildPathRun(self.path_ops.items);
        var picture_owned = true;
        defer if (picture_owned) picture.deinit();

        const ptr = try self.allocator.create(snail.PathPicture);
        errdefer self.allocator.destroy(ptr);
        ptr.* = picture;
        picture_owned = false;
        errdefer ptr.deinit();

        if (!cacheable) {
            try self.transient_path_pictures.append(self.allocator, ptr);
            errdefer self.transient_path_pictures.items.len -= 1;
            try self.scene.addPath(.{ .picture = ptr });
            trace.log("renderer.path-transient frame={d} ops={d} transient={d} build_ms={d:.3}", .{
                self.path_frame,
                op_count,
                self.transient_path_pictures.items.len,
                trace.elapsedMs(start_ns),
            });
            self.resetPathRun();
            return;
        }

        try self.path_cache.put(self.allocator, key, .{
            .picture = ptr,
            .last_used = self.path_frame,
        });
        errdefer _ = self.path_cache.remove(key);
        try self.scene.addPath(.{ .picture = ptr });
        trace.log("renderer.path-cache-miss frame={d} ops={d} entries={d} build_ms={d:.3}", .{
            self.path_frame,
            op_count,
            self.path_cache.count(),
            trace.elapsedMs(start_ns),
        });
        self.resetPathRun();
    }

    fn buildPathRun(self: *Renderer, ops: []const PathOp) !snail.PathPicture {
        var builder = snail.PathPictureBuilder.init(self.allocator);
        defer builder.deinit();

        for (ops) |op| {
            switch (op) {
                .rect => |rect| try addRectOp(self.allocator, &builder, rect),
                .slant_rect => |slant| try addSlantRectOp(self.allocator, &builder, slant),
                .triangle => |triangle| try addTriangleOp(self.allocator, &builder, triangle),
                .curve => |curve| try addCurveOp(&builder, curve),
                .net_spark => |spark| try addNetSparkOp(&builder, spark),
            }
        }

        return builder.freeze(self.allocator);
    }

    fn clearBatchResources(self: *Renderer) void {
        self.scene.reset();
        for (self.text_blobs.items) |blob| {
            blob.deinit();
            self.allocator.destroy(blob);
        }
        self.text_blobs.clearRetainingCapacity();

        for (self.transient_path_pictures.items) |picture| {
            picture.deinit();
            self.allocator.destroy(picture);
        }
        self.transient_path_pictures.clearRetainingCapacity();

        _ = self.frame_arena.reset(.retain_capacity);

        self.resetPathRun();
    }

    fn resetPathRun(self: *Renderer) void {
        self.path_ops.clearRetainingCapacity();
        self.path_hash = std.hash.Wyhash.init(path_hash_seed);
    }

    fn pathRunKey(self: *Renderer) u64 {
        var hasher = self.path_hash;
        hashValue(&hasher, self.path_ops.items.len);
        return hasher.final();
    }

    fn pathRunCacheable(self: *Renderer) bool {
        for (self.path_ops.items) |op| {
            if (!pathOpCacheable(op)) return false;
        }
        return true;
    }

    fn sweepPathCache(self: *Renderer) void {
        if (self.path_cache.count() <= path_cache_max_entries) return;

        const start_ns = trace.nowNs();
        const before = self.path_cache.count();
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.path_cache.iterator();
        while (it.next()) |entry| {
            if (self.path_frame -% entry.value_ptr.last_used > path_cache_retire_after_frames) {
                stale.append(self.allocator, entry.key_ptr.*) catch {
                    self.clearPathCache();
                    return;
                };
            }
        }

        if (stale.items.len == 0) {
            trace.log("renderer.path-cache-clear frame={d} entries_before={d} reason=no-stale dur_ms={d:.3}", .{
                self.path_frame,
                before,
                trace.elapsedMs(start_ns),
            });
            self.clearPathCache();
            return;
        }

        for (stale.items) |key| {
            if (self.path_cache.fetchRemove(key)) |removed| {
                removed.value.picture.deinit();
                self.allocator.destroy(removed.value.picture);
            }
        }
        trace.log("renderer.path-cache-sweep frame={d} entries_before={d} removed={d} entries_after={d} dur_ms={d:.3}", .{
            self.path_frame,
            before,
            stale.items.len,
            self.path_cache.count(),
            trace.elapsedMs(start_ns),
        });
    }

    fn clearPathCache(self: *Renderer) void {
        var it = self.path_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.picture.deinit();
            self.allocator.destroy(entry.value_ptr.picture);
        }
        self.path_cache.clearRetainingCapacity();
    }

    fn sweepPreparedCache(self: *Renderer) void {
        if (self.prepared_cache.count() <= prepared_cache_max_entries) return;

        const start_ns = trace.nowNs();
        const before = self.prepared_cache.count();
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.prepared_cache.iterator();
        while (it.next()) |entry| {
            if (self.path_frame -% entry.value_ptr.last_used > prepared_cache_retire_after_frames) {
                stale.append(self.allocator, entry.key_ptr.*) catch {
                    self.clearPreparedCache();
                    return;
                };
            }
        }

        if (stale.items.len == 0) {
            trace.log("renderer.prepared-cache-clear frame={d} entries_before={d} reason=no-stale dur_ms={d:.3}", .{
                self.path_frame,
                before,
                trace.elapsedMs(start_ns),
            });
            self.clearPreparedCache();
            return;
        }

        for (stale.items) |key| {
            if (self.prepared_cache.fetchRemove(key)) |removed| {
                var entry = removed.value;
                entry.prepared.deinit();
            }
        }
        trace.log("renderer.prepared-cache-sweep frame={d} entries_before={d} removed={d} entries_after={d} dur_ms={d:.3}", .{
            self.path_frame,
            before,
            stale.items.len,
            self.prepared_cache.count(),
            trace.elapsedMs(start_ns),
        });
    }

    fn clearPreparedCache(self: *Renderer) void {
        var it = self.prepared_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.prepared.deinit();
        }
        self.prepared_cache.clearRetainingCapacity();
    }
};

fn resourceManifestKey(resources: *const snail.ResourceSet) u64 {
    var hasher = std.hash.Wyhash.init(prepared_cache_seed);
    const entries = resources.slice();
    hashValue(&hasher, entries.len);
    for (entries) |entry| {
        switch (entry) {
            .text_atlas => |text| {
                hashValue(&hasher, @as(u8, 0));
                hashValue(&hasher, text.key.id);
            },
            .path_picture => |path| {
                hashValue(&hasher, @as(u8, 1));
                hashValue(&hasher, path.key.id);
            },
            .image => |image| {
                hashValue(&hasher, @as(u8, 2));
                hashValue(&hasher, image.key.id);
            },
        }
    }
    return hasher.final();
}

fn addRectOp(allocator: std.mem.Allocator, builder: *snail.PathPictureBuilder, op: RectOp) !void {
    const rect = snail.Rect{ .x = op.x, .y = op.y, .w = op.w, .h = op.h };
    const fill = snail.FillStyle{ .color = op.color };
    if (sameRadius(op.corner_radius)) {
        try builder.addFilledRoundedRect(rect, fill, op.corner_radius[0], .identity);
        return;
    }

    var path = snail.Path.init(allocator);
    defer path.deinit();
    try buildRoundedRectPath(&path, rect, op.corner_radius);
    try builder.addFilledPath(&path, fill, .identity);
}

fn addSlantRectOp(allocator: std.mem.Allocator, builder: *snail.PathPictureBuilder, op: SlantRectOp) !void {
    var path = snail.Path.init(allocator);
    defer path.deinit();
    const shift = op.skew * op.h;
    try path.moveTo(.{ .x = op.x + shift, .y = op.y });
    try path.lineTo(.{ .x = op.x + shift + op.w, .y = op.y });
    try path.lineTo(.{ .x = op.x + op.w, .y = op.y + op.h });
    try path.lineTo(.{ .x = op.x, .y = op.y + op.h });
    try path.close();
    try builder.addFilledPath(&path, .{ .color = op.color }, .identity);
}

fn addTriangleOp(allocator: std.mem.Allocator, builder: *snail.PathPictureBuilder, op: TriangleOp) !void {
    var path = snail.Path.init(allocator);
    defer path.deinit();
    switch (op.dir) {
        .up => {
            try path.moveTo(.{ .x = op.x + op.w * 0.5, .y = op.y });
            try path.lineTo(.{ .x = op.x + op.w, .y = op.y + op.h });
            try path.lineTo(.{ .x = op.x, .y = op.y + op.h });
        },
        .right => {
            try path.moveTo(.{ .x = op.x + op.w, .y = op.y + op.h * 0.5 });
            try path.lineTo(.{ .x = op.x, .y = op.y });
            try path.lineTo(.{ .x = op.x, .y = op.y + op.h });
        },
        .down => {
            try path.moveTo(.{ .x = op.x + op.w * 0.5, .y = op.y + op.h });
            try path.lineTo(.{ .x = op.x, .y = op.y });
            try path.lineTo(.{ .x = op.x + op.w, .y = op.y });
        },
        .left => {
            try path.moveTo(.{ .x = op.x, .y = op.y + op.h * 0.5 });
            try path.lineTo(.{ .x = op.x + op.w, .y = op.y + op.h });
            try path.lineTo(.{ .x = op.x + op.w, .y = op.y });
        },
    }
    try path.close();
    try builder.addFilledPath(&path, .{ .color = op.color }, .identity);
}

fn addCurveOp(builder: *snail.PathPictureBuilder, op: CurveOp) !void {
    try addCurveGrid(builder, op.x, op.y, op.w, op.h, op.grid_lines, op.grid_count);
    if (op.mirror) {
        try addMirrorSeries(builder, op.values, op.value_count, op.x, op.y, op.w, op.h, op.color, op.thickness, op.scroll, op.is_line, true);
        try addMirrorSeries(builder, op.values2, op.value_count2, op.x, op.y, op.w, op.h, op.color2, op.thickness, op.scroll, op.is_line, false);
        return;
    }

    try addSeries(builder, op.values, op.value_count, op.x, op.y, op.w, op.h, op.color, op.thickness, op.scroll, op.is_line);
    if (op.value_count2 > 0) {
        try addSeries(builder, op.values2, op.value_count2, op.x, op.y, op.w, op.h, op.color2, op.thickness, op.scroll, true);
    }
}

fn buildNetSparkInstances(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayListUnmanaged(NetSparkInstanceBucket),
    op: NetSparkOp,
) !void {
    const count1: usize = @min(@as(usize, @intCast(op.value_count)), op.values.len);
    const count2: usize = @min(@as(usize, @intCast(op.value_count2)), op.values2.len);
    const count: usize = @max(count1, count2);
    if (count == 0 or op.w <= 0 or op.h <= 0) return;

    const bar_w = @max(op.bar_width, 1.0);
    const bar_gap = @max(op.bar_gap, 0.0);
    const half_h = op.h * 0.5;
    const center_y = op.y + half_h;
    const content_w = @as(f32, @floatFromInt(count)) * bar_w +
        @as(f32, @floatFromInt(if (count > 0) count - 1 else 0)) * bar_gap;
    const skew_pad = @abs(op.skew) * half_h;
    const total_w = content_w + skew_pad * 2.0;
    const origin_x = op.x + @max(0.0, op.w - total_w) * 0.5 + skew_pad;

    for (0..count) |i| {
        const center_x = origin_x + bar_w * 0.5 +
            @as(f32, @floatFromInt(i)) * (bar_w + bar_gap);
        if (i < count2) {
            try appendNetSparkHalfInstances(
                allocator,
                buckets,
                center_x,
                center_y,
                bar_w,
                @max(0.0, op.values2[i]),
                half_h,
                op.skew,
                op.min_bar_height,
                op.fade_start,
                false,
                op.color2,
            );
        }
        if (i < count1) {
            try appendNetSparkHalfInstances(
                allocator,
                buckets,
                center_x,
                center_y,
                bar_w,
                @max(0.0, op.values[i]),
                half_h,
                op.skew,
                op.min_bar_height,
                op.fade_start,
                true,
                op.color,
            );
        }
    }
}

fn appendNetSparkHalfInstances(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayListUnmanaged(NetSparkInstanceBucket),
    center_x: f32,
    center_y: f32,
    bar_w: f32,
    value: f32,
    half_h: f32,
    skew: f32,
    min_bar_height: f32,
    fade_start: f32,
    upper: bool,
    color: [4]f32,
) !void {
    if (value < 0 or half_h <= 0 or color[3] <= 0) return;

    const bar_h = @max(@max(min_bar_height, 0.0), value * half_h);
    const fade_start_px = std.math.clamp(fade_start, 0.1, 0.98) * half_h;
    const solid_h = @min(bar_h, fade_start_px);

    if (solid_h > 0) {
        try appendNetSparkSliceInstance(allocator, buckets, center_x, center_y, bar_w, 0, solid_h, skew, upper, color);
    }

    const fade_limit = @min(bar_h, half_h);
    if (fade_limit <= fade_start_px) return;

    const fade_span = @max(half_h - fade_start_px, 0.001);
    for (0..net_spark_fade_slices) |i| {
        const f0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(net_spark_fade_slices));
        const f1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(net_spark_fade_slices));
        const d0 = fade_start_px + fade_span * f0;
        const d1 = @min(fade_start_px + fade_span * f1, fade_limit);
        if (d1 <= d0) continue;

        const mid = (d0 + d1) * 0.5;
        const alpha = std.math.clamp((half_h - mid) / fade_span, 0.0, 1.0);
        if (alpha <= 0.02) continue;

        var faded = color;
        faded[3] *= alpha;
        try appendNetSparkSliceInstance(allocator, buckets, center_x, center_y, bar_w, d0, d1, skew, upper, faded);
    }
}

fn appendNetSparkSliceInstance(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayListUnmanaged(NetSparkInstanceBucket),
    center_x: f32,
    center_y: f32,
    bar_w: f32,
    d0: f32,
    d1: f32,
    skew: f32,
    upper: bool,
    color: [4]f32,
) !void {
    const seg_h = d1 - d0;
    if (seg_h <= 0 or color[3] <= 0) return;

    const transform = if (upper)
        snail.Transform2D{
            .xx = bar_w,
            .xy = skew * seg_h,
            .tx = center_x + skew * d0,
            .yx = 0,
            .yy = -seg_h,
            .ty = center_y - d0,
        }
    else
        snail.Transform2D{
            .xx = bar_w,
            .xy = -skew * seg_h,
            .tx = center_x - skew * d0,
            .yx = 0,
            .yy = seg_h,
            .ty = center_y + d0,
        };

    const bucket = try netSparkBucket(allocator, buckets, color);
    try bucket.instances.append(allocator, .{
        .transform = transform,
    });
}

fn netSparkBucket(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayListUnmanaged(NetSparkInstanceBucket),
    color: [4]f32,
) !*NetSparkInstanceBucket {
    const key = colorKey(color);
    for (buckets.items) |*bucket| {
        if (bucket.color_key == key) return bucket;
    }
    try buckets.append(allocator, .{
        .color_key = key,
        .color = color,
    });
    return &buckets.items[buckets.items.len - 1];
}

fn colorKey(color: [4]f32) u32 {
    return (@as(u32, unorm8(color[0])) << 24) |
        (@as(u32, unorm8(color[1])) << 16) |
        (@as(u32, unorm8(color[2])) << 8) |
        @as(u32, unorm8(color[3]));
}

fn unorm8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

fn pathOpCacheable(op: PathOp) bool {
    return switch (op) {
        // This op is time-sampled every render frame. Caching each frame creates
        // a stream of unique retained pictures and periodic cache sweeps.
        .net_spark => false,
        else => true,
    };
}

fn hashPathOp(hasher: *std.hash.Wyhash, op: PathOp) void {
    switch (op) {
        .rect => |rect| {
            hashValue(hasher, @as(u8, 0));
            hashValue(hasher, rect.x);
            hashValue(hasher, rect.y);
            hashValue(hasher, rect.w);
            hashValue(hasher, rect.h);
            hashValue(hasher, rect.color);
            hashValue(hasher, rect.corner_radius);
        },
        .slant_rect => |slant| {
            hashValue(hasher, @as(u8, 1));
            hashValue(hasher, slant.x);
            hashValue(hasher, slant.y);
            hashValue(hasher, slant.w);
            hashValue(hasher, slant.h);
            hashValue(hasher, slant.color);
            hashValue(hasher, slant.skew);
        },
        .triangle => |triangle| {
            hashValue(hasher, @as(u8, 2));
            hashValue(hasher, triangle.x);
            hashValue(hasher, triangle.y);
            hashValue(hasher, triangle.w);
            hashValue(hasher, triangle.h);
            hashValue(hasher, triangle.color);
            hashValue(hasher, @as(i32, @intFromEnum(triangle.dir)));
        },
        .curve => |curve| {
            hashValue(hasher, @as(u8, 3));
            hashValue(hasher, curve.x);
            hashValue(hasher, curve.y);
            hashValue(hasher, curve.w);
            hashValue(hasher, curve.h);
            hashF32Slice(hasher, curve.values, curve.value_count);
            hashF32Slice(hasher, curve.values2, curve.value_count2);
            hashValue(hasher, curve.color);
            hashValue(hasher, curve.color2);
            hashValue(hasher, curve.thickness);
            hashValue(hasher, @as(u8, @intFromBool(curve.mirror)));
            hashValue(hasher, curve.scroll);
            hashValue(hasher, curve.grid_lines);
            hashValue(hasher, curve.grid_count);
            hashValue(hasher, @as(u8, @intFromBool(curve.is_line)));
        },
        .net_spark => |spark| {
            hashValue(hasher, @as(u8, 4));
            hashValue(hasher, spark.x);
            hashValue(hasher, spark.y);
            hashValue(hasher, spark.w);
            hashValue(hasher, spark.h);
            hashF32Slice(hasher, spark.values, spark.value_count);
            hashF32Slice(hasher, spark.values2, spark.value_count2);
            hashValue(hasher, spark.color);
            hashValue(hasher, spark.color2);
            hashValue(hasher, spark.skew);
            hashValue(hasher, spark.bar_width);
            hashValue(hasher, spark.bar_gap);
            hashValue(hasher, spark.min_bar_height);
            hashValue(hasher, spark.fade_start);
        },
    }
}

fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    hasher.update(std.mem.asBytes(&value));
}

fn hashF32Slice(hasher: *std.hash.Wyhash, values: []const f32, value_count: u32) void {
    const count: usize = @intCast(@min(value_count, values.len));
    hashValue(hasher, count);
    hasher.update(std.mem.sliceAsBytes(values[0..count]));
}

fn sameRadius(r: [4]f32) bool {
    return @abs(r[0] - r[1]) < 0.01 and
        @abs(r[0] - r[2]) < 0.01 and
        @abs(r[0] - r[3]) < 0.01;
}

fn buildRoundedRectPath(path: *snail.Path, rect: snail.Rect, radii: [4]f32) !void {
    const max_radius = @min(rect.w, rect.h) * 0.5;
    const tl = std.math.clamp(radii[0], 0, max_radius);
    const tr = std.math.clamp(radii[1], 0, max_radius);
    const bl = std.math.clamp(radii[2], 0, max_radius);
    const br = std.math.clamp(radii[3], 0, max_radius);
    const k: f32 = 0.55228475;
    const x = rect.x;
    const y = rect.y;
    const w = rect.w;
    const h = rect.h;

    try path.moveTo(.{ .x = x + tl, .y = y });
    try path.lineTo(.{ .x = x + w - tr, .y = y });
    if (tr > 0) {
        try path.cubicTo(
            .{ .x = x + w - tr + tr * k, .y = y },
            .{ .x = x + w, .y = y + tr - tr * k },
            .{ .x = x + w, .y = y + tr },
        );
    }
    try path.lineTo(.{ .x = x + w, .y = y + h - br });
    if (br > 0) {
        try path.cubicTo(
            .{ .x = x + w, .y = y + h - br + br * k },
            .{ .x = x + w - br + br * k, .y = y + h },
            .{ .x = x + w - br, .y = y + h },
        );
    }
    try path.lineTo(.{ .x = x + bl, .y = y + h });
    if (bl > 0) {
        try path.cubicTo(
            .{ .x = x + bl - bl * k, .y = y + h },
            .{ .x = x, .y = y + h - bl + bl * k },
            .{ .x = x, .y = y + h - bl },
        );
    }
    try path.lineTo(.{ .x = x, .y = y + tl });
    if (tl > 0) {
        try path.cubicTo(
            .{ .x = x, .y = y + tl - tl * k },
            .{ .x = x + tl - tl * k, .y = y },
            .{ .x = x + tl, .y = y },
        );
    }
    try path.close();
}

fn addCurveGrid(
    builder: *snail.PathPictureBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    grid_lines: [8]f32,
    grid_count: u32,
) !void {
    const count = @min(grid_count, grid_lines.len);
    for (grid_lines[0..count]) |line| {
        if (line <= 0 or line > 1) continue;
        const gy = y + h * (1.0 - line);
        try builder.addFilledRect(
            .{ .x = x, .y = gy - 0.5, .w = w, .h = 1.0 },
            .{ .color = .{ 1, 1, 1, 0.15 } },
            .identity,
        );
    }
}

fn addSeries(
    builder: *snail.PathPictureBuilder,
    values: []const f32,
    value_count: u32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    thickness: f32,
    scroll: f32,
    is_line: bool,
) !void {
    const count: usize = @intCast(@min(value_count, values.len));
    if (count == 0 or color[3] <= 0) return;

    var path = snail.Path.init(builder.allocator);
    defer path.deinit();

    if (!is_line) {
        try path.moveTo(.{ .x = x, .y = y + h });
        for (0..count) |i| {
            const t = if (count == 1) @as(f32, 0) else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            const v = std.math.clamp(sampleSeries(values, count, t, scroll), 0, 1);
            try path.lineTo(.{ .x = x + w * t, .y = y + h * (1.0 - v) });
        }
        try path.lineTo(.{ .x = x + w, .y = y + h });
        try path.close();
        try builder.addFilledPath(&path, .{ .color = color }, .identity);
    } else {
        for (0..count) |i| {
            const t = if (count == 1) @as(f32, 0) else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            const v = std.math.clamp(sampleSeries(values, count, t, scroll), 0, 1);
            const point = snail.Vec2{ .x = x + w * t, .y = y + h * (1.0 - v) };
            if (i == 0) try path.moveTo(point) else try path.lineTo(point);
        }
        try builder.addStrokedPath(&path, .{
            .color = color,
            .width = @max(thickness, 1.0),
            .join = .round,
            .cap = .round,
        }, .identity);
    }
}

fn addMirrorSeries(
    builder: *snail.PathPictureBuilder,
    values: []const f32,
    value_count: u32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    thickness: f32,
    scroll: f32,
    is_line: bool,
    upper: bool,
) !void {
    const count: usize = @intCast(@min(value_count, values.len));
    if (count == 0 or color[3] <= 0) return;

    var path = snail.Path.init(builder.allocator);
    defer path.deinit();
    const center_y = y + h * 0.5;

    if (!is_line) {
        try path.moveTo(.{ .x = x, .y = center_y });
        for (0..count) |i| {
            const t = if (count == 1) @as(f32, 0) else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            const v = std.math.clamp(sampleSeries(values, count, t, scroll), 0, 1) * 0.5;
            const yy = if (upper) y + h * (0.5 - v) else y + h * (0.5 + v);
            try path.lineTo(.{ .x = x + w * t, .y = yy });
        }
        try path.lineTo(.{ .x = x + w, .y = center_y });
        try path.close();
        try builder.addFilledPath(&path, .{ .color = color }, .identity);
    } else {
        for (0..count) |i| {
            const t = if (count == 1) @as(f32, 0) else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            const v = std.math.clamp(sampleSeries(values, count, t, scroll), 0, 1) * 0.5;
            const yy = if (upper) y + h * (0.5 - v) else y + h * (0.5 + v);
            const point = snail.Vec2{ .x = x + w * t, .y = yy };
            if (i == 0) try path.moveTo(point) else try path.lineTo(point);
        }
        try builder.addStrokedPath(&path, .{
            .color = color,
            .width = @max(thickness, 1.0),
            .join = .round,
            .cap = .round,
        }, .identity);
    }
}

fn sampleSeries(values: []const f32, count: usize, t: f32, scroll: f32) f32 {
    if (count == 0) return 0;
    if (count == 1) return values[0];
    const span = @as(f32, @floatFromInt(count - 1));
    const shifted = std.math.clamp(t + scroll / span, 0, 1);
    const pos = shifted * span;
    const idx: usize = @intFromFloat(@floor(pos));
    const next = @min(idx + 1, count - 1);
    const frac = pos - @as(f32, @floatFromInt(idx));
    return values[idx] + (values[next] - values[idx]) * frac;
}

fn appendSlantSegmentPath(
    path: *snail.Path,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    skew: f32,
) !void {
    if (w <= 0 or h <= 0) return;

    const shift = skew * h;
    try path.moveTo(.{ .x = x + shift, .y = y });
    try path.lineTo(.{ .x = x + shift + w, .y = y });
    try path.lineTo(.{ .x = x + w, .y = y + h });
    try path.lineTo(.{ .x = x, .y = y + h });
    try path.close();
}

fn addSlantSegment(
    builder: *snail.PathPictureBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    skew: f32,
) !void {
    if (w <= 0 or h <= 0 or color[3] <= 0) return;

    var path = snail.Path.init(builder.allocator);
    defer path.deinit();

    try appendSlantSegmentPath(&path, x, y, w, h, skew);
    try builder.addFilledPath(&path, .{ .color = color }, .identity);
}

fn appendSparkColumnSlicePath(
    path: *snail.Path,
    used: *bool,
    center_x: f32,
    center_y: f32,
    bar_w: f32,
    d0: f32,
    d1: f32,
    skew: f32,
    upper: bool,
) !void {
    const seg_h = d1 - d0;
    if (seg_h <= 0) return;

    const split_left = center_x - bar_w * 0.5;
    const bottom_y = if (upper) center_y - d0 else center_y + d1;
    const top_y = if (upper) center_y - d1 else center_y + d0;
    const bottom_x = split_left + skew * (center_y - bottom_y);

    try appendSlantSegmentPath(path, bottom_x, top_y, bar_w, seg_h, skew);
    used.* = true;
}

fn appendSparkColumnHalfPaths(
    solid_path: *snail.Path,
    solid_used: *bool,
    fade_paths: []snail.Path,
    fade_used: []bool,
    center_x: f32,
    center_y: f32,
    bar_w: f32,
    value: f32,
    half_h: f32,
    skew: f32,
    min_bar_height: f32,
    fade_start: f32,
    upper: bool,
) !void {
    if (value < 0 or half_h <= 0) return;

    const bar_h = @max(@max(min_bar_height, 0.0), value * half_h);
    const fade_start_px = std.math.clamp(fade_start, 0.1, 0.98) * half_h;
    const solid_h = @min(bar_h, fade_start_px);

    if (solid_h > 0) {
        try appendSparkColumnSlicePath(solid_path, solid_used, center_x, center_y, bar_w, 0, solid_h, skew, upper);
    }

    const fade_limit = @min(bar_h, half_h);
    if (fade_limit <= fade_start_px) return;

    const fade_span = @max(half_h - fade_start_px, 0.001);
    for (fade_paths, 0..) |*fade_path, i| {
        const f0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_paths.len));
        const f1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(fade_paths.len));
        const d0 = fade_start_px + fade_span * f0;
        const d1 = @min(fade_start_px + fade_span * f1, fade_limit);
        if (d1 <= d0) continue;
        try appendSparkColumnSlicePath(fade_path, &fade_used[i], center_x, center_y, bar_w, d0, d1, skew, upper);
    }
}

fn addSparkColumnPaths(
    builder: *snail.PathPictureBuilder,
    solid_path: *snail.Path,
    solid_used: bool,
    fade_paths: []snail.Path,
    fade_used: []bool,
    color: [4]f32,
    half_h: f32,
    fade_start: f32,
) !void {
    if (color[3] <= 0) return;

    if (solid_used) {
        try builder.addFilledPath(solid_path, .{ .color = color }, .identity);
    }

    const fade_start_px = std.math.clamp(fade_start, 0.1, 0.98) * half_h;
    const fade_span = @max(half_h - fade_start_px, 0.001);
    for (fade_paths, fade_used, 0..) |*fade_path, used, i| {
        if (!used) continue;
        const f0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_paths.len));
        const f1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(fade_paths.len));
        const d0 = fade_start_px + fade_span * f0;
        const d1 = fade_start_px + fade_span * f1;
        const mid = (d0 + d1) * 0.5;
        const alpha = std.math.clamp((half_h - mid) / fade_span, 0.0, 1.0);
        if (alpha <= 0.02) continue;

        var faded = color;
        faded[3] *= alpha;
        try builder.addFilledPath(fade_path, .{ .color = faded }, .identity);
    }
}

fn addSparkCurveOverlay(
    builder: *snail.PathPictureBuilder,
    origin_x: f32,
    center_y: f32,
    bar_w: f32,
    bar_gap: f32,
    values: []const f32,
    count: usize,
    half_h: f32,
    color: [4]f32,
    skew: f32,
    upper: bool,
) !void {
    if (count == 0 or color[3] <= 0) return;

    var path = snail.Path.init(builder.allocator);
    defer path.deinit();

    for (0..count) |i| {
        const center_x = origin_x + bar_w * 0.5 +
            @as(f32, @floatFromInt(i)) * (bar_w + bar_gap);
        const d = @min(@max(0.0, values[i]) * half_h, half_h);
        const point = if (upper)
            snail.Vec2{ .x = center_x + skew * d, .y = center_y - d }
        else
            snail.Vec2{ .x = center_x - skew * d, .y = center_y + d };

        if (i == 0) try path.moveTo(point) else try path.lineTo(point);
    }

    var line_color = color;
    line_color[3] = @min(1.0, line_color[3] * 1.25);
    try builder.addStrokedPath(&path, .{
        .color = line_color,
        .width = 1.35,
        .join = .round,
        .cap = .round,
    }, .identity);
}

fn addNetSparkOp(builder: *snail.PathPictureBuilder, op: NetSparkOp) !void {
    const count1: usize = @min(@as(usize, @intCast(op.value_count)), op.values.len);
    const count2: usize = @min(@as(usize, @intCast(op.value_count2)), op.values2.len);
    const count: usize = @max(count1, count2);
    if (count == 0 or op.w <= 0 or op.h <= 0) return;

    const fade_slices: usize = net_spark_fade_slices;
    const bar_w = @max(op.bar_width, 1.0);
    const bar_gap = @max(op.bar_gap, 0.0);
    const half_h = op.h * 0.5;
    const center_y = op.y + half_h;
    const content_w = @as(f32, @floatFromInt(count)) * bar_w +
        @as(f32, @floatFromInt(if (count > 0) count - 1 else 0)) * bar_gap;
    const skew_pad = @abs(op.skew) * half_h;
    const total_w = content_w + skew_pad * 2.0;
    const origin_x = op.x + @max(0.0, op.w - total_w) * 0.5 + skew_pad;

    var tx_solid = snail.Path.init(builder.allocator);
    defer tx_solid.deinit();
    var rx_solid = snail.Path.init(builder.allocator);
    defer rx_solid.deinit();
    var tx_solid_used = false;
    var rx_solid_used = false;

    var tx_fade: [fade_slices]snail.Path = undefined;
    var rx_fade: [fade_slices]snail.Path = undefined;
    var tx_fade_used = [_]bool{false} ** fade_slices;
    var rx_fade_used = [_]bool{false} ** fade_slices;
    for (0..fade_slices) |i| {
        tx_fade[i] = snail.Path.init(builder.allocator);
        rx_fade[i] = snail.Path.init(builder.allocator);
    }
    defer {
        for (&tx_fade) |*path| path.deinit();
        for (&rx_fade) |*path| path.deinit();
    }

    for (0..count) |i| {
        const center_x = origin_x + bar_w * 0.5 +
            @as(f32, @floatFromInt(i)) * (bar_w + bar_gap);
        if (i < count2) {
            try appendSparkColumnHalfPaths(
                &tx_solid,
                &tx_solid_used,
                tx_fade[0..],
                tx_fade_used[0..],
                center_x,
                center_y,
                bar_w,
                @max(0.0, op.values2[i]),
                half_h,
                op.skew,
                op.min_bar_height,
                op.fade_start,
                false,
            );
        }
        if (i < count1) {
            try appendSparkColumnHalfPaths(
                &rx_solid,
                &rx_solid_used,
                rx_fade[0..],
                rx_fade_used[0..],
                center_x,
                center_y,
                bar_w,
                @max(0.0, op.values[i]),
                half_h,
                op.skew,
                op.min_bar_height,
                op.fade_start,
                true,
            );
        }
    }

    try addSparkColumnPaths(builder, &tx_solid, tx_solid_used, tx_fade[0..], tx_fade_used[0..], op.color2, half_h, op.fade_start);
    try addSparkColumnPaths(builder, &rx_solid, rx_solid_used, rx_fade[0..], rx_fade_used[0..], op.color, half_h, op.fade_start);

    if (count2 > 0) {
        try addSparkCurveOverlay(
            builder,
            origin_x,
            center_y,
            bar_w,
            bar_gap,
            op.values2,
            count2,
            half_h,
            op.color2,
            op.skew,
            false,
        );
    }
    if (count1 > 0) {
        try addSparkCurveOverlay(
            builder,
            origin_x,
            center_y,
            bar_w,
            bar_gap,
            op.values,
            count1,
            half_h,
            op.color,
            op.skew,
            true,
        );
    }
}
