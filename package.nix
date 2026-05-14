{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
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
    makeWrapper
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

    # The runtime falls back to /usr/share/shoal/lib if SHOAL_LIB is
    # unset, which is wrong on Nix. Pin it to the installed copy.
    wrapProgram $out/bin/shoal \
      --set-default SHOAL_LIB $out/share/shoal/lib
  '';

  meta = {
    description = "Wayland surface renderer and desktop shell toolkit";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "shoal";
  };
})
