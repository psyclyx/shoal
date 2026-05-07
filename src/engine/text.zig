const std = @import("std");
const snail = @import("snail");
const assets = @import("snail_assets");

const log = std.log.scoped(.text);

const MeasureKey = struct {
    font_id: u16,
    font_size: u16,
    hash: u64,
};

pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    atlas: *snail.TextAtlas,
    retired_atlases: std.ArrayListUnmanaged(*snail.TextAtlas),
    measure_cache: std.AutoHashMap(MeasureKey, [2]f32),
    next_font_id: u16 = 0,
    default_font_size: u16 = 14,

    pub fn init(allocator: std.mem.Allocator) !TextRenderer {
        const atlas = try allocator.create(snail.TextAtlas);
        errdefer allocator.destroy(atlas);
        atlas.* = try snail.TextAtlas.init(allocator, &.{
            .{ .data = assets.noto_sans_regular },
            .{ .data = assets.noto_sans_bold, .weight = .bold },
            .{ .data = assets.noto_sans_arabic, .fallback = true },
            .{ .data = assets.noto_sans_devanagari, .fallback = true },
            .{ .data = assets.noto_sans_mongolian, .fallback = true },
            .{ .data = assets.noto_sans_symbols, .fallback = true },
            .{ .data = assets.noto_sans_thai, .fallback = true },
            .{ .data = assets.noto_emoji, .fallback = true },
            .{ .data = assets.twemoji_mozilla, .fallback = true },
        });

        return .{
            .allocator = allocator,
            .atlas = atlas,
            .retired_atlases = .empty,
            .measure_cache = std.AutoHashMap(MeasureKey, [2]f32).init(allocator),
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        self.clearRetiredAtlases();
        self.retired_atlases.deinit(self.allocator);
        self.measure_cache.deinit();
        self.atlas.deinit();
        self.allocator.destroy(self.atlas);
        self.* = undefined;
    }

    /// Release atlas snapshots that were kept alive for blobs rendered during
    /// the previous frame.
    pub fn beginFrame(self: *TextRenderer) void {
        self.clearRetiredAtlases();
    }

    /// Preserve the existing public API. snail owns the actual font fallback
    /// chain, so the family name is currently advisory.
    pub fn loadFont(self: *TextRenderer, family: []const u8, size: u16) !u16 {
        _ = family;
        const font_id = self.next_font_id;
        self.next_font_id += 1;
        self.default_font_size = size;
        log.info("loaded snail font atlas id={} size={}", .{ font_id, size });
        return font_id;
    }

    pub fn measureText(self: *TextRenderer, text: []const u8, font_id: u16, font_size: u16) [2]f32 {
        const key = MeasureKey{
            .font_id = font_id,
            .font_size = font_size,
            .hash = std.hash.Wyhash.hash(0, text),
        };
        if (self.measure_cache.get(key)) |cached| return cached;

        const size = self.resolveFontSize(font_size);
        const width = self.atlas.measureText(.{}, text, size) catch |err| {
            log.warn("measure text failed: {}", .{err});
            return .{ 0, 0 };
        };
        const result = .{ width, self.lineHeight(size) };
        self.measure_cache.put(key, result) catch {};
        return result;
    }

    pub fn lineHeightForFont(self: *TextRenderer, font_id: u16, font_size: u16) f32 {
        _ = font_id;
        return self.lineHeight(self.resolveFontSize(font_size));
    }

    pub fn buildTextBlob(
        self: *TextRenderer,
        text: []const u8,
        font_id: u16,
        font_size: u16,
        x: f32,
        y: f32,
        color: [4]f32,
    ) !snail.TextBlob {
        _ = font_id;
        if (try self.atlas.ensureText(.{}, text)) |next| {
            const next_atlas = try self.allocator.create(snail.TextAtlas);
            errdefer self.allocator.destroy(next_atlas);
            next_atlas.* = next;
            try self.retired_atlases.append(self.allocator, self.atlas);
            self.atlas = next_atlas;
        }

        const size = self.resolveFontSize(font_size);
        var builder = snail.TextBlobBuilder.init(self.allocator, self.atlas);
        defer builder.deinit();
        _ = try builder.addText(.{}, text, x, self.baselineForTop(y, size), size, color);
        return builder.finish();
    }

    fn resolveFontSize(self: *TextRenderer, font_size: u16) f32 {
        return @floatFromInt(if (font_size == 0) self.default_font_size else font_size);
    }

    fn baselineForTop(self: *TextRenderer, y: f32, font_size: f32) f32 {
        const metrics = self.atlas.lineMetrics() catch return y + font_size;
        const upem = self.atlas.unitsPerEm() catch return y + font_size;
        const scale = font_size / @as(f32, @floatFromInt(upem));
        return y + @as(f32, @floatFromInt(metrics.ascent)) * scale;
    }

    fn lineHeight(self: *TextRenderer, font_size: f32) f32 {
        const metrics = self.atlas.lineMetrics() catch return font_size;
        const upem = self.atlas.unitsPerEm() catch return font_size;
        const scale = font_size / @as(f32, @floatFromInt(upem));
        return @as(f32, @floatFromInt(metrics.ascent - metrics.descent)) * scale;
    }

    fn clearRetiredAtlases(self: *TextRenderer) void {
        for (self.retired_atlases.items) |atlas| {
            atlas.deinit();
            self.allocator.destroy(atlas);
        }
        self.retired_atlases.clearRetainingCapacity();
    }
};
