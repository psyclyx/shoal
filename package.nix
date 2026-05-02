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
  libxkbcommon,
  janet,
  zig_0_15,
  snail-src ? null,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "shoal";
  version = "0.1.0";

  src = ./.;

  deps = callPackage ./build.zig.zon.nix {
    inherit snail-src;
  };

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
    libxkbcommon
    janet
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  postInstall = ''
    cp -r $src/lib $out/share/shoal/lib
  '';

  meta = {
    description = "Wayland surface renderer and desktop shell toolkit";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "shoal";
  };
})
