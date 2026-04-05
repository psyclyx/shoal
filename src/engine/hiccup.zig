const std = @import("std");
const clay = @import("clay");
const janet = @import("janet.zig");
const jc = janet.c;

const log = std.log.scoped(.hiccup);

// Pre-interned keyword constants (set by init)
var kw_row: jc.Janet = undefined;
var kw_col: jc.Janet = undefined;
var kw_text: jc.Janet = undefined;
var kw_area: jc.Janet = undefined;
var kw_line: jc.Janet = undefined;
var kw_w: jc.Janet = undefined;
var kw_h: jc.Janet = undefined;
var kw_pad: jc.Janet = undefined;
var kw_gap: jc.Janet = undefined;
var kw_align_x: jc.Janet = undefined;
var kw_align_y: jc.Janet = undefined;
var kw_bg: jc.Janet = undefined;
var kw_radius: jc.Janet = undefined;
var kw_border_color: jc.Janet = undefined;
var kw_border_width: jc.Janet = undefined;
var kw_id: jc.Janet = undefined;
var kw_color: jc.Janet = undefined;
var kw_color2: jc.Janet = undefined;
var kw_font: jc.Janet = undefined;
var kw_size: jc.Janet = undefined;
var kw_wrap: jc.Janet = undefined;
var kw_text_align: jc.Janet = undefined;
var kw_values: jc.Janet = undefined;
var kw_fill: jc.Janet = undefined;
var kw_thickness: jc.Janet = undefined;
var kw_smooth: jc.Janet = undefined;
// Sizing keywords
var kw_grow: jc.Janet = undefined;
var kw_fit: jc.Janet = undefined;
var kw_percent: jc.Janet = undefined;
// Alignment keywords
var kw_left: jc.Janet = undefined;
var kw_right: jc.Janet = undefined;
var kw_center: jc.Janet = undefined;
var kw_top: jc.Janet = undefined;
var kw_bottom: jc.Janet = undefined;
// Wrap keywords
var kw_words: jc.Janet = undefined;
var kw_newlines: jc.Janet = undefined;
var kw_none: jc.Janet = undefined;

// GC roots for strings coerced via janet_to_string during a render pass.
// These must survive until Clay's endLayout reads them.
const MAX_COERCED_STRINGS = 256;
var coerced_roots: [MAX_COERCED_STRINGS]jc.Janet = undefined;
var coerced_count: usize = 0;

// ---------------------------------------------------------------------------
// Per-frame curve data storage
// ---------------------------------------------------------------------------

pub const MAX_CURVES = 16;
pub const MAX_CURVE_VALUES = 64;

pub const CurveData = struct {
    values: [MAX_CURVE_VALUES]f32 = [_]f32{0} ** MAX_CURVE_VALUES,
    value_count: u32 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    color2: [4]f32 = .{ 1, 1, 1, 0.3 },
    fill: f32 = 1.0,
    thickness: f32 = 1.5,
    smooth: bool = true,
    is_line: bool = false,
};

var curve_storage: [MAX_CURVES]CurveData = undefined;
var curve_count: usize = 0;

/// Call before walkHiccup to begin tracking coerced string roots.
pub fn beginPass() void {
    coerced_count = 0;
    curve_count = 0;
}

/// Call after Clay endLayout to unroot coerced strings.
pub fn endPass() void {
    for (coerced_roots[0..coerced_count]) |val| {
        _ = jc.janet_gcunroot(val);
    }
    coerced_count = 0;
}

var initialized = false;

