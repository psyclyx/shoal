# Architecture

Shoal is a Wayland layer-shell toolkit. It provides a reactive UI framework
for building desktop shell surfaces — status bars, launchers, notification
popups, OSD overlays, and anything else that lives on a layer-shell surface.

---

## Layers

The codebase has three distinct layers:

### Engine (Zig — always embedded, not overridable)

Core rendering and Wayland integration. Users never touch this.

| File | Role |
|------|------|
| `main.zig` | Wayland event loop, EGL setup, surface lifecycle, frame callbacks |
| `renderer.zig` | GL batch renderer: SDF rounded rects, textured quads, scissor |
| `text.zig` | FreeType/HarfBuzz/fontconfig text pipeline, glyph atlas |
| `layout.zig` | Clay layout engine integration, render command dispatch |
| `animation.zig` | Generic `Animated(T)` tween system, easing functions |
| `hiccup.zig` | Janet hiccup tree → Clay layout calls |
| `janet.zig` | Janet VM, reactive dispatch loop, timer/anim/spawn/ipc pools |
| `config.zig` | JSON + CLI config loading |
| `spawn.zig` | Child process pool with stdout piping |
| `ipc.zig` | Unix socket pool with line/netrepl framing |

### Framework (Janet — always embedded, not overridable)

The reactive primitives that everything else builds on.

| File | Role |
|------|------|
| `shoal.janet` | Event handler, subscription, cofx, fx registries. The `reg-*` API. |
| `json.janet` | Minimal JSON decoder for IPC message parsing |

### Modules (Janet — user-overridable)

Data sources, views, and user logic. Loaded from `~/.config/shoal/` if present,
otherwise from embedded defaults.

| Embedded default | Role |
|------------------|------|
| `tidepool.janet` | IPC client for tidepool WM (tags, layout, title, windows, signals) |
| `clock.janet` | Clock data source (1s timer, os/date) |
| `sysinfo.janet` | CPU, memory, battery, disk, network data sources |
| `bar.janet` | Status bar view (workspaces, title, system info modules) |
| `launcher.janet` | Universal seam: launcher/command palette (apps, windows, tags, actions) |
| `osd.janet` | Volume/brightness on-screen display (triggered by tidepool signals) |
| `dmenu.janet` | dmenu compatibility: stdin/stdout item picker (loaded in `--dmenu` mode) |

---

## Module Loading

On startup, after the framework loads:

1. If `~/.config/shoal/` contains `.janet` files, they are loaded
   **alphabetically**. No embedded modules load.
2. If the directory is empty or absent, all embedded defaults load.

This is all-or-nothing by design. When you provide modules, you have full
control. Use numeric prefixes to control load order:

```
~/.config/shoal/
  10-tidepool.janet   # compositor IPC (copy from embedded or write your own)
  20-clock.janet      # clock data source
  30-sysinfo.janet    # system info data sources
  90-bar.janet        # your custom bar view
```

Every module is just a Janet file that calls `reg-event-handler`, `reg-sub`,
and/or `reg-view`. There is no distinction between "data sources" and "views" —
they're all modules.

---

## Data Flow

```
Events (Wayland, IPC, timers, spawns)
  → Event queue (Zig)
    → Handler dispatch (Janet)
      → cofx injection → handler fn → fx map
        → Effect execution (Zig)
          → db update → sub invalidation → view re-render
            → Hiccup tree → Clay layout → GL draw
```

Unidirectional. Events in, pixels out. Handlers are pure functions.
Side effects go through the fx system.

---

## Views

A view is a Janet function that returns a hiccup tree:

```janet
(defn my-view []
  [:row {:w :grow :h :grow :bg (theme :bg)}
    [:text {:color (theme :text) :size 16} (sub :clock/time)]])

(reg-view my-view)
```

Views read state via `(sub :key)` subscriptions. Subscriptions are memoized
and only recompute when their dependencies change.

Named views support multiple surfaces:

