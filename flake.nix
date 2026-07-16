{
  description = "Safe projector and display switching for Hyprland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      perSystem = { pkgs, ... }: {
        packages.default = pkgs.writeShellApplication {
          name = "projectorctl";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.jq
            pkgs.libnotify
            pkgs.socat
            pkgs.util-linux
          ];
          text = builtins.readFile ./src/projectorctl.sh;
        };

        packages.panel = pkgs.writeShellApplication {
          name = "projector-panel";
          runtimeInputs = [ pkgs.coreutils pkgs.quickshell ];
          text = ''
            runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
            pid_file="$runtime_dir/projector-panel.pid"
            mkdir -p "$runtime_dir"

            if read -r old_pid < "$pid_file" 2>/dev/null && [ -n "$old_pid" ] && [ "$old_pid" != "$$" ]; then
              if kill -0 "$old_pid" 2>/dev/null; then
                old_command="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null || true)"
                if [[ "$old_command" == *quickshell*Projector.qml* ]]; then
                  kill "$old_pid" 2>/dev/null || true
                  exit 0
                fi
              fi
            fi

            printf "%s\n" "$$" > "$pid_file"
            exec quickshell -p ${./ui/Projector.qml} "$@"
          '';
        };

        checks.controller = pkgs.runCommand "projectorctl-controller-check" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.jq
            pkgs.shellcheck
          ];
        } ''
          shellcheck -x ${./src/projectorctl.sh} ${./tests/controller.bash}
          PROJECTORCTL_SOURCE=${./src/projectorctl.sh} bash ${./tests/controller.bash}
          touch "$out"
        '';
      };

      flake.homeManagerModules.default = import ./modules/home-manager.nix;
    };
}
