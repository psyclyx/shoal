{ config, lib, pkgs, ... }:

let
  cfg = config.programs.shoal;

  hasStylix = (config ? stylix) && (config.stylix.enable or false);

  systemdUnitType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to create and start the systemd service.";
      };

      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "graphical-session.target" ];
        description = "Units to start after.";
      };

      partOf = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "graphical-session.target" ];
        description = "Units this is part of.";
      };

      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "graphical-session.target" ];
        description = "Units to want.";
      };

      requisite = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Units required to be running.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Environment variables for the service.";
      };

      restart = lib.mkOption {
        type = lib.types.enum [ "no" "on-success" "on-failure" "on-abnormal" "on-abort" "always" ];
        default = "on-failure";
      };

      restartSec = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2;
        description = "Seconds to wait before restarting.";
      };
    };
  };

  configType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable this shoal config.";
      };

      modules = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = {};
        description = ''
          Janet modules to write to ~/.config/shoal/<name>/.
          Each key becomes a filename (e.g. "bar" → bar.janet).
          Files are loaded alphabetically.
        '';
        example = {
          "10-compositor" = "(use /compositor/sway)";
          "20-bar" = "(reg-surface :default {:per-output true} (fn [] [:row ...]))";
        };
      };

      theme = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.ints.positive);
        default = {};
        description = "Base16 theme colors and font config.";
      };

      systemd = lib.mkOption {
        type = systemdUnitType;
        default = {};
        description = "Systemd unit configuration.";
      };
    };
  });

  # Generate the xdg.configFile entries for a single config
  mkConfigFiles = name: conf: let
    configDir = "shoal/${name}";
  in lib.mkMerge [
    # Janet modules
    (lib.mkIf (conf.modules != {}) (lib.mapAttrs' (modName: text:
      lib.nameValuePair "${configDir}/${modName}.janet" {
        inherit text;
        onChange = "systemctl restart --user shoal-${name}.service || true";
      }
    ) conf.modules))

    # config.json for theme
    (lib.mkIf (conf.theme != {}) {
      "${configDir}/config.json".text = builtins.toJSON { theme = conf.theme; };
    })
  ];

  # Generate systemd service for a config
  mkSystemService = name: conf: lib.nameValuePair "shoal-${name}" {
    Unit = {
      Description = "Shoal - ${name}";
      PartOf = conf.systemd.partOf;
      After = conf.systemd.after ++ (lib.optional (name != "default" && config.programs.shoal.configs ? default) "shoal-default.service");
      Wants = conf.systemd.wants;
      Requisite = conf.systemd.requisite;
    };

    Service = {
      ExecStart = "${lib.getExe cfg.package} run ${config.xdg.configHome}/shoal/${name}/main.janet";
      Environment = lib.mapAttrsToList (k: v: "${k}=${v}") conf.systemd.environment;
      Restart = conf.systemd.restart;
      RestartSec = conf.systemd.restartSec;
    };

    Install.WantedBy = lib.mkIf conf.systemd.enable [ "graphical-session.target" ];
  };

in {
  options.programs.shoal = {
    enable = lib.mkEnableOption "Shoal wayland shell toolkit";

    package = lib.mkPackageOption pkgs "shoal" {
      default = pkgs.shoal;
    };

    configs = lib.mkOption {
      type = lib.types.attrsOf configType;
      default = {};
      description = ''
        Named shoal configurations. Each config gets:
        - ~/.config/shoal/<name>/ directory with modules
        - systemd user service: shoal-<name>.service

        Use the "default" config name for the main bar.
      '';
      example = {
        default = {
          modules.bar = "(reg-surface :default {:per-output true} (fn [] [:row ...]))";
        };
        osd = {
          modules.osd = "(reg-surface :osd {:layer :overlay} osd-view)";
          systemd.after = [ "graphical-session.target" "shoal-default.service" ];
        };
      };
    };

    # Legacy options for backwards compatibility
    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Legacy: Janet modules for default config. Use configs.default.modules instead.";
    };

    theme = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.ints.positive);
      default = {};
      description = "Legacy: Theme for default config. Use configs.default.theme instead.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      home.packages = [ cfg.package ];
    }

    # Legacy support: merge into configs.default
    (lib.mkIf (cfg.modules != {} || cfg.theme != {}) {
      programs.shoal.configs.default = {
        modules = cfg.modules;
        theme = cfg.theme;
      };
    })

    # Generate config files for all configs
    {
      xdg.configFile = lib.mkMerge (lib.mapAttrsToList mkConfigFiles cfg.configs);
    }

    # Generate systemd services for enabled configs
    {
      systemd.user.services = lib.mapAttrs' mkSystemService
        (lib.filterAttrs (_: conf: conf.enable && conf.systemd.enable) cfg.configs);
    }

    # Stylix integration (applies to default config)
    (lib.mkIf hasStylix {
      programs.shoal.configs.default.theme = let
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
