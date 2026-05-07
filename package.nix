{
  lib,
  stdenv,
  callPackage,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libGL,
  harfbuzz,
  libxkbcommon,
  janet,
  zig_0_16,
  snail-src ? (import ./npins).snail,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "shoal";
  version = "0.1.0";

  src = ./.;

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_16.hook
  ];

  buildInputs = [
    wayland
    wayland-protocols
    libGL
    harfbuzz
    libxkbcommon
    janet
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "--fork=${snail-src}"
  ];

  postInstall = ''
    mkdir -p $out/share/shoal
    cp -r $src/src/lib $out/share/shoal/lib
  '';

  meta = {
    description = "Wayland surface renderer and desktop shell toolkit";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "shoal";
  };
})
