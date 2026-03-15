{
  lib,
  stdenv,
  callPackage,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libGL,
  freetype,
  harfbuzz,
  fontconfig,
  janet,
  zig_0_15,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "shoal";
  version = "0.1.0";

  src = ./.;

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_15
  ];

  buildInputs = [
    wayland
    wayland-protocols
    libGL
    freetype
    harfbuzz
    fontconfig
    janet
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  meta = {
    description = "Wayland surface renderer and desktop shell toolkit";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "shoal";
  };
})