pub fn init() void {
    kw_row = janet.kw("row");
    kw_col = janet.kw("col");
    kw_text = janet.kw("text");
    kw_area = janet.kw("area");
    kw_line = janet.kw("line");
    kw_w = janet.kw("w");
    kw_h = janet.kw("h");
    kw_pad = janet.kw("pad");
    kw_gap = janet.kw("gap");
    kw_align_x = janet.kw("align-x");
    kw_align_y = janet.kw("align-y");
    kw_bg = janet.kw("bg");
    kw_radius = janet.kw("radius");
    kw_border_color = janet.kw("border-color");
    kw_border_width = janet.kw("border-width");
    kw_id = janet.kw("id");
    kw_color = janet.kw("color");
    kw_color2 = janet.kw("color2");
    kw_font = janet.kw("font");
    kw_size = janet.kw("size");
    kw_wrap = janet.kw("wrap");
    kw_text_align = janet.kw("text-align");
    kw_values = janet.kw("values");
    kw_fill = janet.kw("fill");
    kw_thickness = janet.kw("thickness");
    kw_smooth = janet.kw("smooth");
    kw_grow = janet.kw("grow");
    kw_fit = janet.kw("fit");
    kw_percent = janet.kw("percent");
    kw_left = janet.kw("left");
    kw_right = janet.kw("right");
    kw_center = janet.kw("center");
    kw_top = janet.kw("top");
    kw_bottom = janet.kw("bottom");
    kw_words = janet.kw("words");
    kw_newlines = janet.kw("newlines");
    kw_none = janet.kw("none");
    initialized = true;
}

/// Walk a Janet hiccup tree and emit Clay layout calls.
pub fn walkHiccup(node: jc.Janet) void {
    std.debug.assert(initialized);

    // Skip nil
    if (jc.janet_checktype(node, jc.JANET_NIL) != 0) return;

    // If it's a string, that's an error — bare strings only valid as text children
    if (jc.janet_checktype(node, jc.JANET_STRING) != 0) {
        log.warn("bare string in hiccup tree (only valid as :text child)", .{});
        return;
    }

    // Must be a tuple or array
    if (jc.janet_checktype(node, jc.JANET_TUPLE) == 0 and
        jc.janet_checktype(node, jc.JANET_ARRAY) == 0)
    {
        return;
    }

    const view = janetIndexedSlice(node) orelse return;
    if (view.len == 0) return;

    const first = view[0];

    // If first element is not a keyword, treat as a list of hiccup nodes (splice)
    if (jc.janet_checktype(first, jc.JANET_KEYWORD) == 0) {
        for (view) |child| {
            walkHiccup(child);
        }
        return;
    }

    // Parse tag, attrs, children_start
    const tag = first;
    var attrs = jc.janet_wrap_nil();
    var children_start: usize = 1;

    if (view.len > 1) {
        const second = view[1];
        if (jc.janet_checktype(second, jc.JANET_TABLE) != 0 or
            jc.janet_checktype(second, jc.JANET_STRUCT) != 0)
        {
            attrs = second;
            children_start = 2;
        }
    }

    if (janetKeywordEql(tag, kw_text)) {
        walkText(attrs, view[children_start..]);
    } else if (janetKeywordEql(tag, kw_row)) {
        walkContainer(.left_to_right, attrs, view[children_start..]);
    } else if (janetKeywordEql(tag, kw_col)) {
        walkContainer(.top_to_bottom, attrs, view[children_start..]);
    } else if (janetKeywordEql(tag, kw_area)) {
        walkCurve(false, attrs);
    } else if (janetKeywordEql(tag, kw_line)) {
        walkCurve(true, attrs);
    } else {
        log.warn("unknown hiccup tag, skipping", .{});
    }
}

fn walkContainer(direction: clay.LayoutDirection, attrs: jc.Janet, children: []const jc.Janet) void {
    var config = clay.ElementDeclaration{
        .layout = .{
            .direction = direction,
        },
    };

    applyContainerAttrs(&config, attrs);

    clay.cdefs.Clay__OpenElement();
    clay.cdefs.Clay__ConfigureOpenElement(config);

    for (children) |child| {
        walkHiccup(child);
    }

    clay.cdefs.Clay__CloseElement();
}

fn walkText(attrs: jc.Janet, children: []const jc.Janet) void {
    if (children.len == 0) return;

    // Get text content — single pre-concatenated string expected.
    // Janet views should use (string ...) to build text before returning hiccup.
    if (children.len > 1) {
        log.warn(":text has {d} children, using first only — pre-concatenate with (string ...)", .{children.len});
    }
    const text_slice = janetToString(children[0]);

    if (text_slice.len == 0) return;

    var text_config = clay.TextElementConfig{};
    applyTextAttrs(&text_config, attrs);

    clay.cdefs.Clay__OpenTextElement(
        clay.String.fromSlice(text_slice),
        clay.cdefs.Clay__StoreTextElementConfig(text_config),
    );
}

