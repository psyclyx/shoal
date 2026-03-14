{ config, lib, pkgs, ... }:

let
  cfg = config.programs.shoal;

  # Check if stylix is available and enabled
  hasStylix = (config ? stylix) && (config.stylix.enable or false);

  # Build the config JSON
  configJson = builtins.toJSON (
    (lib.filterAttrs (n: v: v != null) {
      layer = cfg.layer;
      anchor = cfg.anchor;
      width = cfg.width;
      height = cfg.height;
      exclusive_zone = cfg.exclusive_zone;
      margin = cfg.margin;
      namespace = cfg.namespace;
      keyboard_interactivity = cfg.keyboard_interactivity;
      modules_left = cfg.modules_left;
      modules_center = cfg.modules_center;
      modules_right = cfg.modules_right;
      clock_format = cfg.clock_format;
    }) // lib.optionalAttrs (cfg.theme != {}) {
      theme = cfg.theme;
    }
  );

in {
  options.programs.shoal = {
    enable = lib.mkEnableOption "Shoal wayland shell toolkit";

    package = lib.mkPackageOption pkgs "shoal" {
      default = pkgs.shoal;
    };

    # Surface options
    layer = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "background" "bottom" "top" "overlay" ]);
      default = null;
      description = "Layer shell layer";
    };

    anchor = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          top = lib.mkOption { type = lib.types.bool; default = false; };
          bottom = lib.mkOption { type = lib.types.bool; default = false; };
          left = lib.mkOption { type = lib.types.bool; default = false; };
          right = lib.mkOption { type = lib.types.bool; default = false; };
        };
      });
      default = null;
      description = "Anchor edges";
    };

    width = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
    };

    height = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
    };

    exclusive_zone = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
    };

    margin = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          top = lib.mkOption { type = lib.types.int; default = 0; };
          right = lib.mkOption { type = lib.types.int; default = 0; };
          bottom = lib.mkOption { type = lib.types.int; default = 0; };
          left = lib.mkOption { type = lib.types.int; default = 0; };
        };
      });
      default = null;
    };

    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    keyboard_interactivity = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "none" "exclusive" "on_demand" ]);
      default = null;
    };

    # Bar module layout
    modules_left = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Modules for the left section of the bar";
      example = [ "workspaces" ];
    };

    modules_center = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Modules for the center section of the bar";
      example = [ "title" ];
    };

    modules_right = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Modules for the right section of the bar";
      example = [ "pulseaudio" "cpu" "memory" "network" "clock" ];
    };

    clock_format = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Clock format string (strftime-like: %H %I %M %S %m %d %Y %y %p)";
      example = "%I:%M %p";
    };

    # Theme options - base16 colors
    theme = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Base16 theme colors. Keys are base00-base0F, values are hex color strings like '#1e1e2e'.";
      example = {
        base00 = "#1e1e2e";
        base05 = "#cdd6f4";
        base0D = "#89b4fa";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      home.packages = [ cfg.package ];
    }

    # Generate config file if any options are set
    (lib.mkIf (cfg.theme != {} || cfg.layer != null || cfg.width != null || cfg.height != null
               || cfg.modules_left != null || cfg.modules_center != null || cfg.modules_right != null) {
      xdg.configFile."shoal/config.json".text = configJson;
    })

    # Stylix integration: inject base16 colors as theme defaults
    (lib.mkIf hasStylix {
      programs.shoal.theme = let
        colors = config.lib.stylix.colors;
      in lib.mkDefault {
        base00 = "#${colors.base00}";
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
      };
    })
  ]);
}
