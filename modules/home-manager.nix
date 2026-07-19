{ config, lib, pkgs, ... }:
let
  cfg = config.programs.projectorctl;
  controller = pkgs.writeShellApplication {
    name = "projectorctl";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.libnotify pkgs.socat pkgs.systemd pkgs.util-linux ];
    text = builtins.readFile ../src/projectorctl.sh;
  };
  panel = pkgs.writeShellApplication {
    name = "projector-panel";
    runtimeInputs = [ pkgs.coreutils pkgs.quickshell pkgs.util-linux ];
    text = ''
      PROJECTORCTL_PANEL_QML=${../ui/Projector.qml}
    '' + builtins.readFile ../src/projector-panel.sh;
  };
in {
  options.programs.projectorctl = {
    enable = lib.mkEnableOption "the projectorctl Hyprland display controller";
    enablePanel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the Quickshell projector-panel frontend.";
    };
    enableGuard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Restore the laptop display after a selected external output disappears.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ controller ] ++ lib.optional cfg.enablePanel panel;

    wayland.windowManager.hyprland.extraConfig = lib.mkAfter (builtins.readFile ./projector-layout.lua);

    systemd.user.services.projector-display-guard = lib.mkIf cfg.enableGuard {
      Unit = {
        Description = "Projector display fail-safe";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${controller}/bin/projectorctl watch";
        ExecStopPost = "-${controller}/bin/projectorctl check";
        Restart = "always";
        RestartSec = 1;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