fn walkCurve(is_line: bool, attrs: jc.Janet) void {
    if (curve_count >= MAX_CURVES) {
        log.warn("too many curve elements ({d}), skipping", .{MAX_CURVES});
        return;
    }

    var data = CurveData{ .is_line = is_line };

    if (jc.janet_checktype(attrs, jc.JANET_NIL) == 0) {
        // :values — array of 0-1 floats
        const values_val = janet.janetGet(attrs, kw_values);
        if (jc.janet_checktype(values_val, jc.JANET_NIL) == 0) {
            const items = janetIndexedSlice(values_val) orelse &[0]jc.Janet{};
            const n: usize = @min(items.len, MAX_CURVE_VALUES);
            for (items[0..n], 0..) |item, i| {
                data.values[i] = janetToF32(item) orelse 0;
            }
            data.value_count = @intCast(n);
        }

        // :color — primary color (0-255 RGBA)
        const color_val = janet.janetGet(attrs, kw_color);
        if (jc.janet_checktype(color_val, jc.JANET_NIL) == 0) {
            const col = parseColor(color_val);
            data.color = .{ col[0] / 255.0, col[1] / 255.0, col[2] / 255.0, col[3] / 255.0 };
        }

        // :color2 — speculative/secondary color (0-255 RGBA)
        const color2_val = janet.janetGet(attrs, kw_color2);
        if (jc.janet_checktype(color2_val, jc.JANET_NIL) == 0) {
            const col = parseColor(color2_val);
            data.color2 = .{ col[0] / 255.0, col[1] / 255.0, col[2] / 255.0, col[3] / 255.0 };
        }

        // :fill — boundary between real and speculative data (0-1)
        const fill_val = janet.janetGet(attrs, kw_fill);
        if (jc.janet_checktype(fill_val, jc.JANET_NIL) == 0) {
            data.fill = janetToF32(fill_val) orelse 1.0;
        }

        // :thickness — line stroke width in pixels
        const thick_val = janet.janetGet(attrs, kw_thickness);
        if (jc.janet_checktype(thick_val, jc.JANET_NIL) == 0) {
            data.thickness = janetToF32(thick_val) orelse 1.5;
        }

        // :smooth — enable Catmull-Rom interpolation (boolean)
        const smooth_val = janet.janetGet(attrs, kw_smooth);
        if (jc.janet_checktype(smooth_val, jc.JANET_NIL) == 0) {
            data.smooth = jc.janet_truthy(smooth_val) != 0;
        }
    }

    curve_storage[curve_count] = data;
    const data_ptr: *anyopaque = @ptrCast(&curve_storage[curve_count]);
    curve_count += 1;

    // Emit a Clay custom element so it participates in layout and produces
    // a .custom render command with our CurveData pointer.
    var config = clay.ElementDeclaration{
        .custom = .{ .custom_data = data_ptr },
    };

    applyContainerAttrs(&config, attrs);

    clay.cdefs.Clay__OpenElement();
    clay.cdefs.Clay__ConfigureOpenElement(config);
    clay.cdefs.Clay__CloseElement();
}

// ---------------------------------------------------------------------------
// Attribute parsing
// ---------------------------------------------------------------------------

