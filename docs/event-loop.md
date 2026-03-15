# Event Loop & Reactive Pipeline Design

Phase 2 of the shoal rearchitecture. This doc covers event dispatch, handler
registration, cofx injection, and fx execution.

---

## Overview

The reactive loop has four phases per event:

```
1. EVENT arrives (Zig → Janet)
2. HANDLE: cofx injected, handler runs, returns fx map
3. EXECUTE: Zig processes fx map (db, anim, render, ipc, spawn, timer, surface)
4. RENDER (if flagged): subs recompute → view fn → hiccup → Clay → GL
```

Janet runs at **event rate** (user actions, IPC messages, timer fires). Zig runs
at **frame rate** (animation interpolation, GL draw). Janet never runs per-frame.

---

## Events

An event is a Janet tuple: `[:keyword & args]`.

```janet
[:init]
[:tick]
[:tidepool/tags {:tag 1 :active true}]
[:timer/fired :poll-cpu]
[:pointer/enter {:x 100 :y 20}]
[:key/press {:key "q" :mods [:ctrl]}]
```

The first element is always a keyword identifying the event type. Remaining
elements are the payload. Handlers are registered by event-id (the keyword).

### Event Queue

Lives in **Zig**. Sources:
- Wayland protocol events (output added/removed, pointer, keyboard)
- IPC messages (tidepool socket)
- Timer fires
- Spawn stdout/stderr lines
- Animation completion callbacks
- Internal (`:init`, `:shutdown`)

Zig accumulates events. Processing happens at two points:
1. **After Wayland dispatch** — process all queued events
2. **On animation tick** — if animations are active, inject `:anim-tick` cofx
   (no event needed; the frame loop checks if subs are dirty)

Events are processed in order. One handler per event-id. If no handler is
registered for an event, it is silently dropped (logged at debug level).

---

## Handlers

A handler is a pure function: `(cofx, event) → fx-map`.

```janet
(reg-event-handler
  :tidepool/tags
  (fn [cofx [_ tags]]
    (let [db (cofx :db)]
      {:db (put db :tags tags)
       :render true})))
```

Handlers receive:
- `cofx` — a table of all available coeffects (inputs)
- `event` — the full event tuple

Handlers return:
- An fx map (table of effect-id → value), or `nil` for no effects

Handlers must be **pure**. All inputs come through cofx, all outputs go through
fx. No global state, no I/O, no Janet `os/` calls.

### Registration

```janet
(reg-event-handler event-id handler-fn)
```

Stored in a Janet table: `{:event-id handler-fn}`. One handler per event-id.
Re-registering replaces the previous handler.

---

## Coeffects (cofx)

Cofx are **all inputs** to a handler. Before a handler runs, Zig builds the cofx
table by calling registered cofx injectors.

### Built-in cofx (always present)

| Key | Type | Description |
|-----|------|-------------|
| `:db` | table | The application state |
| `:now` | number | Current monotonic time (seconds, f64) |
| `:event` | tuple | The event being handled (convenience) |

### Registered cofx (injected on demand)

```janet
(reg-cofx :surface-dims
  (fn [cofx]
    (put cofx :surface-dims (get-surface-dims))))
```

Handlers declare which additional cofx they need:

```janet
(reg-event-handler
  :click
  [:cofx :surface-dims :pointer]  ;; cofx declaration
  (fn [cofx [_ button]]
    ...))
```

The second argument can be a vector of extra cofx keys to inject. If omitted,
only built-in cofx are provided.

### Implementation

cofx injectors are Janet functions stored in a table: `{:cofx-id injector-fn}`.
Zig calls each declared injector before invoking the handler.

Some cofx are **Zig-native** — their injector is a C function registered into
Janet. Examples: `:surface-dims`, `:pointer` (read from Zig state). Others are
pure Janet (`:now` calls `os/clock`... actually no, `:now` should come from Zig
monotonic clock for consistency).

All built-in cofx are Zig-native:
- `:db` — Zig holds a reference to the Janet db table
- `:now` — `std.time.Timer` / monotonic clock
- `:event` — the current event tuple

---

## Effects (fx)

Effects are **all outputs** from a handler. The fx map returned by a handler is
processed by Zig, which calls the appropriate effect executor for each key.

### Built-in effects

| Key | Value | Description |
|-----|-------|-------------|
| `:db` | table | Replace application state |
| `:render` | bool/truthy | Flag: recompute subs + view, produce hiccup |
| `:anim` | table/tuple | Queue or retarget a tween |
| `:dispatch` | tuple | Dispatch another event (async, queued) |
| `:dispatch-n` | array of tuples | Dispatch multiple events |
| `:ipc` | table | Send message on a socket |
| `:spawn` | table | Run a command, route output as events |
| `:timer` | table | Schedule a future event |
| `:surface` | table | Create/destroy/configure layer-shell surface |

### Effect execution order

Effects execute in a **defined order** to avoid surprises:

