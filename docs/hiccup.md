# Hiccup → Clay Renderer Design

Phase 4 of the shoal rearchitecture. Walk a Janet hiccup tree and produce
Clay layout calls.

---

## Hiccup Format

A hiccup node is a Janet tuple:

```janet
[:tag {:attr val ...} & children]
```

- **Tag** — keyword identifying the element type
- **Attrs** — optional table of attributes (if second element is a table/struct)
- **Children** — remaining elements: nested hiccup nodes or strings

If the second element is not a table/struct, all elements after the tag are
children (no attrs = empty config).

```janet
# With attrs
[:row {:gap 6 :pad 8} [:text {} "hello"]]

# Without attrs (shorthand)
[:col [:text "hello"] [:text "world"]]

# Text with just a string child
[:text {:color [255 255 255 255]} "hello"]
```

---

## Tag Vocabulary

### Container tags

| Tag | Clay direction | Notes |
|-----|---------------|-------|
| `:row` | `left_to_right` | Horizontal flex container |
| `:col` | `top_to_bottom` | Vertical flex container |

These are the only two container tags. No `:box` — a box is just a `:row` or
`:col` with one child. Fewer concepts.

### Leaf tags

| Tag | Clay call | Notes |
|-----|-----------|-------|
| `:text` | `clay.text()` | Text element. Children must be strings. |

### Future tags (not Phase 4)

| Tag | Notes |
|-----|-------|
| `:scroll` | Scrollable container (clip element) |
| `:float` | Floating/overlay element |
| `:image` | Image element |
| `:custom` | Custom render command |

---

## Attribute Mapping

Hiccup attributes (Janet table) → Clay `ElementDeclaration` fields.

### Layout attributes

| Hiccup attr | Type | Clay field | Notes |
|-------------|------|------------|-------|
| `:w` | keyword/number | `layout.sizing.w` | See sizing below |
| `:h` | keyword/number | `layout.sizing.h` | See sizing below |
| `:pad` | number/tuple | `layout.padding` | See padding below |
| `:gap` | number | `layout.child_gap` | Gap between children |
| `:align-x` | keyword | `layout.child_alignment.x` | `:left`, `:right`, `:center` |
| `:align-y` | keyword | `layout.child_alignment.y` | `:top`, `:bottom`, `:center` |

### Sizing values

| Janet value | Clay SizingAxis |
|-------------|-----------------|
| `:grow` | `.grow` |
| `:fit` | `.fit` |
| `100` (number) | `.fixed(100)` |
| `[:percent 0.5]` | `.percent(0.5)` |
| `[:grow 50 200]` | `.growMinMax(.{.min=50, .max=200})` |
| `[:fit 0 100]` | `.fitMinMax(.{.min=0, .max=100})` |

