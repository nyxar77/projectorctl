{ config, lib, pkgs, ... }:
let
  cfg = config.programs.projectorctl;
  controller = pkgs.writeShellApplication {
    name = "projectorctl";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.libnotify pkgs.socat pkgs.util-linux ];
    text = builtins.readFile ../src/projectorctl.sh;
  };
  panel = pkgs.writeShellApplication {
    name = "projector-panel";
    runtimeInputs = [ pkgs.coreutils pkgs.quickshell ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      pid_file="$runtime_dir/projector-panel.pid"
      mkdir -p "$runtime_dir"
      if read -r old_pid < "$pid_file" 2>/dev/null && [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
        exit 0
      fi
      printf "%s\n" "$$" > "$pid_file"
      exec quickshell -p ${../ui/Projector.qml} "$@"
    '';
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
      Unit.Description = "Projector display fail-safe";
      Service = {
        ExecStart = "${controller}/bin/projectorctl watch";
        ExecStopPost = "-${controller}/bin/projectorctl check";
        Restart = "always";
        RestartSec = 1;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
