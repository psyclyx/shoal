const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("fontconfig/fontconfig.h");
    @cInclude("GLES3/gl3.h");
});

const log = std.log.scoped(.text);

// ---------------------------------------------------------------------------
// GlyphRegion — UV coordinates within the atlas
// ---------------------------------------------------------------------------

pub const GlyphRegion = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

// ---------------------------------------------------------------------------
// GlyphInfo — cached per-glyph rendering data
// ---------------------------------------------------------------------------

pub const GlyphInfo = struct {
    region: GlyphRegion,
    width: f32,
    height: f32,
    bearing_x: f32,
    bearing_y: f32,
    advance_x: f32,
};

// ---------------------------------------------------------------------------
// GlyphAtlas — single-channel GL_R8 texture with row-based packing
// ---------------------------------------------------------------------------

const initial_atlas_size: u32 = 512;
const max_atlas_size: u32 = 4096;

pub const GlyphAtlas = struct {
    texture: c.GLuint,
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    row_height: u32,
    generation: u32 = 0,

    pub fn init() GlyphAtlas {
        var tex: c.GLuint = 0;
        c.glGenTextures(1, &tex);
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_R8,
            @intCast(initial_atlas_size),
            @intCast(initial_atlas_size),
            0,
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        return .{
            .texture = tex,
            .width = initial_atlas_size,
            .height = initial_atlas_size,
            .cursor_x = 0,
            .cursor_y = 0,
            .row_height = 0,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        if (self.texture != 0) {
            c.glDeleteTextures(1, &self.texture);
            self.texture = 0;
        }
    }

    /// Upload a glyph bitmap into the atlas, returning the UV region.
    /// Returns null if the atlas is at maximum size and still cannot fit the glyph.
    pub fn upload(
        self: *GlyphAtlas,
        bitmap_width: u32,
        bitmap_height: u32,
        pitch: u32,
        bitmap_data: [*]const u8,
    ) ?GlyphRegion {
        if (bitmap_width == 0 or bitmap_height == 0) {
            return GlyphRegion{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 };
        }

        // Pad each glyph by 1 pixel to avoid filtering artifacts.
        const padded_w = bitmap_width + 1;
        const padded_h = bitmap_height + 1;

        // Try to fit into the current row.
        if (self.cursor_x + padded_w > self.width) {
            // Move to the next row.
            self.cursor_y += self.row_height;
            self.cursor_x = 0;
            self.row_height = 0;
        }

        // Check if we need to grow vertically.
        if (self.cursor_y + padded_h > self.height) {
            if (!self.grow()) return null;
            // After growing, retry positioning (cursor state is preserved).
            if (self.cursor_y + padded_h > self.height) return null;
        }

        const x = self.cursor_x;
        const y = self.cursor_y;

        c.glBindTexture(c.GL_TEXTURE_2D, self.texture);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(pitch));
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            @intCast(x),
            @intCast(y),
            @intCast(bitmap_width),
            @intCast(bitmap_height),
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            bitmap_data,
        );
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);

        self.cursor_x += padded_w;
        if (padded_h > self.row_height) {
            self.row_height = padded_h;
        }

        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);

        return GlyphRegion{
            .u0 = @as(f32, @floatFromInt(x)) / fw,
            .v0 = @as(f32, @floatFromInt(y)) / fh,
            .u1 = @as(f32, @floatFromInt(x + bitmap_width)) / fw,
            .v1 = @as(f32, @floatFromInt(y + bitmap_height)) / fh,
        };
    }

    /// Double the atlas size (up to the cap). Replaces the texture with an
    /// empty one and resets the packing cursor. Bumps `generation` so
    /// FontFace caches invalidate and re-rasterize glyphs on next access.
    fn grow(self: *GlyphAtlas) bool {
        const new_width = self.width * 2;
        const new_height = self.height * 2;

        if (new_width > max_atlas_size or new_height > max_atlas_size) {
            log.err("glyph atlas at maximum size ({0}x{0}), cannot grow", .{max_atlas_size});
            return false;
        }

        log.info("growing glyph atlas from {}x{} to {}x{}", .{
            self.width, self.height, new_width, new_height,
        });

        c.glDeleteTextures(1, &self.texture);

        var new_tex: c.GLuint = 0;
        c.glGenTextures(1, &new_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, new_tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_R8,
            @intCast(new_width),
            @intCast(new_height),
            0,
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            null,
        );

        self.texture = new_tex;
        self.width = new_width;
        self.height = new_height;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
        self.generation += 1;

        return true;
    }
};

