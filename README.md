# Shoal

Wayland layer-shell toolkit for building desktop shell surfaces — status bars,
launchers, OSD overlays, and more.

## Architecture

Shoal separates concerns into five layers:

```
src/
  main.zig              Wayland event loop + EGL entry point
  engine/               Zig rendering engine (GL, text, layout, Janet VM)
  framework/            Janet reactive framework (reg-event-handler, reg-sub, reg-view)
  modules/              Compositor-agnostic Janet modules (bar, launcher, OSD, ...)
  compositors/          Compositor integrations (tidepool, sway)
  presets/              Compositions wiring a compositor + modules together
```

**Engine** handles Wayland surfaces, EGL/OpenGL ES rendering, text layout
(FreeType/HarfBuzz/fontconfig), and hosts the Janet VM with a reactive
event dispatch system.

**Framework** provides the `reg-*` API — event handlers, subscriptions,
effects, and views. Pure Janet, always loaded.

**Modules** are compositor-agnostic. They consume the `wm/*` subscription
interface for workspace state, window info, and compositor actions. Swap
the compositor integration and everything keeps working.

**Compositors** each populate the same `wm/*` interface:

| Integration | Protocol | Status |
|-------------|----------|--------|
| `tidepool.janet` | netrepl IPC | Complete |
| `sway.janet` | swaymsg + JSON events | Base implementation |

**Presets** are Zig files that select a compositor + module set at compile time.
`tidepool.zig` bundles tidepool + all modules. `sway.zig` bundles sway + all
modules.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Modules

All modules use the generic `wm/*` interface. They work with any compositor
integration that implements it.

| Module | Description |
|--------|-------------|
| `bar.janet` | Status bar with workspaces, title, CPU/memory/battery/disk/network/audio, clock |
| `launcher.janet` | Universal command palette — apps, windows, tags, compositor actions, commands, eval |
| `osd.janet` | Volume/brightness on-screen display |
| `clock.janet` | Clock data source (1s timer) |
| `sysinfo.janet` | System info polling (/proc, /sys, wpctl) |
| `dmenu.janet` | dmenu-compatible stdin/stdout picker (`--dmenu` mode) |

## User Configuration

Modules load from `~/.config/shoal/*.janet` (alphabetically) when present.
If absent, the embedded preset loads. This is all-or-nothing — provide your
own modules for full control:

```
~/.config/shoal/
  10-sway.janet         # or tidepool, or your own compositor glue
  20-clock.janet
  30-sysinfo.janet
  90-bar.janet          # your custom bar
```

Surface configuration goes in `~/.config/shoal/config.json`:

```json
{
  "surfaces": [{
    "layer": "top",
    "height": 36,
    "exclusive_zone": 40,
    "anchor": {"top": true, "left": true, "right": true}
  }]
}
```

## Building

Requires Zig 0.15 and system libraries: wayland, EGL, GLESv2, freetype2,
harfbuzz, fontconfig, xkbcommon, janet.

```sh
zig build
zig build run
```

### Nix

```sh
nix-build
```

A home-manager module is available at `nix/hm-module.nix` with stylix
integration.

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
