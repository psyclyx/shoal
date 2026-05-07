{ pkgs ? import (import ./npins).nixpkgs {} }:

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
