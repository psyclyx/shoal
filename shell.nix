{ pkgs ? import (import ./npins).nixpkgs {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    pkg-config
    wayland-scanner
    zig_0_15
  ];

  buildInputs = with pkgs; [
    wayland
    wayland-protocols
    libGL
    freetype
    harfbuzz
    fontconfig
    janet
  ];
}