// ---------------------------------------------------------------------------
// FontFace — FreeType face + HarfBuzz font, with per-glyph cache
// ---------------------------------------------------------------------------

pub const FontFace = struct {
    ft_face: c.FT_Face,
    hb_font: *c.hb_font_t,
    size: u16,
    glyph_cache: std.AutoHashMap(u32, GlyphInfo),
    atlas: *GlyphAtlas,
    atlas_generation: u32 = 0,

    ascender: f32,
    descender: f32,
    line_height: f32,

    pub fn init(
        allocator: std.mem.Allocator,
        ft_lib: c.FT_Library,
        atlas: *GlyphAtlas,
        font_path: []const u8,
        size: u16,
    ) !FontFace {
        // FreeType needs a null-terminated path.
        const path_z = try allocator.dupeZ(u8, font_path);
        defer allocator.free(path_z);

        var ft_face: c.FT_Face = null;
        if (c.FT_New_Face(ft_lib, path_z.ptr, 0, &ft_face) != 0) {
            return error.FreetypeNewFaceFailed;
        }
        errdefer _ = c.FT_Done_Face(ft_face);

        // Set character size. FreeType sizes are in 1/64th of a point.
        if (c.FT_Set_Pixel_Sizes(ft_face, 0, size) != 0) {
            return error.FreetypeSetSizeFailed;
        }

        const hb_font = c.hb_ft_font_create_referenced(ft_face) orelse
            return error.HarfbuzzFontCreateFailed;

        const metrics = ft_face.*.size.*.metrics;
        const ascender = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const descender = @as(f32, @floatFromInt(metrics.descender)) / 64.0;
        const line_height = @as(f32, @floatFromInt(metrics.height)) / 64.0;

        return FontFace{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .size = size,
            .glyph_cache = std.AutoHashMap(u32, GlyphInfo).init(allocator),
            .atlas = atlas,
            .ascender = ascender,
            .descender = descender,
            .line_height = line_height,
        };
    }

    pub fn deinit(self: *FontFace) void {
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.ft_face);
        self.glyph_cache.deinit();
    }

    /// Get glyph info for a given glyph index, rasterizing and uploading
    /// to the atlas if not already cached.
    pub fn getGlyph(self: *FontFace, glyph_index: u32) !GlyphInfo {
        if (self.atlas.generation != self.atlas_generation) {
            self.glyph_cache.clearRetainingCapacity();
            self.atlas_generation = self.atlas.generation;
        }

        if (self.glyph_cache.get(glyph_index)) |info| {
            return info;
        }

        // Rasterize with FreeType.
        if (c.FT_Load_Glyph(self.ft_face, glyph_index, c.FT_LOAD_RENDER) != 0) {
            return error.FreetypeLoadGlyphFailed;
        }

        const glyph = self.ft_face.*.glyph;
        const bitmap = glyph.*.bitmap;
        const bw: u32 = bitmap.width;
        const bh: u32 = bitmap.rows;
        const pitch: u32 = @intCast(@abs(bitmap.pitch));

        const region = if (bw > 0 and bh > 0)
            self.atlas.upload(bw, bh, pitch, bitmap.buffer) orelse return error.AtlasFull
        else
            GlyphRegion{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 };

        const info = GlyphInfo{
            .region = region,
            .width = @floatFromInt(bw),
            .height = @floatFromInt(bh),
            .bearing_x = @floatFromInt(glyph.*.bitmap_left),
            .bearing_y = @floatFromInt(glyph.*.bitmap_top),
            .advance_x = @as(f32, @floatFromInt(glyph.*.advance.x)) / 64.0,
        };

        try self.glyph_cache.put(glyph_index, info);
        return info;
    }
};

