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
          runtimeInputs = [ pkgs.coreutils pkgs.quickshell pkgs.util-linux ];
          text = ''
            PROJECTORCTL_PANEL_QML=${./ui/Projector.qml}
          '' + builtins.readFile ./src/projector-panel.sh;
        };

        checks.controller = pkgs.runCommand "projectorctl-controller-check" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.jq
            pkgs.shellcheck
            pkgs.util-linux
          ];
        } ''
          shellcheck -x \
            ${./src/projectorctl.sh} \
            ${./src/projector-panel.sh} \
            ${./tests/controller.bash} \
            ${./tests/panel.bash} \
            ${./tests/fake-quickshell}
          PROJECTORCTL_SOURCE=${./src/projectorctl.sh} bash ${./tests/controller.bash}
          PROJECTORCTL_PANEL_SOURCE=${./src/projector-panel.sh} \
            PROJECTORCTL_FAKE_QUICKSHELL=${./tests/fake-quickshell} \
            bash ${./tests/panel.bash}
          touch "$out"
        '';
      };

      flake.homeManagerModules.default = import ./modules/home-manager.nix;
    };
}
