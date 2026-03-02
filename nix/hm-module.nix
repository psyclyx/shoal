{ config, lib, pkgs, ... }:

let
  cfg = config.programs.shoal;
in {
  options.programs.shoal = {
    enable = lib.mkEnableOption "Shoal wayland surface renderer";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.shoal;
      defaultText = lib.literalExpression "pkgs.shoal";
      description = "The shoal package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
