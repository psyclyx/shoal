# Architecture

Shoal is a Wayland layer-shell toolkit. It provides a reactive UI framework
for building desktop shell surfaces — status bars, launchers, notification
popups, OSD overlays, and anything else that lives on a layer-shell surface.

---

## Source Layout

```
src/
  main.zig              Entry point (Wayland event loop, EGL, surface lifecycle)
  engine/               Zig rendering and runtime engine
  framework/            Janet reactive framework (always loaded)
  modules/              Reusable, compositor-agnostic Janet modules
  compositors/          Compositor integrations (tidepool, sway)
  presets/              Compositions wiring a compositor + modules together
```

---

## Layers

### Engine (`src/engine/` + `src/main.zig`)

Core rendering and Wayland integration. Users never touch this.

| File | Role |
|------|------|
| `main.zig` | Wayland event loop, EGL setup, surface lifecycle, frame callbacks |
| `engine/renderer.zig` | GL batch renderer: SDF rounded rects, textured quads, scissor |
| `engine/text.zig` | FreeType/HarfBuzz/fontconfig text pipeline, glyph atlas |
| `engine/layout.zig` | Clay layout engine integration, render command dispatch |
| `engine/animation.zig` | Generic `Animated(T)` tween system, easing functions |
| `engine/hiccup.zig` | Janet hiccup tree → Clay layout calls |
| `engine/janet.zig` | Janet VM, reactive dispatch loop, timer/anim/spawn/ipc pools |
| `engine/config.zig` | JSON + CLI config loading |
| `engine/spawn.zig` | Child process pool with stdout piping |
| `engine/ipc.zig` | Unix socket pool with line/netrepl framing |
| `engine/jutil.zig` | Janet C FFI helpers |
| `engine/theme.zig` | Base16 theme data structure |

### Framework (`src/framework/`)

The reactive primitives that everything else builds on. Always loaded.

| File | Role |
|------|------|
| `framework/shoal.janet` | Event handler, subscription, cofx, fx registries. The `reg-*` API. |
| `framework/json.janet` | Minimal JSON decoder for IPC message parsing |

### Modules (`src/modules/`)

Reusable, compositor-agnostic data sources and views. Loaded from
`~/.config/shoal/` if present, otherwise from the embedded preset.

| Module | Role |
|--------|------|
| `clock.janet` | Clock data source (1s timer, os/date) |
| `sysinfo.janet` | CPU, memory, battery, disk, network, audio data sources |
| `bar.janet` | Status bar view (workspaces, title, system info) |
| `launcher.janet` | Universal seam: launcher/command palette (apps, windows, tags, actions) |
| `osd.janet` | Volume/brightness on-screen display |
| `dmenu.janet` | dmenu compatibility: stdin/stdout item picker (loaded in `--dmenu` mode) |

Modules consume the `wm/*` subscription interface. They do not depend on any
specific compositor — they work with whichever compositor integration is loaded.

### Compositors (`src/compositors/`)

Each compositor integration populates the standard `wm/*` interface.

| File | Role |
|------|------|
| `tidepool.janet` | IPC client for tidepool WM (netrepl protocol) |
| `sway.janet` | Integration for sway/i3 (swaymsg + JSON events) |

Both register the same set of `wm/*` subscriptions and action handlers:

- **Subscriptions:** `:wm/tags`, `:wm/layout`, `:wm/title`, `:wm/app-id`, `:wm/windows`, `:wm/outputs`, `:wm/connected`, `:wm/signal`
- **Actions:** `:wm/focus-tag`, `:wm/toggle-tag`, `:wm/set-tag`, `:wm/set-layout`, `:wm/cycle-layout`, `:wm/focus`, `:wm/close`, `:wm/zoom`, `:wm/fullscreen`, `:wm/float`, `:wm/dispatch-action`, `:wm/focus-window`, `:wm/query-actions`, `:wm/eval`

### Presets (`src/presets/`)

A preset selects a compositor integration and a set of modules to embed.
The active preset is imported by the engine at compile time.

| File | Compositor | Modules |
|------|-----------|---------|
| `tidepool.zig` | tidepool | clock, sysinfo, bar, launcher, osd |
| `sway.zig` | sway | clock, sysinfo, bar, launcher, osd |

To switch presets, change the import in `src/engine/janet.zig`.

---

## Module Loading

On startup, after the framework loads:

1. If `~/.config/shoal/` contains `.janet` files, they are loaded
   **alphabetically**. No embedded modules load.
2. If the directory is empty or absent, all embedded preset modules load.

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

## The `wm/*` Interface

The `wm/*` namespace is the contract between compositor integrations and
modules. Compositor modules populate state under the `:wm` key in the db
and register handlers for `wm/*` action events.

```
Compositor (tidepool, sway, ...)
  → populates :wm in db (tags, layout, title, windows, outputs)
  → registers wm/* action handlers (focus-tag, close, zoom, ...)
  → dispatches :wm/signal for compositor signals

Modules (bar, launcher, osd, ...)
  → subscribe to wm/* for display
  → dispatch wm/* actions on user interaction
  → react to :wm/signal events
```

This decoupling means you can swap compositor integrations without changing
any module code.

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

When `modules` is empty (the default), embedded preset defaults are used.
