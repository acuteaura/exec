{ pkgs, nixos }:

# Build an OCI (Docker-compatible) image from a NixOS system closure.
#
# The image's / contains only:
#   - /nix/store      the system closure
#   - /nix/var/nix    a Nix database registering that closure, plus the
#                     `system` profile pointing at the toplevel
#   - /init           -> /nix/var/nix/profiles/system/init (what exe.dev's
#                     exetini exec's as PID 1)
#   - empty runtime dirs (/etc, /tmp, /var, ...)
#
# Notes on why it looks like this:
#
#   * The store paths MUST be registered in the Nix DB (includeNixDB). If
#     they are not, Nix on the running VM considers them invalid and
#     `nixos-rebuild` re-creates them in place — deleting and rewriting
#     files that running services (e.g. dbus-broker's policy dirs) are
#     watching. That left dbus-broker with a policy lacking systemd's rules,
#     so every bus call to systemd was denied, root included.
#
#   * /etc is NOT pre-populated. NixOS activation builds /etc as symlinks
#     into /etc/static; copying the toplevel's etc/ into / instead leaves real
#     directories (e.g. /etc/dbus-1) that activation can never replace, so
#     they go stale after the first switch.
#
#   * /init goes through the system profile so a `nixos-rebuild switch`
#     (which updates the profile) also takes effect on the next boot.

let
  inherit (nixos.config.system.build) toplevel;

  # Root skeleton. .toplevel only records the toplevel's path so it is in the
  # closure that buildImage copies into /nix/store and registers in the DB;
  # extraCommands removes it from / again. (A symlink would not work:
  # copyToRoot dereferences symlinks and would copy the whole toplevel into /.)
  root = pkgs.runCommand "exe-mcp-root" { } ''
    mkdir -p $out
    echo ${toplevel} > $out/.toplevel
  '';

  image =
    pkgs.dockerTools.buildImage
      {
        # The repository will host multiple images eventually; the `mcp`
        # suffix distinguishes this one (the MCP aggregation gateway) from
        # any future target.
        name = "acuteaura/exec-mcp";
        tag = "latest";

        copyToRoot = root;
        includeNixDB = true;

        # exe.dev reads these labels at VM creation time.
        # install-shelley=true makes exe.dev install a recent Shelley and the
        # UI assume it's present. login-user=exedev makes SSH come in as exedev.
        config = {
          Cmd = [ "/init" ];
          ExposedPorts = { "80/tcp" = { }; };
          Labels = {
            "exe.dev/install-shelley" = "true";
            "exe.dev/login-user" = "exedev";
          };
          Env = [
            "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
          ];
        };

        # Runs in the layer directory (paths are relative to /). No
        # runAsRoot VM needed: NixOS activation creates users, /etc and the
        # exedev home directory at boot.
        extraCommands = ''
          rm -f .toplevel

          # System profile, as `nixos-rebuild` would create it.
          mkdir -p nix/var/nix/profiles
          ln -s ${toplevel} nix/var/nix/profiles/system-1-link
          ln -s system-1-link nix/var/nix/profiles/system

          ln -s /nix/var/nix/profiles/system/init init

          mkdir -p etc run var/lib home root tmp
          chmod 1777 tmp
          chmod 0700 root
          # Empty machine-id => systemd treats this as first boot and
          # generates one.
          : > etc/machine-id
        '';
      };

  # A buildable path that is the image tarball (a docker-loadable archive).
  imageTarball = image;

  # A script that streams the OCI tarball to stdout. Useful in CI:
  #   nix build .#streamImage && ./result | docker load
  streamScript = pkgs.writeShellScriptBin "stream-image" ''
    set -euo pipefail
    cat ${image}
  '';
in
{
  inherit streamScript imageTarball;
  # Expose the raw image derivation too.
  inherit image;
}
