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

Bind `projector-panel` to a key in Hyprland, or use the CLI directly. The panel opens on the focused display; press the same key again to close it.

```sh
projectorctl status
projectorctl apply duplicate
projectorctl apply external
projectorctl recover
```

The module appends the required Lua layout loader to Hyprland's configuration. The panel follows Caelestia's scheme file when it is present and otherwise uses its built-in colors.
