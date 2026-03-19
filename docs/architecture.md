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
| `tidepool.janet` | IPC client for tidepool WM (tags, layout, title, windows) |
| `clock.janet` | Clock data source (1s timer, os/date) |
| `sysinfo.janet` | CPU, memory, battery, disk, network data sources |
| `bar.janet` | Status bar view (workspaces, title, system info modules) |

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

When `modules` is empty (the default), embedded defaults are used.