Default: `:fit` (Clay's default).

### Padding values

| Janet value | Clay Padding |
|-------------|-------------|
| `8` (number) | `.all(8)` |
| `[4 8]` (tuple) | `.axes(4, 8)` — [top/bottom, left/right] |
| `[4 8 4 8]` (tuple) | `.{.top=4, .right=8, .bottom=4, .left=8}` |

### Visual attributes

| Hiccup attr | Type | Clay field | Notes |
|-------------|------|------------|-------|
| `:bg` | tuple of 4 numbers | `background_color` | RGBA 0-255 |
| `:radius` | number/tuple | `corner_radius` | See below |
| `:border-color` | tuple of 4 numbers | `border.color` | RGBA 0-255 |
| `:border-width` | number/tuple | `border.width` | See below |
| `:id` | string | `id` | Element ID for queries |

### Corner radius values

| Janet value | Clay CornerRadius |
|-------------|-------------------|
| `8` (number) | `.all(8)` |
| `[8 8 0 0]` (tuple) | `.{.top_left=8, .top_right=8, .bottom_left=0, .bottom_right=0}` |

### Border width values

| Janet value | Clay BorderWidth |
|-------------|-----------------|
| `2` (number) | `.outside(2)` |
| `[2 2 0 0]` (tuple) | `.{.top=2, .right=2, .bottom=0, .left=0}` |

### Text attributes

Only valid on `:text` elements:

| Hiccup attr | Type | Clay TextElementConfig | Notes |
|-------------|------|----------------------|-------|
| `:color` | tuple of 4 numbers | `.color` | Text color RGBA 0-255 |
| `:font` | number | `.font_id` | Font ID from text renderer |
| `:size` | number | `.font_size` | Font size in pixels |
| `:wrap` | keyword | `.wrap_mode` | `:words`, `:newlines`, `:none` |
| `:text-align` | keyword | `.alignment` | `:left`, `:center`, `:right` |

---

## Walker Algorithm

The walker is a Zig function that receives a Janet value (the hiccup tree root)
and emits Clay API calls. It recurses into children.

```
walkHiccup(node: Janet) void:
  if node is a string:
    error — bare strings only valid as text children
    return

  if node is not a tuple:
    return (skip nil, numbers, etc.)

  tag = node[0]  (keyword)
  attrs, children_start = parseAttrs(node)

  if tag == :text:
    walkText(attrs, node[children_start..])
    return

  config = attrsToElementDeclaration(tag, attrs)

  clay.UI()(config)({
    for child in node[children_start..]:
      walkHiccup(child)
  })
```

### Text handling

`:text` is a leaf node. Its children must be strings (or values coerced to
strings). Multiple string children are concatenated.

```
walkText(attrs, children):
  text_content = concatenate all children as strings
  text_config = attrsToTextConfig(attrs)
  clay.text(text_content, text_config)
```

This means views produce:
```janet
[:text {:color [255 255 255 255]} (string "CPU: " (sub :cpu-percent) "%")]
```

The string concatenation happens in Janet (view fn). The walker sees a single
string child.

### The children closure problem

Clay's Zig API uses inline functions and closures:
```zig
clay.UI()(.{config})({
    // children declared here
});
```

The inner `({...})` is actually calling a function returned by the config call.
We can't use this pattern from a recursive walker because the children aren't
known at comptime. Instead, we use the low-level Clay C API directly:

```zig
clay.cdefs.Clay__OpenElement();
clay.cdefs.Clay__ConfigureOpenElement(config);
// walk children recursively
clay.cdefs.Clay__CloseElement();
```

This is exactly what `clay.UI()` does internally. We just do it manually so
we can recurse between open and close.

For text:
```zig
clay.cdefs.Clay__OpenTextElement(string, text_config_ptr);
```

---

## Implementation Plan

### What gets added

**`src/hiccup.zig`** — the walker module:
- `walkHiccup(node: Janet) void` — main entry point
- `walkContainer(tag, attrs, node, children_start) void` — container elements
- `walkText(attrs, node, children_start) void` — text elements
- `parseAttrs(node) -> (attrs: Janet, children_start: usize)` — extract attrs
- `attrsToConfig(tag, attrs) -> ElementDeclaration` — map attrs to Clay config
- `attrsToTextConfig(attrs) -> TextElementConfig` — map attrs to text config
- Attribute parsers: `parseSizing`, `parsePadding`, `parseColor`, `parseRadius`

**`src/janet.zig`** changes:
- `Dispatch.renderView(view_fn: Janet) void` — calls prepareRender, calls view
  fn, walks resulting hiccup through the walker
- Wire into the render-dirty path

**`src/main.zig`** changes:
- When `render_dirty`: call `layout.beginLayout()`, walk hiccup,
  `layout.endLayout()`, swap buffers

### What the render path looks like

```
events processed, render_dirty = true
  ↓
dispatch.prepareRender()           — set *current-db* for subs
  ↓
hiccup = dispatch.callViewFn()     — Janet view fn → hiccup tuple
  ↓
layout.beginLayout()
hiccup.walkHiccup(hiccup)          — hiccup → Clay API calls
layout.endLayout()                 — Clay → render commands → GL
```

### View function registration

The root view function is registered via Janet:

```janet
(reg-view (fn []
  [:row {:w :grow :h :grow :pad 8 :bg [30 30 46 255]}
    [:text {:color [205 214 244 255] :size 14} (sub :title)]]))
```

Zig stores a reference to this function. When render is needed, it calls the
view fn (protected, via fiber) and walks the result.

For Phase 4, we start with `reg-view` storing the function and Zig calling it.
Later, multi-surface support means each surface gets its own view fn.

---

## Example

A complete example of how a bar surface would look:

```janet
# Subscriptions
(reg-sub :tags (fn [db] (db :tags)))
(reg-sub :title (fn [db] (db :title)))
(reg-sub :clock (fn [db] (db :clock)))

# View
(reg-view
  (fn []
    [:row {:w :grow :h :grow :pad [0 8] :bg [30 30 46 255] :radius 8}
      # Left section
      [:row {:w :grow :gap 6 :align-y :center}
        (each-tag (sub :tags))]
      # Center
      [:row {:w :grow :align-x :center :align-y :center}
        [:text {:color [205 214 244 255] :size 14} (sub :title)]]
      # Right
      [:row {:w :grow :gap 6 :align-x :right :align-y :center}
        [:text {:color [205 214 244 255] :size 14} (sub :clock)]]]))

(defn each-tag [tags]
  # Returns a tuple of hiccup nodes — one per tag
  # (This is where Janet's expressiveness shines)
  (seq [t :in (keys tags)]
    [:row {:pad [2 6] :bg (if (tags t) [137 180 250 255] [49 50 68 255])
           :radius 4}
      [:text {:color [205 214 244 255] :size 12} (string t)]]))
```

---

## Edge Cases

1. **nil children** — skip silently. Views may conditionally return nil.
2. **Flat child lists** — if a child is a tuple whose first element is NOT a
   keyword, treat it as a list of hiccup nodes (splice). This handles `(seq ...)`
   and `(map ...)` returning arrays of nodes.
3. **Empty attrs** — `{}` or omitted. All Clay defaults apply.
4. **Unknown attrs** — logged and ignored. Don't crash on typos.
5. **Unknown tags** — logged and ignored. Skip the node.
6. **Deeply nested** — no explicit depth limit. Janet stack depth is the limit.
7. **Text coercion** — `:text` children that aren't strings get `janet_to_string`
   applied. Numbers, keywords, etc. become their string representation.

---

## What's Not Covered

- **Animations** — Phase 5. Animated values in attrs (e.g., bg color tweening).
  For now, attrs are static per render pass.
- **Event handlers on elements** — `:on-click`, `:on-hover`. Needs Clay's
  hover/pointer API wired in. Future phase.
- **Multiple surfaces** — each surface gets its own view fn. Phase 6+.
- **Hot reload** — re-evaluating Janet and re-rendering. Needs cache invalidation.
- **Performance** — walking a Janet tuple tree every render is fine at event rate.
  If it becomes a bottleneck, we can diff hiccup trees and only update changed
  subtrees. YAGNI.