fn applyContainerAttrs(config: *clay.ElementDeclaration, attrs: jc.Janet) void {
    if (jc.janet_checktype(attrs, jc.JANET_NIL) != 0) return;

    // :w
    const w_val = janet.janetGet(attrs, kw_w);
    if (jc.janet_checktype(w_val, jc.JANET_NIL) == 0) {
        config.layout.sizing.w = parseSizing(w_val);
    }

    // :h
    const h_val = janet.janetGet(attrs, kw_h);
    if (jc.janet_checktype(h_val, jc.JANET_NIL) == 0) {
        config.layout.sizing.h = parseSizing(h_val);
    }

    // :pad
    const pad_val = janet.janetGet(attrs, kw_pad);
    if (jc.janet_checktype(pad_val, jc.JANET_NIL) == 0) {
        config.layout.padding = parsePadding(pad_val);
    }

    // :gap
    const gap_val = janet.janetGet(attrs, kw_gap);
    if (jc.janet_checktype(gap_val, jc.JANET_NIL) == 0) {
        if (jc.janet_checktype(gap_val, jc.JANET_NUMBER) != 0) {
            config.layout.child_gap = floatToU16(jc.janet_unwrap_number(gap_val));
        }
    }

    // :align-x
    const ax_val = janet.janetGet(attrs, kw_align_x);
    if (jc.janet_checktype(ax_val, jc.JANET_NIL) == 0) {
        config.layout.child_alignment.x = parseAlignX(ax_val);
    }

    // :align-y
    const ay_val = janet.janetGet(attrs, kw_align_y);
    if (jc.janet_checktype(ay_val, jc.JANET_NIL) == 0) {
        config.layout.child_alignment.y = parseAlignY(ay_val);
    }

    // :bg
    const bg_val = janet.janetGet(attrs, kw_bg);
    if (jc.janet_checktype(bg_val, jc.JANET_NIL) == 0) {
        config.background_color = parseColor(bg_val);
    }

    // :radius
    const radius_val = janet.janetGet(attrs, kw_radius);
    if (jc.janet_checktype(radius_val, jc.JANET_NIL) == 0) {
        config.corner_radius = parseRadius(radius_val);
    }

    // :border-color + :border-width
    const bc_val = janet.janetGet(attrs, kw_border_color);
    const bw_val = janet.janetGet(attrs, kw_border_width);
    if (jc.janet_checktype(bc_val, jc.JANET_NIL) == 0) {
        config.border.color = parseColor(bc_val);
    }
    if (jc.janet_checktype(bw_val, jc.JANET_NIL) == 0) {
        config.border.width = parseBorderWidth(bw_val);
    }

    // :id
    const id_val = janet.janetGet(attrs, kw_id);
    if (jc.janet_checktype(id_val, jc.JANET_NIL) == 0) {
        if (jc.janet_checktype(id_val, jc.JANET_STRING) != 0) {
            const s = jc.janet_unwrap_string(id_val);
            const len: usize = @intCast(jc.janet_string_length(s));
            config.id = clay.ElementId.ID(s[0..len]);
        }
    }
}

fn applyTextAttrs(config: *clay.TextElementConfig, attrs: jc.Janet) void {
    if (jc.janet_checktype(attrs, jc.JANET_NIL) != 0) return;

    // :color
    const color_val = janet.janetGet(attrs, kw_color);
    if (jc.janet_checktype(color_val, jc.JANET_NIL) == 0) {
        config.color = parseColor(color_val);
    }

    // :font
    const font_val = janet.janetGet(attrs, kw_font);
    if (jc.janet_checktype(font_val, jc.JANET_NIL) == 0) {
        if (jc.janet_checktype(font_val, jc.JANET_NUMBER) != 0) {
            config.font_id = floatToU16(jc.janet_unwrap_number(font_val));
        }
    }

    // :size
    const size_val = janet.janetGet(attrs, kw_size);
    if (jc.janet_checktype(size_val, jc.JANET_NIL) == 0) {
        if (jc.janet_checktype(size_val, jc.JANET_NUMBER) != 0) {
            config.font_size = floatToU16(jc.janet_unwrap_number(size_val));
        }
    }

    // :wrap
    const wrap_val = janet.janetGet(attrs, kw_wrap);
    if (jc.janet_checktype(wrap_val, jc.JANET_NIL) == 0) {
        if (janetKeywordEql(wrap_val, kw_words)) {
            config.wrap_mode = .words;
        } else if (janetKeywordEql(wrap_val, kw_newlines)) {
            config.wrap_mode = .new_lines;
        } else if (janetKeywordEql(wrap_val, kw_none)) {
            config.wrap_mode = .none;
        }
    }

    // :text-align
    const ta_val = janet.janetGet(attrs, kw_text_align);
    if (jc.janet_checktype(ta_val, jc.JANET_NIL) == 0) {
        if (janetKeywordEql(ta_val, kw_left)) {
            config.alignment = .left;
        } else if (janetKeywordEql(ta_val, kw_center)) {
            config.alignment = .center;
        } else if (janetKeywordEql(ta_val, kw_right)) {
            config.alignment = .right;
        }
    }
}

