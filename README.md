# projectorctl

A small display switcher for Hyprland laptops. It covers the usual projector setup without an `xrandr` script or a streamed virtual display.

The available layouts are:

- laptop only
- projector only
- mirror
- extend left
- extend right

Mirror mode uses Hyprland's own monitor mirroring. Projector-only mode keeps a guard running so the laptop screen comes back if the cable is pulled.

## Home Manager

Add the flake and import its module:

```nix
inputs.projectorctl.url = "github:nyxar77/projectorctl";

imports = [ inputs.projectorctl.homeManagerModules.default ];

programs.projectorctl.enable = true;
```

The panel and unplug guard are enabled by default. They can be turned off with `enablePanel` and `enableGuard`.

This project uses Hyprland's Lua configuration. Bind the panel wherever it makes sense in your config:

```lua
hl.bind("SUPER + P", hl.dsp.exec_cmd("projector-panel"))
```

The panel opens on every active screen and does not belong to a workspace. Run the same command again to close it.

## CLI

The panel is optional. Everything is available directly:

```sh
projectorctl status
projectorctl apply builtin
projectorctl apply external
projectorctl apply duplicate
projectorctl apply extend-left
projectorctl apply extend-right
projectorctl recover
```

`external` means projector only. `recover` brings the laptop panel back.

## If the screen stays black

Press `Ctrl+Alt+F12`. The Home Manager module installs this as a direct recovery binding, so it works without opening the panel.

The guard listens to Hyprland and kernel DRM hotplug events. There is also a slow 60-second check as a fallback, but it stays out of Hyprland when no guarded layout is active.

## Theme

The panel uses the current Caelestia scheme when one is available. Otherwise it uses its own small fallback palette.

## Check the repo

```sh
nix flake check
```
