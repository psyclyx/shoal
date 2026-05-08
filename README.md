# Shoal

Wayland layer-shell toolkit for building desktop shell surfaces — status bars,
launchers, OSD overlays, and more.

## Architecture

```
src/
  main.zig                  Wayland event loop + EGL entry point
  engine/                   Zig rendering engine (GL, text, layout, Janet VM)
  lib/
    core/framework.janet    reg-event-handler, reg-sub, reg-view, theme, db
    drawing/                Hiccup helpers (sections, sparklines, minimap)
    stdlib/                 Color and layout utilities
    compositor/             Compositor integrations (tidepool, sway)
    module/                 Reusable data sources and overlays
    example/                Runnable scripts (bar, minimal)
```

**Engine** handles Wayland surfaces, EGL/OpenGL ES rendering, text layout
(FreeType/HarfBuzz/fontconfig), and hosts the Janet VM with a reactive event
dispatch system.

**Framework** provides the `reg-*` API — event handlers, subscriptions,
effects, views — and the `theme` lookup. Pure Janet, always loaded.

**Modules** are compositor-agnostic. They consume the `wm/*` subscription
interface for workspace state, window info, and compositor actions, so
swapping the compositor integration leaves everything else intact.

**Compositors** each populate the same `wm/*` interface:

| Integration | Protocol | Status |
|-------------|----------|--------|
| `tidepool.janet` | netrepl IPC | Complete |
| `sway.janet` | swaymsg + JSON events | Base implementation |

See [docs/architecture.md](docs/architecture.md) for the full design.

## Scripts

A shoal script is a Janet file that `(use ...)`s the modules it needs and
registers at least one view. Run one with:

```sh
shoal run path/to/script.janet [args...]
```

Args after the script path are exposed as `script-args` inside the script.
Two examples ship in `src/lib/example/`:

| Script | Description |
|--------|-------------|
| `bar.janet` | Status bar with workspaces, title, minimap, CPU/mem/disk/net/audio/battery, clock. Takes `sway` or `tidepool` as `script-args`. |
| `minimal.janet` | Smallest possible config — just a clock. |

Other subcommands:

```sh
shoal list                  # list running shoal instances
shoal signal <inst> <name>  # send an event to a running instance
```

## Modules

All modules use the generic `wm/*` interface and work with any compositor
integration that implements it.

| Module | Description |
|--------|-------------|
| `clock.janet` | Clock data source (1s timer) |
| `sysinfo.janet` | CPU/memory/disk/network/battery/audio polling (/proc, /sys, pactl) |
| `launcher.janet` | Universal command palette — apps, windows, tags, compositor actions, eval |
| `osd.janet` | Volume/brightness on-screen display |
| `decorator.janet` | Window decoration renderer (tidepool) |
| `dmenu.janet` | dmenu-compatible stdin/stdout picker (`shoal run --dmenu ...`) |

## User Configuration

When invoked without an explicit script path, `shoal run` auto-loads
`~/.config/shoal/*.janet` alphabetically. Drop in your own scripts to
compose modules however you like:

```
~/.config/shoal/
  10-sway.janet     # or tidepool, or your own compositor glue
  20-clock.janet
  30-sysinfo.janet
  90-bar.janet      # your custom bar view
```

Surface and theme config go in `~/.config/shoal/config.json`:

```json
{
  "surfaces": [{
    "layer": "top",
    "height": 36,
    "exclusive_zone": 40,
    "anchor": {"top": true, "left": true, "right": true}
  }],
  "theme": {
    "bg":   [11, 4, 0, 255],
    "text": [184, 172, 154, 255]
  }
}
```

Theme keys map to `(theme :key)` in Janet.

## Building

Requires Zig 0.16 and system libraries: wayland, EGL, GLESv2, freetype2,
harfbuzz, fontconfig, xkbcommon, janet.

```sh
zig build
zig build run -- run src/lib/example/bar.janet
```

### Nix

```sh
nix-build
```

A home-manager module is available at `nix/hm-module.nix` with stylix
integration — themes flow into `config.json` automatically.

## The `wm/*` Interface

The contract between compositor integrations and modules:

**Subscriptions** (compositor → modules):
`:wm/tags`, `:wm/layout`, `:wm/title`, `:wm/app-id`, `:wm/windows`,
`:wm/outputs`, `:wm/connected`, `:wm/signal`

**Actions** (modules → compositor):
`:wm/focus-tag`, `:wm/toggle-tag`, `:wm/set-tag`, `:wm/set-layout`,
`:wm/cycle-layout`, `:wm/focus`, `:wm/close`, `:wm/zoom`,
`:wm/fullscreen`, `:wm/float`, `:wm/dispatch-action`,
`:wm/focus-window`, `:wm/query-actions`, `:wm/eval`

To add support for a new compositor, create a Janet file that:
1. Connects to the compositor's IPC
2. Populates `:wm` state in the db
3. Registers `wm/*` action handlers
4. Registers `wm/*` subscriptions

## License

GPL-3.0
