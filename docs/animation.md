# Animation as cofx/fx

Phase 5 of the shoal rearchitecture. Surfaces the existing Zig animation engine
to Janet via the reactive pipeline.

---

## Core Insight

Janet runs at **event rate**. Zig runs at **frame rate**. Animation
interpolation happens in Zig — Janet never touches per-frame math. Janet's role
is to declare intent ("animate this value to that target over this duration")
and read results ("what's the current value?").

This maps cleanly to the fx/cofx split:
- **`:anim` fx** — handler output. "Start/retarget/cancel this animation."
- **`(anim :id)` reader** — view-time call. "What's the interpolated value now?"

---

## Animation Pool

Zig maintains a fixed-size pool of named animation slots:

```
MAX_ANIMS = 64

AnimSlot:
  active:   bool
  id:       Janet keyword (GC-rooted when active)
  current:  f64
  target:   f64
  start:    f64
  progress: f32
  duration: f32
  easing:   Easing
  on_complete: Janet tuple or nil (GC-rooted when active)
```

All animated values are **scalar f64**. No vectors, no structs. If you need to
animate a color, use four animations (`:bg-r`, `:bg-g`, `:bg-b`, `:bg-a`) or
more likely: animate one opacity value and compose it in the view. Scalar is
simpler, more composable, and avoids type complexity at the Zig↔Janet boundary.

Why not reuse `Animated(T)`? It's comptime-generic — great for Zig code that
knows types at compile time, wrong for a runtime-dynamic pool where Janet
decides what to animate. The pool uses the same math (lerp, easing) but stores
everything as f64.

---

## `:anim` fx — Declaring Animations

Returned from handlers as part of the fx map.

### Single animation

```janet
{:anim {:id :panel-x
        :to 200
        :duration 0.3
        :easing :ease-out-cubic}}
```

### Multiple animations

```janet
{:anim [{:id :panel-x :to 200 :duration 0.3 :easing :ease-out-cubic}
        {:id :panel-opacity :to 1.0 :duration 0.2}]}
```

### Immediate set (no transition)

```janet
{:anim {:id :panel-x :to 200}}
```

Duration omitted or 0 → set immediately, no interpolation.

### Cancel

```janet
{:anim {:id :panel-x :cancel true}}
```

Stops the animation at its current value.

### Spec fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `:id` | keyword | yes | — | Animation identifier |
| `:to` | number | yes* | — | Target value (*not needed for `:cancel`) |
| `:duration` | number | no | 0 | Seconds. 0 = immediate |
| `:easing` | keyword | no | `:linear` | Easing function name |
| `:from` | number | no | current | Explicit start value |
| `:on-complete` | tuple | no | nil | Event to dispatch when done |

### Easing keywords

`:linear`, `:ease-in-quad`, `:ease-out-quad`, `:ease-in-out-quad`,
`:ease-out-cubic`, `:ease-in-out-cubic`

Maps directly to the existing `Easing` enum.

---

## `(anim :id)` — Reading Animated Values

A Zig C function registered into Janet. Called from view functions to read the
current interpolated value of a named animation.

```janet
(reg-view
  (fn []
    [:row {:w :grow :h :grow
           :bg [30 30 46 (anim :panel-opacity)]}
      [:col {:w (anim :panel-width)}
        [:text {:color [205 214 244 255]} "panel"]]]))
```

Behavior:
- Returns the current `f64` value if the animation exists (active or at rest)
- Returns `0.0` if no animation with that id has ever been created
- No-id → error logged, returns 0

This is analogous to `(sub :id)` — a read function available during view
evaluation. Not pure in the strict FP sense, but practically pure: the value
only changes between frames, never during a single view evaluation.

### Why not a cofx?

Animation values change every frame. If they were cofx, every handler would need
to declare which animations it reads. But handlers rarely need animation values
— they operate on logical state ("is the panel open?"), not interpolated
positions. Views need them. Making `(anim :id)` a direct read from Zig is
simpler and matches the actual data flow.

If a handler does need an animation value (rare), it can be added as an
opt-in cofx injector later: `(reg-cofx :anim-values ...)`. Not needed now.

