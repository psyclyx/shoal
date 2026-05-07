# Zig package dependencies for shoal
# Hand-written because zon2nix cannot handle the new Zig hash format.

{
  linkFarm,
  fetchgit,
}:

linkFarm "zig-packages" [
  # zig-wayland (Wayland protocol scanner + client bindings)
  {
    name = "wayland-0.7.0-dev-lQa1krn7AQCMUzT3J6gWyukl3L3kbMtCZy9djQemUYA-";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/zig-wayland";
      rev = "589aaf7c213159547d774ef8e6491f0045c511d5";
      hash = "sha256-C1KR8BhbzbO+9RC1ExIDmbKARnzK2XA3+0pzxL4K2Qw=";
    };
  }
  # clay-zig-bindings (Clay layout engine Zig bindings)
  {
    name = "zclay-0.2.2-Ej1rkP3RAACYZGzQB5NGPaqfySgKfO26NYk5Ja6Z15gC";
    path = fetchgit {
      url = "https://github.com/johan0A/clay-zig-bindings";
      rev = "e0286c488a303b93501944ccde10730cc74ecd58";
      hash = "sha256-D/npnyjGykDygu4z+wrUR1TCGWnG3vMbtF+tH/JrB+g=";
    };
  }
  # --- Transitive dependencies ---

  # clay upstream (dep of clay-zig-bindings)
  {
    name = "N-V-__8AALPgZwA7tLqRlkCCL7OrkEhj4xZ3y_0FxgR42t0W";
    path = fetchgit {
      url = "https://github.com/nicbarker/clay";
      rev = "b25a31c1a152915cd7dd6796e6592273e5a10aac";
      hash = "sha256-6h1aQXqwzPc4oPuid3RfV7W0WzQFUiddjW7OtkKM0P8=";
    };
  }
]
