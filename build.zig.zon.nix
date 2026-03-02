# Zig package dependencies for shoal
# Hand-written because zon2nix cannot handle the new Zig hash format.

{
  linkFarm,
  fetchgit,
}:

linkFarm "zig-packages" [
  # zig-wayland (Wayland protocol scanner + client bindings)
  {
    name = "wayland-0.5.0-dev-lQa1kv_ZAQCZfnVZMocokZ78QJbH6NaM5RUC9ODQPhx5";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/zig-wayland";
      rev = "260778a0f2f6af0a2c6bd311a60cb1aa4311ef7a";
      hash = "sha256-7c7aDEKi8eCbyR05aoER+vcZTgxGJv9+KDdfeHfOpes=";
    };
  }
  # clay-zig-bindings (Clay layout engine Zig bindings)
  {
    name = "zclay-0.2.2-Ej1rkPDRAADuk7U5Y1YjpoFfE5Puvf5JIDyyjtnz3aVc";
    path = fetchgit {
      url = "https://github.com/johan0A/clay-zig-bindings";
      rev = "6247096649f547a55e90dcdc1e821c72186f6d09";
      hash = "sha256-qfiJdzb5gUe/N6H2u1ejFhw9ooSjRHM4gqWdjaJtOLE=";
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
