# Pointer Events

Design for making the bar interactive: Wayland pointer → Clay hit testing →
Janet click/hover events.

## Overview

The bar needs to respond to pointer clicks (e.g., clicking a tag to switch
workspaces). The pipeline:

```
wl_seat → wl_pointer → motion/button events
    → track pointer position + button state (Zig)
    → Clay.setPointerState(pos, pressed) before each layout pass
    → Clay.getPointerOverIds() after layout pass
    → compare with previous frame → emit Janet events for changes
    → Janet handlers dispatch actions (e.g., :tp/focus-tag)
```

## Wayland Side

### Binding wl_seat

`wl_seat` was removed in Session 22 (unused). Re-add it to the registry
listener. Bind `wl_seat` → call `seat.getPointer()` → set pointer listener.

### Pointer State Tracking

Track in module-level state (like `surfaces`, `running`, etc.):

```zig
var pointer: ?*wl.Pointer = null;
var pointer_x: f32 = 0;    // surface-local coordinates
var pointer_y: f32 = 0;
var pointer_surface: ?*wl.Surface = null;  // which surface the pointer is on
var pointer_button_pressed: bool = false;
var pointer_button_just_pressed: bool = false;
var pointer_button_just_released: bool = false;
```

### Pointer Listener Events

- **`enter`**: pointer entered a surface. Store `pointer_surface`, update
  position from `surface_x`/`surface_y` (Fixed → f32 via `toDouble`).
- **`leave`**: pointer left a surface. Clear `pointer_surface`. Set position
  to off-screen (-1, -1).
- **`motion`**: update `pointer_x`, `pointer_y`. Mark surface dirty (hover
  state may change).
- **`button`**: update pressed state. On press → `pointer_button_just_pressed`.
  On release → `pointer_button_just_released`. Mark surface dirty.
- **`frame`**: Wayland guarantees atomicity within a frame event. Process the
  accumulated state. Mark surface dirty if any pointer state changed.

### Fixed-Point Conversion

Wayland coordinates are `wl_fixed_t` (24.8 fixed-point). Convert:
```zig
const x: f32 = @floatCast(surface_x.toDouble());
```

## Clay Integration

### Before Layout

Already exists: `Layout.setPointerState(position, pressed)`. Call this in
`renderSurface` before `beginLayout`, passing current pointer position and
button state.

Only set pointer position for the surface the pointer is actually on. Other
surfaces get (-1, -1) / released.

### After Layout: Hit Testing

After `layout.endLayout()` (which processes render commands), query Clay for
which elements the pointer is over:

```zig
const hovered_ids = clay.getPointerOverIds();
```

This returns a slice of `ElementId`s. Compare with previous frame to detect
enter/leave transitions.

### Element IDs

Hiccup elements with `:id "name"` already get Clay `ElementId`s. For
click-interactive elements, the Janet view must provide an `:id`:

```janet
[:row {:id "tag-3" :w 22 :h 22 ...}
  [:text {:color bg :size 13} "3"]]
```

The `:id` string is what flows through the event system.

## Event Flow

### Click Events

After `endLayout`, if `pointer_button_just_released` is true and there are
hovered elements:

1. Get `clay.getPointerOverIds()`
2. For each hovered element ID, enqueue `[:click "element-id"]`
3. Clear `pointer_button_just_released`

**Released, not pressed**: click = press then release while still over the
element. This matches standard UI convention (allows press-drag-away to cancel).

### Hover Events (deferred)

Hover state changes (enter/leave per element) are useful for visual feedback
(highlight on hover) but add complexity. **Defer to a future session.** The
initial implementation only needs click events for tag switching.

If needed later: track `prev_hovered_ids`, diff with current frame, enqueue
`:hover-enter` / `:hover-leave` events.

## Janet Side

### Click Handler Registration

Bar elements register click handlers by element ID:

```janet
(reg-event-handler :click
  (fn [cofx event]
    (def id (get event 1))
    (cond
      (string/has-prefix? "tag-" id)
      (let [tag (scan-number (string/slice id 4))]
        {:dispatch [:tp/focus-tag tag]})

      # other clickable elements...
      {})))
```

### Bar View Changes

`tag-view` needs `:id` attributes:

```janet
(defn- tag-view [idx tag]
  (if (tag :focused)
    [:row {:id (string "tag-" idx) :w 22 :h 22 :bg accent :radius 5
           :align-x :center :align-y :center}
      [:text {:color bg :size 13} (string idx)]]
    [:row {:id (string "tag-" idx) :w 22 :h 22 :radius 5
           :align-x :center :align-y :center}
      [:text {:color text-color :size 13} (string idx)]]))
```

## Implementation Plan

### Step 1: Wayland Pointer Binding
- Re-add `wl_seat` to registry listener
- `seat.getPointer()` → set pointer listener
- Track position + button state in module-level vars
- Pointer listener: enter/leave/motion/button/frame events

### Step 2: Wire into Render Path
- Call `Layout.setPointerState()` in `renderSurface` before `beginLayout`
- After `endLayout`, check `pointer_button_just_released`
- If released over elements with IDs, enqueue `[:click "id"]` events
- Clear one-shot flags after processing

### Step 3: Janet Click Handlers
- Add `:click` handler in `bar.janet` that pattern-matches on element IDs
- Add `:id` attributes to clickable elements (tags, layout indicator)
- Wire tag clicks to `:tp/focus-tag`

## Key Decisions

1. **Click = release, not press.** Standard UI convention. Press-drag-away
   cancels.
2. **Element IDs are strings.** Janet views set `:id "name"` in hiccup attrs.
   These flow through Clay and back as strings in `:click` events.
3. **No hover events initially.** Click-to-act is sufficient for v1. Hover
   feedback is a visual polish concern for later.
4. **Per-surface pointer tracking.** Only the surface the pointer is on gets
   valid coordinates. Others get off-screen position.
5. **One-shot flags cleared in render path.** `just_pressed` / `just_released`
   are set by Wayland events and cleared after the render pass processes them.
   This ensures exactly one click event per physical click.