// ---------------------------------------------------------------------------
// ShapedGlyph / ShapedText — output of harfbuzz shaping
// ---------------------------------------------------------------------------

pub const ShapedGlyph = struct {
    glyph_index: u32,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
};

pub const ShapedText = struct {
    glyphs: []ShapedGlyph,
    total_width: f32,

    pub fn deinit(self: ShapedText, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
    }
};

// ---------------------------------------------------------------------------
// TextRenderer — top-level API
// ---------------------------------------------------------------------------

pub const TextRenderer = struct {
    ft_lib: c.FT_Library,
    atlas: GlyphAtlas,
    fonts: std.AutoHashMap(u16, FontFace),
    allocator: std.mem.Allocator,
    next_font_id: u16,

    pub fn init(allocator: std.mem.Allocator) !TextRenderer {
        var ft_lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&ft_lib) != 0) {
            return error.FreetypeInitFailed;
        }

        return TextRenderer{
            .ft_lib = ft_lib,
            .atlas = GlyphAtlas.init(),
            .fonts = std.AutoHashMap(u16, FontFace).init(allocator),
            .allocator = allocator,
            .next_font_id = 0,
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        var it = self.fonts.valueIterator();
        while (it.next()) |face| {
            face.deinit();
        }
        self.fonts.deinit();
        self.atlas.deinit();
        _ = c.FT_Done_FreeType(self.ft_lib);
    }

    /// Load a font by family name using fontconfig. Returns a font_id
    /// that can be used with shapeText / measureText.
    pub fn loadFont(self: *TextRenderer, family: []const u8, size: u16) !u16 {
        const path = findFontPath(family) orelse {
            log.err("fontconfig: no match for family \"{s}\"", .{family});
            return error.FontNotFound;
        };

        const path_slice = std.mem.span(path);

        const font_id = self.next_font_id;
        self.next_font_id += 1;

        const face = try FontFace.init(self.allocator, self.ft_lib, &self.atlas, path_slice, size);
        try self.fonts.put(font_id, face);

        log.info("loaded font id={} family=\"{s}\" size={} path=\"{s}\"", .{
            font_id, family, size, path_slice,
        });

        return font_id;
    }

    /// Resolve a font file path via fontconfig.
    fn findFontPath(family: []const u8) ?[*:0]const u8 {
        const fc_config = c.FcInitLoadConfigAndFonts() orelse return null;
        defer c.FcConfigDestroy(fc_config);

        const pattern = c.FcPatternCreate() orelse return null;
        defer c.FcPatternDestroy(pattern);

        // FcPatternAddString expects a null-terminated FcChar8 string.
        // family might not be null-terminated, so we stack-copy it.
        var buf: [256]u8 = undefined;
        if (family.len >= buf.len) return null;
        @memcpy(buf[0..family.len], family);
        buf[family.len] = 0;

        _ = c.FcPatternAddString(pattern, c.FC_FAMILY, &buf);
        _ = c.FcConfigSubstitute(fc_config, pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = c.FcResultNoMatch;
        const matched = c.FcFontMatch(fc_config, pattern, &result);
        if (matched == null or result != c.FcResultMatch) return null;
        // Note: matched pattern is owned by fontconfig and freed with config.
        // But we need the path to outlive this scope. FcPatternGetString returns
        // a pointer into the pattern's internal storage. We must copy it or
        // keep the pattern alive. For simplicity, we leak the matched pattern
        // (tiny one-time cost per font load).
        // Actually, let's not defer-destroy matched so the string stays valid.
        // The caller (FontFace.init) copies the path into FT_New_Face
        // immediately, so we just need it to survive until then. Since
        // findFontPath is called from loadFont which immediately passes the
        // path to FontFace.init, and FontFace.init dupes it, we're fine
        // as long as the pattern lives until after FontFace.init returns.
        //
        // However, we destroyed fc_config with defer above. FcFontMatch returns
        // a new pattern that we own. So matched is independent of fc_config.
        // We just must not destroy matched before the caller is done with the
        // path. Since we return the pointer and the caller immediately copies
        // it, we intentionally leak matched here (one pattern per font load).

        var file_path: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(matched, c.FC_FILE, 0, &file_path) != c.FcResultMatch) {
            c.FcPatternDestroy(matched);
            return null;
        }

        // We intentionally do NOT destroy `matched` so that `file_path` remains
        // valid for the caller. This is a small intentional leak (once per font
        // load).

        return @ptrCast(file_path);
    }

    /// Shape a UTF-8 text string using harfbuzz, returning positioned glyphs.
    pub fn shapeText(self: *TextRenderer, font_id: u16, text: []const u8) !ShapedText {
        const face_ptr = self.fonts.getPtr(font_id) orelse return error.InvalidFontId;
        return shapeTextInternal(self.allocator, face_ptr.hb_font, text);
    }

    /// Measure text dimensions. Returns .{ width, height }.
    /// Suitable for use as a Clay text measurement callback.
    pub fn measureText(self: *TextRenderer, text: []const u8, font_id: u16, font_size: u16) [2]f32 {
        _ = font_size; // size is baked into the FontFace
        const face_ptr = self.fonts.getPtr(font_id) orelse return .{ 0, 0 };

        const shaped = shapeTextInternal(self.allocator, face_ptr.hb_font, text) catch return .{ 0, 0 };
        defer shaped.deinit(self.allocator);

        return .{ shaped.total_width, face_ptr.line_height };
    }

    /// Get the GL texture handle for the shared glyph atlas.
    pub fn getAtlasTexture(self: *TextRenderer) c.GLuint {
        return self.atlas.texture;
    }

    /// Get glyph info for a specific glyph index from a loaded font.
    pub fn getGlyphInfo(self: *TextRenderer, font_id: u16, glyph_index: u32) !GlyphInfo {
        const face_ptr = self.fonts.getPtr(font_id) orelse return error.InvalidFontId;
        return face_ptr.getGlyph(glyph_index);
    }

    /// Get font metrics for a loaded font.
    pub fn getFontMetrics(self: *TextRenderer, font_id: u16) ?struct {
        ascender: f32,
        descender: f32,
        line_height: f32,
    } {
        const face_ptr = self.fonts.getPtr(font_id) orelse return null;
        return .{
            .ascender = face_ptr.ascender,
            .descender = face_ptr.descender,
            .line_height = face_ptr.line_height,
        };
    }
};

