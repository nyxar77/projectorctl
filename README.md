# projectorctl

A small display switcher for Hyprland laptops. It handles private laptop-only, explicit presentation, and extended layouts without an `xrandr` script or a streamed virtual display.

![projectorctl panel](preview/preview0.png)

The panel is just a chooser. The actual work is done by the CLI, so it is still usable from scripts and keybindings.

## Nix and Home Manager

Add the flake and import the module:

```nix
inputs.projectorctl.url = "github:nyxar77/projectorctl";

imports = [ inputs.projectorctl.homeManagerModules.default ];

programs.projectorctl.enable = true;
```

The module exposes three options:

```nix
programs.projectorctl.enable = true;
programs.projectorctl.enablePanel = true; # Quickshell chooser, on by default
programs.projectorctl.enableGuard = true; # unplug recovery, on by default
```

The flake also exposes packages directly:

```sh
nix profile install github:nyxar77/projectorctl
nix profile install github:nyxar77/projectorctl#panel
```

The first command installs the CLI; the second installs the Quickshell panel. The guard service is installed by the Home Manager module.

This project uses Hyprland's Lua configuration. Bind the panel wherever it makes sense in your config:

```lua
hl.bind("SUPER + P", hl.dsp.exec_cmd("projector-panel"))
```

The panel opens on every active screen and does not belong to a workspace. Run the same command again to close it.
It reads display status once when it opens, after an action, or when you press the refresh button; it does not continuously poll Hyprland while it is open.

## Without Nix

The CLI needs Bash, `jq`, `socat`, `timeout`, `flock`, `udevadm`, and `wpctl` from WirePlumber. Hyprland and a working `hyprctl` are assumed. `notify-send` and Caelestia are optional.

Install the scripts and controller modules somewhere on your `PATH`:

```sh
install -Dm755 src/projectorctl.sh ~/.local/bin/projectorctl
install -d ~/.local/share/projectorctl/lib
install -Dm644 src/lib/*.sh ~/.local/share/projectorctl/lib/
install -Dm755 src/projector-panel.sh ~/.local/bin/projector-panel
install -Dm644 ui/Projector.qml ~/.local/share/projectorctl/Projector.qml
install -Dm644 modules/projector-layout.lua ~/.local/share/projectorctl/projector-layout.lua
```

The controller finds its modules in `~/.local/share/projectorctl/lib`. Load the display rules from your Hyprland Lua config; without this line, `hyprctl reload` cannot apply projectorctl's generated layouts:

```lua
dofile(os.getenv("HOME") .. "/.local/share/projectorctl/projector-layout.lua")
```

To open the panel, point it at the installed QML file:

```sh
PROJECTORCTL_PANEL_QML="$HOME/.local/share/projectorctl/Projector.qml" projector-panel
```

For a permanent panel keybinding, use the same command in your Hyprland Lua config:

```lua
local home = os.getenv("HOME")
hl.bind(
  "SUPER + P",
  hl.dsp.exec_cmd("env PROJECTORCTL_PANEL_QML=" .. home .. "/.local/share/projectorctl/Projector.qml projector-panel")
)
```

To keep unplug recovery running, save this as `~/.config/systemd/user/projector-display-guard.service`:

```ini
[Unit]
Description=Projector display fail-safe
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/projectorctl watch
ExecStopPost=-%h/.local/bin/projectorctl check
Restart=always
RestartSec=1
KillMode=control-group
TimeoutStopSec=10

[Install]
WantedBy=graphical-session.target
```

Then enable it:

```sh
systemctl --user daemon-reload
systemctl --user enable --now projector-display-guard.service
```

## CLI

```sh
projectorctl status
projectorctl apply builtin
projectorctl apply duplicate
projectorctl apply extend-left
projectorctl apply extend-right
projectorctl audio builtin
projectorctl audio external
projectorctl recover
```

`builtin` is the fail-closed Private mode: the laptop stays active and all external or unknown outputs are disabled. `duplicate` presents the laptop desktop on one external output. Display changes select the matching audio output when one is available; `audio builtin` and `audio external` select it directly. `recover` returns to Private mode. Projector-only was removed because disabling the laptop forces Hyprland to relocate workspaces.

## If the screen stays black

Press `Ctrl+Alt+F12`. The Home Manager module installs this as a direct recovery binding, so it works without opening the panel.

The guard starts in Private mode, listens to Hyprland and kernel DRM hotplug events, and returns to Private mode if a presentation output disappears. Presentation rules are session-only, so a reboot or new login cannot silently resume sharing. A 60-second topology check catches missed events and repairs any layout that no longer exactly matches the recorded mode.
Event listeners block while idle. If either listener exits unexpectedly, the guard starts it again.

If Present or Extend returns to Private mode, inspect
`$XDG_RUNTIME_DIR/projector-control-$UID/last-verification.json`. It records
the requested layout and the final monitor snapshot. The verifier waits up to
eight seconds by default; set `PROJECTORCTL_VERIFICATION_TIMEOUT` only when a
display consistently needs longer to complete a mode switch.

## Theme

The panel uses the current Caelestia scheme when one is available. Otherwise it uses its own small fallback palette.

## Check the repo

```sh
nix flake check
```

Without Nix, run the test scripts directly:

```sh
bash tests/controller.bash
bash tests/panel.bash
```
