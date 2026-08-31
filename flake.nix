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
            pkgs.wireplumber
          ];
          text = ''
            PROJECTORCTL_LIB_DIR=${./src/lib}
          '' + builtins.readFile ./src/projectorctl.sh;
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
            pkgs.qt6.qtdeclarative
            pkgs.qt6.qtwayland
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
          # These files are sourced modules. Their shared globals are defined by
          # config.sh and consumed across module boundaries.
          shellcheck -s bash -e SC2034,SC2154 \
            ${./src/lib/config.sh} \
            ${./src/lib/runtime.sh} \
            ${./src/lib/audio.sh} \
            ${./src/lib/state.sh} \
            ${./src/lib/hyprland.sh} \
            ${./src/lib/layouts.sh} \
            ${./src/lib/status.sh} \
            ${./src/lib/guard.sh}
          PROJECTORCTL_SOURCE=${./src/projectorctl.sh} \
            PROJECTORCTL_LIB_DIR=${./src/lib} \
            bash ${./tests/controller.bash}
          PROJECTORCTL_PANEL_SOURCE=${./src/projector-panel.sh} \
            PROJECTORCTL_FAKE_QUICKSHELL=${./tests/fake-quickshell} \
            PROJECTORCTL_QML_SOURCE=${./ui/Projector.qml} \
            bash ${./tests/panel.bash}
          qmllint \
            -I ${pkgs.qt6.qtdeclarative}/lib/qt-6/qml \
            -I ${pkgs.qt6.qtwayland}/lib/qt-6/qml \
            -I ${pkgs.quickshell}/lib/qt-6/qml \
            ${./ui/Projector.qml}
          touch "$out"
        '';
      };

      flake.homeManagerModules.default = import ./modules/home-manager.nix;
    };
}
