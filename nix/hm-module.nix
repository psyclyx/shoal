{ config, lib, pkgs, ... }:

let
  cfg = config.programs.shoal;

  hasStylix = (config ? stylix) && (config.stylix.enable or false);

  surfaceType = lib.types.submodule {
    options = {
      layer = lib.mkOption {
        type = lib.types.enum [ "background" "bottom" "top" "overlay" ];
        default = "top";
      };

      anchor = lib.mkOption {
        type = lib.types.submodule {
          options = {
            top = lib.mkOption { type = lib.types.bool; default = true; };
            bottom = lib.mkOption { type = lib.types.bool; default = false; };
            left = lib.mkOption { type = lib.types.bool; default = true; };
            right = lib.mkOption { type = lib.types.bool; default = true; };
          };
        };
        default = {};
      };

      width = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
      };

      height = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 40;
      };

      exclusive_zone = lib.mkOption {
        type = lib.types.int;
        default = 44;
      };

      margin = lib.mkOption {
        type = lib.types.submodule {
          options = {
            top = lib.mkOption { type = lib.types.int; default = 0; };
            right = lib.mkOption { type = lib.types.int; default = 0; };
            bottom = lib.mkOption { type = lib.types.int; default = 0; };
            left = lib.mkOption { type = lib.types.int; default = 0; };
          };
        };
        default = {};
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "shoal";
      };

      keyboard_interactivity = lib.mkOption {
        type = lib.types.enum [ "none" "exclusive" "on_demand" ];
        default = "none";
      };
    };
  };

  # Build config JSON from theme + surfaces
  surfaceList = lib.mapAttrsToList (_: surf: {
    inherit (surf)
      layer width height exclusive_zone margin namespace
      keyboard_interactivity;
    anchor = lib.filterAttrs (_: v: v) surf.anchor;
  }) cfg.surfaces;

  configJson = builtins.toJSON (
    { surfaces = surfaceList; }
    // lib.optionalAttrs (cfg.theme != {}) { theme = cfg.theme; }
  );

in {
  options.programs.shoal = {
    enable = lib.mkEnableOption "Shoal wayland shell toolkit";

    package = lib.mkPackageOption pkgs "shoal" {
      default = pkgs.shoal;
    };

    surfaces = lib.mkOption {
      type = lib.types.attrsOf surfaceType;
      default = {};
      description = "Named surfaces. Each surface creates a layer-shell surface on all outputs.";
    };

    theme = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.ints.positive);
      default = {};
      description = "Base16 theme colors and font config.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      home.packages = [ cfg.package ];

      systemd.user.services.shoal = {
        Unit = {
          Description = "Shoal wayland shell";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = lib.getExe cfg.package;
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    }

    # Generate config file when surfaces or theme are configured
    (lib.mkIf (cfg.surfaces != {} || cfg.theme != {}) {
      xdg.configFile."shoal/config.json".text = configJson;
    })

    # Stylix integration
    (lib.mkIf hasStylix {
      programs.shoal.theme = let
        colors = config.lib.stylix.colors;
        fonts = config.stylix.fonts;
        opacity = config.stylix.opacity.desktop;
        alphaHex = let
          a = builtins.floor (opacity * 255);
          hex = lib.toHexString a;
        in if builtins.stringLength hex == 1 then "0${hex}" else hex;
      in lib.mkDefault ({
        base00 = "#${colors.base00}${alphaHex}";
        base01 = "#${colors.base01}";
        base02 = "#${colors.base02}";
        base03 = "#${colors.base03}";
        base04 = "#${colors.base04}";
        base05 = "#${colors.base05}";
        base06 = "#${colors.base06}";
        base07 = "#${colors.base07}";
        base08 = "#${colors.base08}";
        base09 = "#${colors.base09}";
        base0A = "#${colors.base0A}";
        base0B = "#${colors.base0B}";
        base0C = "#${colors.base0C}";
        base0D = "#${colors.base0D}";
        base0E = "#${colors.base0E}";
        base0F = "#${colors.base0F}";
        font_family = fonts.monospace.name;
        font_size = fonts.sizes.desktop;
      });
    })
  ]);
}
