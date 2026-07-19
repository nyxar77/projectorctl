# projectorctl

Safe display switching for Hyprland laptops and projectors.

`projectorctl` provides laptop-only, projector-only, native mirroring, and extended layouts. It verifies every layout, uses Hyprland's own mirroring instead of a streamed virtual output, and restores the laptop panel if a projector-only setup is unplugged.

## Home Manager

```nix
inputs.projectorctl.url = "path:/path/to/projectorctl";

imports = [ inputs.projectorctl.homeManagerModules.default ];

programs.projectorctl = {
  enable = true;
  enablePanel = true;
  enableGuard = true;
};
```

Bind `projector-panel` to a key in Hyprland, or use the CLI directly. The panel appears above every active display without belonging to a workspace; press the same key again to close it everywhere.

```sh
projectorctl status
projectorctl apply duplicate
projectorctl apply external
projectorctl recover
```

If every display is black, press `Ctrl+Alt+F12` to restore the laptop panel directly. This emergency binding is installed by the Home Manager module and does not open the graphical panel.

The fail-safe listens for Hyprland and kernel DRM hotplug events. A slow 60-second check remains as a backup; it does not query Hyprland unless projector-only or mirror mode is armed.

The module appends the required Lua layout loader to Hyprland's configuration. The panel follows Caelestia's scheme file when it is present and otherwise uses its built-in colors.
