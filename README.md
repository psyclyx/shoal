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
declares at least one surface. Run one with:

```sh
shoal run path/to/script.janet [args...]
shoal run path/to/dir [args...]      # loads every *.janet inside, alphabetically
```

Args after the path are exposed as `script-args`. Three examples
ship in `src/lib/example/`:

| Script | Description |
|--------|-------------|
| `bar.janet` | Status bar with workspaces, title, minimap, CPU/mem/disk/net/audio/battery, clock. Takes `sway` or `tidepool` as the first script-arg. |
| `dmenu.janet` | Fuzzy picker — reads items from stdin, writes selection to stdout, exits. `printf 'a\nb' \| shoal run dmenu.janet '> '` |
| `minimal.janet` | Smallest possible config — just a clock. |

Other subcommands:

```sh
shoal list                  # list running shoal instances
shoal signal <inst> <name>  # send an event to a running instance
```

A script with no surfaces (or one whose surfaces are all destroyed)
exits naturally once its event queue drains — no `{:exit 0}` needed
for one-shot pickers.

## Surfaces

Every layer-shell surface is declared with `reg-surface`:

```janet
(reg-surface :name
  {:layer :top                 # :background :bottom :top :overlay
   :anchor {:bottom true       # any subset of {:top :bottom :left :right}
            :left true :right true}
   :height 0                   # 0 = auto-size to content
   :exclusive-zone 38
   :margin {:top 0 :right 0 :bottom 0 :left 0}
   :keyboard-interactivity :none  # :none :exclusive :on-demand
   :input-region :default      # :default or :empty (click-through)
   :namespace "shoal"
   :per-output false           # true = one instance per wl_output
   :lazy false}                # true = register view, don't auto-create
  view-fn)
```

`:per-output true` is the bar pattern — one instance per monitor.
The default is single-instance, which the compositor places on the
focused output (good for OSDs, launchers, pickers).

`:lazy true` registers the view function without creating a surface.
Use it for transient overlays that pop up via `{:surface :create ...}`
fx and for `:render-to-shm` views that have no wayland surface.

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

## User Configuration

When invoked without an explicit script path, `shoal run` auto-loads
`~/.config/shoal/*.janet` alphabetically. Drop in your own scripts to
compose modules however you like:

```
~/.config/shoal/
  10-sway.janet     # or tidepool, or your own compositor glue
  20-clock.janet
  30-sysinfo.janet
  90-bar.janet      # your custom bar with reg-surface
```

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
