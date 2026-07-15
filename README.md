# projectorctl

Safe display switching for Hyprland laptops and projectors.

`projectorctl` provides laptop-only, external-only, native Duplicate, and extended layouts. It verifies every layout, uses Hyprland's native mirroring rather than a streamed virtual output, and runs a user service that restores the built-in display when an external-only display disconnects.

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

Bind `projector-panel` to a key in Hyprland, or use the CLI directly:

```sh
projectorctl status
projectorctl apply duplicate
projectorctl apply external
projectorctl recover
```

The module appends the required Lua layout loader to Hyprland's configuration. The panel follows Caelestia's scheme file when it is present and otherwise uses its built-in colors.