// ---------------------------------------------------------------------------
// Value parsers
// ---------------------------------------------------------------------------

fn parseSizing(val: jc.Janet) clay.SizingAxis {
    // Keyword: :grow or :fit
    if (jc.janet_checktype(val, jc.JANET_KEYWORD) != 0) {
        if (janetKeywordEql(val, kw_grow)) return clay.SizingAxis.grow;
        if (janetKeywordEql(val, kw_fit)) return .{};
        return .{};
    }

    // Number: fixed size
    if (jc.janet_checktype(val, jc.JANET_NUMBER) != 0) {
        return clay.SizingAxis.fixed(@floatCast(jc.janet_unwrap_number(val)));
    }

    // Tuple: [:percent 0.5], [:grow min max], [:fit min max]
    const items = janetIndexedSlice(val) orelse return .{};
    if (items.len < 2) return .{};

    const kind = items[0];
    if (jc.janet_checktype(kind, jc.JANET_KEYWORD) == 0) return .{};

    if (janetKeywordEql(kind, kw_percent)) {
        if (jc.janet_checktype(items[1], jc.JANET_NUMBER) != 0) {
            return clay.SizingAxis.percent(@floatCast(jc.janet_unwrap_number(items[1])));
        }
    } else if (janetKeywordEql(kind, kw_grow) and items.len >= 3) {
        const min_val = janetToF32(items[1]) orelse 0;
        const max_val = janetToF32(items[2]) orelse 0;
        return clay.SizingAxis.growMinMax(.{ .min = min_val, .max = max_val });
    } else if (janetKeywordEql(kind, kw_fit) and items.len >= 3) {
        const min_val = janetToF32(items[1]) orelse 0;
        const max_val = janetToF32(items[2]) orelse 0;
        return clay.SizingAxis.fitMinMax(.{ .min = min_val, .max = max_val });
    }

    return .{};
}

fn parsePadding(val: jc.Janet) clay.Padding {
    // Number: all sides
    if (jc.janet_checktype(val, jc.JANET_NUMBER) != 0) {
        return clay.Padding.all(floatToU16(jc.janet_unwrap_number(val)));
    }

    // Tuple: [top/bottom left/right] or [top right bottom left]
    const items = janetIndexedSlice(val) orelse return .{};
    if (items.len == 2) {
        const tb = floatToU16(janetToF64(items[0]) orelse 0);
        const lr = floatToU16(janetToF64(items[1]) orelse 0);
        return clay.Padding.axes(tb, lr);
    } else if (items.len >= 4) {
        return .{
            .top = floatToU16(janetToF64(items[0]) orelse 0),
            .right = floatToU16(janetToF64(items[1]) orelse 0),
            .bottom = floatToU16(janetToF64(items[2]) orelse 0),
            .left = floatToU16(janetToF64(items[3]) orelse 0),
        };
    }

    return .{};
}

fn parseColor(val: jc.Janet) clay.Color {
    const items = janetIndexedSlice(val) orelse return .{ 0, 0, 0, 255 };
    if (items.len < 4) return .{ 0, 0, 0, 255 };
    return .{
        @floatCast(janetToF64(items[0]) orelse 0),
        @floatCast(janetToF64(items[1]) orelse 0),
        @floatCast(janetToF64(items[2]) orelse 0),
        @floatCast(janetToF64(items[3]) orelse 255),
    };
}

fn parseRadius(val: jc.Janet) clay.CornerRadius {
    // Number: all corners
    if (jc.janet_checktype(val, jc.JANET_NUMBER) != 0) {
        return clay.CornerRadius.all(@floatCast(jc.janet_unwrap_number(val)));
    }

    // Tuple: [tl tr bl br]
    const items = janetIndexedSlice(val) orelse return .{};
    if (items.len >= 4) {
        return .{
            .top_left = janetToF32(items[0]) orelse 0,
            .top_right = janetToF32(items[1]) orelse 0,
            .bottom_left = janetToF32(items[2]) orelse 0,
            .bottom_right = janetToF32(items[3]) orelse 0,
        };
    }

    return .{};
}

