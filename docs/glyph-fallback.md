# Glyph Fallback Design

## Problem

Berkeley Mono lacks many Unicode glyphs (em dash U+2014, box drawing, emoji,
etc.). HarfBuzz returns glyph index 0 (`.notdef`) for missing characters,
which FreeType renders as "?" or an empty box. Window titles with em dashes
show "Place Your Order ? Mozilla Firefox" instead of the actual dash.

## Approach: Per-Glyph Font Substitution

After HarfBuzz shapes text with the primary font, scan for `.notdef` glyphs.
For each missing codepoint, find a fallback font via fontconfig, load it, and
substitute the glyph. The renderer already processes glyphs individually —
we just need each `ShapedGlyph` to carry its own `font_id`.

### Data Changes

**`ShapedGlyph`** — add `font_id: u16`:
```zig
pub const ShapedGlyph = struct {
    glyph_index: u32,
    font_id: u16,       // NEW: which font to rasterize from
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
};
```

**`layout.zig:renderText`** — use `glyph.font_id` instead of the passed-in
`font_id`:
```zig
const info = self.text_renderer.getGlyphInfo(glyph.font_id, glyph.glyph_index) catch continue;
```

### Shaping with Fallback

In `shapeText`, after HarfBuzz shapes the text:

1. Scan `hb_infos` for glyph_index == 0 (`.notdef`)
2. For each `.notdef`, find the source codepoint from the cluster index
   (cluster points into the original UTF-8 byte offset)
3. Call `findFallbackFont(codepoint)` → returns a `font_id` for a font that
   covers this codepoint, or null if none found
4. Re-shape just the codepoint with the fallback font's HarfBuzz font to get
   correct advance/offset values
5. Set `glyph.font_id` and `glyph.glyph_index` from the fallback result

Why re-shape rather than just `FT_Get_Char_Index`? HarfBuzz computes proper
advances for the fallback font's metrics. Using the primary font's .notdef
advance would produce wrong spacing.

### Fallback Font Resolution

**`findFallbackFont(codepoint: u32) -> ?u16`**:
1. Check the fallback cache: `HashMap(u32, u16)` mapping codepoint → font_id.
   If cached, return immediately.
2. Use fontconfig to find a font covering the codepoint:
   ```c
   FcPatternAddCharSet(pattern, FC_CHARSET, charset_with_codepoint);
   FcFontMatch(config, pattern, &result);
   ```
3. If found, check if we've already loaded this font path (avoid duplicates).
   If not, call `loadFont` with the path directly (not by family name).
4. Cache the mapping: codepoint → font_id. Also cache the font path → font_id
   mapping to reuse the same font face for multiple codepoints.

### Caching Strategy

Two caches in `TextRenderer`:
- `fallback_codepoint_cache: HashMap(u32, ?u16)` — codepoint → font_id (or
  null for "no font has this glyph"). Avoids repeated fontconfig queries.
- `fallback_path_cache: HashMap([]const u8, u16)` — font path → font_id.
  Prevents loading the same font multiple times when it covers multiple
  missing codepoints.

Fallback fonts reuse the existing `fonts: HashMap(u16, FontFace)` — they're
just additional entries with auto-assigned font_ids. They share the same
`GlyphAtlas` as the primary font.

### Size Matching

Fallback fonts must be loaded at the same pixel size as the primary font they
substitute for. Since `shapeText` takes a `font_id`, and each `FontFace` has
a fixed `size`, the fallback must match. This means the fallback cache is
per-size: a 14px primary font needs 14px fallbacks.

Simplification: the bar currently uses a single font size (14). If multiple
sizes are needed later, the cache key becomes `(codepoint, size)` instead of
just `codepoint`.

### measureText Consistency

`measureText` must also use fallback — otherwise Clay measures text narrower
than it renders (`.notdef` advance ≠ fallback glyph advance). Since
`measureText` calls `shapeText` internally, this comes for free once
`shapeText` handles fallback.

### What This Doesn't Handle

- **Emoji** — need a color font (COLR/CBDT), our renderer only does grayscale
  glyphs. Fallback will find a font with emoji outlines but they'll render
  as monochrome silhouettes. Fine for a bar.
- **Complex script shaping** — substituting individual glyphs breaks ligatures
  and contextual shaping. Not an issue for the bar's use case (Latin text with
  occasional Unicode punctuation).
- **Font style matching** — fallback doesn't match bold/italic. The bar only
  uses regular weight, so this doesn't matter.

### Implementation Plan

1. Add `font_id` to `ShapedGlyph`, update `renderText` to use it
2. Add `findFallbackFont` with fontconfig codepoint lookup + caching
3. Add fallback substitution in `shapeText` after initial shaping
4. Verify em dash renders correctly in window titles
