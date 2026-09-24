let
  npins = import ./npins;
  overlay = import ./overlay.nix;
in
{ nixpkgs ? npins.nixpkgs
, pkgs ? import nixpkgs { }
  # snail is consumed as a Zig *source* via `zig build --system`; shoal keeps
  # its OWN pinned snail (targets 0.6.1) — deliberate, kept as the default.
, snail-src ? npins.snail
, ...
}:
let
  # surface snail-src by name so package.nix's `snail-src` callPackage arg
  # resolves it; superproject overrides snail-src to point at sibling lib/snail.
  finalPkgs = (pkgs.extend (_: _: { snail-src = snail-src; })).extend overlay;
in
{
  packages = { inherit (finalPkgs) shoal; };
  inherit overlay;
  shell = import ./shell.nix { pkgs = finalPkgs; };
  default = finalPkgs.shoal;
  homeManagerModules.default = import ./nix/hm-module.nix;
}