1. `:db` — state update (everything else may depend on new state)
2. `:anim` — queue tweens (may affect render)
3. `:dispatch-n`, `:dispatch` — queue follow-up events (processed next cycle)
4. `:timer` — schedule future events
5. `:spawn` — launch processes
6. `:ipc` — send messages
7. `:surface` — surface management
8. `:render` — always last (uses final state)

### Registration

Built-in effects are Zig-native. User-defined effects:

```janet
(reg-fx :my-effect
  (fn [val]
    ...))
```

Stored in a table: `{:fx-id executor-fn}`. Unknown fx keys are errors (logged,
not fatal).

---

## The Dispatch Cycle (Zig side)

```
fn processEvents(queue: *EventQueue) void {
    while (queue.pop()) |event| {
        // 1. Build cofx table
        var cofx = buildCofx(event);

        // 2. Look up handler
        var handler = lookupHandler(event[0]);
        if (handler == null) continue;

        // 3. Inject declared cofx
        injectCofx(&cofx, handler.cofx_keys);

        // 4. Call handler (Janet)
        var fx_map = callHandler(handler.fn, cofx, event);

        // 5. Execute effects in order
        executeFx(fx_map);
    }

    // 6. If render flagged, recompute subs + view
    if (render_dirty) {
        var hiccup = recomputeView();
        walkHiccup(hiccup);  // → Clay → GL
    }
}
```

Key detail: **render is deferred to after all events are processed.** Multiple
events in one batch that each set `:render true` result in one render pass. This
is critical for performance — we don't want to re-render per event when 10
events arrive in one Wayland dispatch cycle.

---

## The db

The db is a single Janet table. It is the canonical application state. Handlers
read it from cofx and write it via the `:db` fx.

```janet
# Example db shape (not prescribed — user-defined)
@{:tags @{1 true 2 false 3 true}
  :active-tag 1
  :title "Firefox"
  :layout :tile
  :cpu-percent 23.5
  :volume 75
  :muted false}
```

Zig holds a GC root to the db table so it survives between event cycles.

---

## Zig↔Janet Boundary

### Zig calls Janet

- `dispatch(event)` — push event tuple, process
- `callHandler(handler, cofx, event)` — invoke handler fn, get fx map
- `callSub(sub-fn, cofx)` — invoke subscription fn
- `callView(view-fn, sub-data)` — invoke view fn, get hiccup

All Janet calls happen inside `janet_pcall` (protected call). Errors are caught,
logged, and the event/sub/view is skipped. The system continues with last-known-
good state.

### Janet calls Zig

Via C functions registered as Janet abstractions:

- `(get-surface-dims)` — cofx injector for surface geometry
- `(get-pointer-pos)` — cofx injector for pointer state
- `(get-anim-value key)` — read current interpolated animation value

These are registered during VM init with `janet_def` / `janet_cfuns`.

---

## What This Doesn't Cover Yet

- **Subscriptions** — Phase 3. Memoized derivations from db + other cofx.
- **Hiccup → Clay walker** — Phase 4. The `:render` fx just flags; the actual
  hiccup→GL pipeline is a separate design.
- **Animation cofx/fx details** — Phase 5. How tween specs look, how `:anim`
  cofx exposes interpolated values.
- **Error recovery specifics** — What "last-known-good state" means exactly.
  Needs definition during implementation.

---

## Implementation Plan

### Step 1: Janet-side registration API

Create `src/shoal.janet` (or embed as string) with:
- `reg-event-handler`
- `reg-cofx`
- `reg-fx`
- Internal tables for handler/cofx/fx registries

### Step 2: Zig dispatch skeleton

Extend `src/janet.zig` with:
- `registerCFunctions()` — register Zig-native cofx injectors and fx executors
- `dispatch(event)` — the main entry point
- `buildCofx()` / `injectCofx()` — cofx table construction
- `executeFx()` — walk fx map, call executors in order
- GC root for the db table

### Step 3: Minimal working loop

Wire into `main.zig`:
- On init: load Janet boot file, dispatch `:init` event
- On frame: if render dirty, call view fn (stub: return nil)
- On shutdown: dispatch `:shutdown`

Start with just `:db` cofx and `:db` + `:render` fx. Prove the cycle works with
a trivial handler that increments a counter.

### Step 4: Timer fx

Implement `:timer` so we can test periodic events without Wayland input. Timer
fires → dispatch event → handler updates db → render flagged.

---

## Open Questions

1. **Should the db be a Janet table or a Zig-managed persistent data structure?**
   Janet table for now. Persistent/structural-sharing can come later if needed
   for undo or time-travel debugging. YAGNI.

2. **Should cofx injection be opt-in (handler declares needs) or always-inject?**
   Opt-in for expensive cofx (surface dims requires Wayland roundtrip?). Built-in
   cofx (db, now, event) are always injected. Start with always-inject for all
   built-in, opt-in for registered.

3. **How does the frame loop interact with event processing?**
   Two triggers for work: (a) Wayland events → process event queue, (b) frame
   callback → tick animations, check if subs dirty, re-render if needed. These
   are NOT concurrent — both happen on the main thread, sequentially.
