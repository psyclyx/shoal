# Dev shell contents — reached via ../default.nix `shell` (root shell.nix is a
# passthrough), so `pkgs` is default.nix's injected finalPkgs.
{ pkgs }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    pkg-config
    wayland-scanner
    zig_0_16
  ];

  buildInputs = with pkgs; [
    wayland
    wayland-protocols
    libGL
    harfbuzz
    libxkbcommon
    janet
  ];
}