fn parseBorderWidth(val: jc.Janet) clay.BorderWidth {
    // Number: all sides
    if (jc.janet_checktype(val, jc.JANET_NUMBER) != 0) {
        return clay.BorderWidth.outside(floatToU16(jc.janet_unwrap_number(val)));
    }

    // Tuple: [top right bottom left] (CSS order, same as padding)
    const items = janetIndexedSlice(val) orelse return .{};
    if (items.len >= 4) {
        return .{
            .top = floatToU16(janetToF64(items[0]) orelse 0),
            .right = floatToU16(janetToF64(items[1]) orelse 0),
            .bottom = floatToU16(janetToF64(items[2]) orelse 0),
            .left = floatToU16(janetToF64(items[3]) orelse 0),
        };
    }

    return .{};
}

fn parseAlignX(val: jc.Janet) clay.LayoutAlignmentX {
    if (jc.janet_checktype(val, jc.JANET_KEYWORD) == 0) return .left;
    if (janetKeywordEql(val, kw_left)) return .left;
    if (janetKeywordEql(val, kw_right)) return .right;
    if (janetKeywordEql(val, kw_center)) return .center;
    return .left;
}

fn parseAlignY(val: jc.Janet) clay.LayoutAlignmentY {
    if (jc.janet_checktype(val, jc.JANET_KEYWORD) == 0) return .top;
    if (janetKeywordEql(val, kw_top)) return .top;
    if (janetKeywordEql(val, kw_bottom)) return .bottom;
    if (janetKeywordEql(val, kw_center)) return .center;
    return .top;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn janetIndexedSlice(val: jc.Janet) ?[]const jc.Janet {
    var items: [*c]const jc.Janet = undefined;
    var len: i32 = 0;
    if (jc.janet_indexed_view(val, &items, &len) != 0) {
        if (len > 0) {
            return @as([*]const jc.Janet, @ptrCast(items))[0..@intCast(len)];
        }
        return &[0]jc.Janet{};
    }
    return null;
}

fn janetKeywordEql(a: jc.Janet, b: jc.Janet) bool {
    return jc.janet_equals(a, b) != 0;
}

fn janetToF64(val: jc.Janet) ?f64 {
    if (jc.janet_checktype(val, jc.JANET_NUMBER) != 0) {
        return jc.janet_unwrap_number(val);
    }
    return null;
}

fn janetToF32(val: jc.Janet) ?f32 {
    if (janetToF64(val)) |d| return @floatCast(d);
    return null;
}

/// Safe float-to-u16 conversion for user-controlled Janet numbers.
/// Clamps to [0, maxInt], rounds, handles NaN/Inf.
fn floatToU16(val: f64) u16 {
    if (std.math.isNan(val) or val <= 0) return 0;
    if (val >= @as(f64, std.math.maxInt(u16))) return std.math.maxInt(u16);
    return @intFromFloat(@round(val));
}

fn janetToString(val: jc.Janet) []const u8 {
    // If it's already a string, use it directly
    if (jc.janet_checktype(val, jc.JANET_STRING) != 0) {
        const s = jc.janet_unwrap_string(val);
        const len: usize = @intCast(jc.janet_string_length(s));
        return s[0..len];
    }
    // Otherwise coerce to string via janet_to_string.
    // Root it so it survives until Clay's endLayout reads it.
    const s = jc.janet_to_string(val);
    const len: usize = @intCast(jc.janet_string_length(s));
    if (coerced_count < MAX_COERCED_STRINGS) {
        const wrapped = jc.janet_wrap_string(s);
        jc.janet_gcroot(wrapped);
        coerced_roots[coerced_count] = wrapped;
        coerced_count += 1;
    } else {
        log.warn("too many coerced :text strings ({d}), GC may collect", .{MAX_COERCED_STRINGS});
    }
    return s[0..len];
}