---

## Retargeting

When an `:anim` fx targets an `:id` that's already animating:

1. `start` ← current interpolated value (not the old target)
2. `target` ← new target
3. `progress` ← 0.0
4. `duration` ← new duration
5. `easing` ← new easing

This gives smooth retargeting — the value continues from where it is, not from
where it was going. Same behavior as `Animated(T).setTarget()`.

If `:from` is explicitly provided, it overrides the current value as start.

---

## Completion Events

When an animation finishes (progress reaches 1.0) and has an `:on-complete`
event tuple, that event is enqueued. This enables:

```janet
;; Slide panel out, then remove it from db
(reg-event-handler :close-panel
  (fn [cofx _]
    {:anim {:id :panel-x :to -300 :duration 0.3
            :on-complete [:panel-closed]}}))

(reg-event-handler :panel-closed
  (fn [cofx _]
    {:db (put (cofx :db) :panel-visible false)
     :render true}))
```

Completion events fire once. If an animation is retargeted before completing,
the old on-complete is discarded.

---

## Frame Loop Integration

The frame loop already has `FrameClock.tick()` producing `dt`. The animation
pool hooks into the same place:

```
frame callback fires:
  dt = frame_clock.tick()
  any_active = tickAnimations(dt)   // ← new
  if any_active:
    mark render dirty
    request next frame
```

`tickAnimations(dt: f32) -> bool`:
- Iterates all active slots
- Updates progress: `progress += dt / duration`
- If progress >= 1.0: set current = target, active = false, enqueue on-complete
- Else: apply easing, lerp between start and target
- Returns true if any slot was active (→ need another frame)

When animations are active, the frame loop keeps requesting frames. When all
animations settle, frame requests stop (Wayland idle, no CPU burn).

---

## Render Triggering

Animations do NOT use `:render true` in the fx map. The `:anim` fx just
creates/retargets slots. The frame loop handles render triggering:

1. Handler returns `{:anim {...}}` — slot created/retargeted
2. Next frame tick: `tickAnimations` returns true (active animations)
3. Frame loop marks render dirty
4. `prepareRender()` → view fn → `(anim :id)` reads current values → hiccup
5. Repeat until all animations settle

This avoids redundant renders. If a handler starts an animation AND sets
`:render true`, that's fine — the immediate render shows the first frame, then
the frame loop continues rendering until animations settle.

---

## Implementation Plan

### Step 1: Animation pool in Zig

Add to `Dispatch` (or a new `AnimPool` struct used by Dispatch):
- `AnimSlot` array (64 slots)
- `tickAnimations(dt) -> bool`
- `getAnimValue(id) -> f64`
- `handleAnimFx(val)` — parse `:anim` fx spec(s)
- `freeAnim(slot)` — cleanup GC roots

### Step 2: Wire into frame loop

In main.zig:
- Call `dispatch.tickAnimations(dt)` alongside existing `bg_color.update(dt)`
- If returns true, mark render dirty + request frame
- Process any completion events (`dispatch.processQueue()`)

### Step 3: Register `(anim :id)` in Janet

Register a C function via `janet_cfuns` during boot:
- `(anim :id)` → calls `getAnimValue`, returns f64

### Step 4: Wire into fx execution

In `executeFx`, handle `:anim` key:
- Parse single spec or array of specs
- Create/retarget/cancel slots

### Step 5: End-to-end test

Register a handler that starts an animation on `:init`. View reads `(anim :id)`.
Verify the value changes across frames.

---

## What This Doesn't Cover

- **Spring animations.** The current easing model is duration-based. Springs
  (velocity-based, no fixed duration) are a different model. Could be added
  later as an alternative to easing — same pool, different update math.
- **Animation groups.** No concept of "animate these three things together and
  fire one completion event." Use individual animations with completion on the
  last one. Simple enough for now.
- **Keyframes / sequences.** Chain via completion events. No built-in sequence
  type.
- **Per-surface animations.** All animations are global. Multi-surface support
  may need namespacing (`:surface-1/panel-x`). Cross that bridge later.