// ---------------------------------------------------------------------------
// Internal: harfbuzz shaping
// ---------------------------------------------------------------------------

fn shapeTextInternal(
    allocator: std.mem.Allocator,
    hb_font: *c.hb_font_t,
    text: []const u8,
) !ShapedText {
    const buf = c.hb_buffer_create() orelse return error.HarfbuzzBufferCreateFailed;
    defer c.hb_buffer_destroy(buf);

    c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);
    c.hb_buffer_set_script(buf, c.HB_SCRIPT_LATIN);
    c.hb_buffer_guess_segment_properties(buf);

    c.hb_shape(hb_font, buf, null, 0);

    var glyph_count: u32 = 0;
    const hb_infos = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
    const hb_positions = c.hb_buffer_get_glyph_positions(buf, &glyph_count);

    if (glyph_count == 0) {
        return ShapedText{
            .glyphs = &.{},
            .total_width = 0,
        };
    }

    const glyphs = try allocator.alloc(ShapedGlyph, glyph_count);
    errdefer allocator.free(glyphs);

    var total_width: f32 = 0;

    for (0..glyph_count) |i| {
        const x_advance = @as(f32, @floatFromInt(hb_positions[i].x_advance)) / 64.0;
        const x_offset = @as(f32, @floatFromInt(hb_positions[i].x_offset)) / 64.0;
        const y_offset = @as(f32, @floatFromInt(hb_positions[i].y_offset)) / 64.0;

        glyphs[i] = ShapedGlyph{
            .glyph_index = hb_infos[i].codepoint,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .x_advance = x_advance,
        };

        total_width += x_advance;
    }

    return ShapedText{
        .glyphs = glyphs,
        .total_width = total_width,
    };
}