```janet
(reg-view my-bar)                    # default view
(reg-view :launcher launcher-view)   # named view for a launcher surface
```

---

## Native Functions

Janet modules can call Zig-provided functions:

| Function | Description |
|----------|-------------|
| `(anim :id)` | Get current interpolated animation value |
| `(disk-usage "/")` | Get filesystem usage via statfs syscall |
| `(desktop-apps)` | Scan XDG data dirs for .desktop files |
| `(theme :key)` | Read theme colors (injected at boot) |

---

## Keyboard Input

Surfaces with keyboard interactivity (`on_demand` or `exclusive`) receive key events
dispatched as Janet events:

```janet
# :key event — sym is the xkb keysym name, text is UTF-8 output
(reg-event-handler :key
  (fn [cofx event]
    (def info (event 1))
    (def sym (info :sym))      # "Return", "a", "Escape", etc.
    (def text (info :text))    # "a", "", etc.
    (def pressed (info :pressed))
    (def ctrl (info :ctrl))
    (def alt (info :alt))
    (def shift (info :shift))
    (def super (info :super))
    ...))

# Focus tracking
(reg-event-handler :keyboard-enter (fn [cofx event] ...))
(reg-event-handler :keyboard-leave (fn [cofx event] ...))
```

---

## Pointer Input

All surfaces receive pointer events. Hover tracking is automatic based on
element `:id` attributes:

```janet
# Hover enter/leave — id is the element's :id string
(reg-event-handler :pointer-enter (fn [cofx event] (def id (event 1)) ...))
(reg-event-handler :pointer-leave (fn [cofx event] (def id (event 1)) ...))

# Click — fired on button release over an element
(reg-event-handler :click (fn [cofx event] (def id (event 1)) ...))

# Scroll — direction is "up" or "down", id is the topmost hovered element
(reg-event-handler :scroll
  (fn [cofx event]
    (def dir (event 1))   # "up" or "down"
    (def id (event 2))    # element id string, or nil
    ...))
```

---

## Dynamic Surfaces

Modules can create and destroy layer-shell surfaces at runtime via the `:surface` effect:

```janet
# Create a surface — renders the :launcher named view
(reg-event-handler :open-launcher
  (fn [cofx event]
    {:surface {:create {:name :launcher
                        :layer :overlay
                        :width 600
                        :height 400
                        :anchor {:top true :left true :right true}
                        :keyboard-interactivity :exclusive}}}))

# Destroy it
(reg-event-handler :close-launcher
  (fn [cofx event]
    {:surface {:destroy :launcher}}))

# Register the view that renders on the launcher surface
(reg-view :launcher (fn [] [:col {:w :grow :h :grow :bg (theme :bg)} ...]))
```

Available surface properties: `:layer`, `:width`, `:height`, `:anchor`,
`:exclusive-zone`, `:margin`, `:keyboard-interactivity`. The `:name` field
is required and determines which named view renders on the surface.

---

## Process Launching

The `:exec` effect launches a process fully detached from shoal (double-fork + setsid):

```janet
# Launch by command string (runs via sh -c)
{:exec {:cmd "firefox"}}

# Launch by argv array
{:exec {:cmd ["alacritty" "--title" "scratch"]}}
```

For commands that produce output piped back to shoal, use `:spawn` instead.

---

## Nix Integration

The home-manager module generates `~/.config/shoal/config.json` from Nix
options and optionally writes Janet modules:

```nix
programs.shoal = {
  enable = true;
  surfaces.bar = {
    layer = "top";
    height = 36;
    exclusive_zone = 40;
    margin = { top = 4; left = 6; right = 6; };
  };
  # Optional: provide custom Janet modules
  modules = {
    "10-data" = ''
      # custom data source
      (reg-event-handler :init (fn [cofx event] ...))
    '';
    "90-bar" = ''
      # custom bar view
      (reg-view (fn [] [:row {:w :grow} ...]))
    '';
  };
};
```

When `modules` is empty (the default), embedded defaults are used.
