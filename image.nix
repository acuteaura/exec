{ pkgs, nixos }:

# Build an OCI (Docker-compatible) image from a NixOS system closure.
#
# The image's / contains only:
#   - /nix/store      the system closure
#   - /nix/var/nix    a Nix database registering that closure, plus the
#                     `system` profile pointing at the toplevel
#   - /init           -> <toplevel>/init (what exe.dev's exetini exec's as
#                     PID 1)
#   - minimal /etc files (passwd, group, shadow, os-release, machine-id)
#     and /home/exedev, needed by exe-init before NixOS activation runs
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
#   * The toplevel's etc/ is NOT copied into /. NixOS activation builds /etc
#     as symlinks into /etc/static; copying it instead leaves real
#     directories (e.g. /etc/dbus-1) that activation can never replace, so
#     they go stale after the first switch. Only a few plain files are
#     seeded (see extraCommands), which activation does replace.
#
#   * /init is a direct store-path symlink (a chain through the profile did
#     not boot on exe.dev). configuration.nix re-points it on every
#     activation so a `nixos-rebuild switch` also takes effect on reboot.

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

        # Runs on the layer directory (paths relative to /), after the Nix DB
        # is generated; no build VM needed.
        #
        # Kept close to the layout that is known to boot: exe.dev's exe-init
        # runs *before* NixOS activation, so give it minimal passwd/group/
        # shadow, os-release and the login user's home. Only plain files go
        # into /etc (written by hand rather than with dockerTools.shadowSetup,
        # which adds /etc/pam.d): NixOS activation replaces files with its own
        # on boot, but a directory in /etc would get stuck. Activation also
        # chowns /home/exedev to exedev.
        extraCommands = ''
          rm -f .toplevel
          chmod 0755 .

          # System profile, as nixos-rebuild expects it.
          mkdir -p nix/var/nix/profiles
          ln -s ${toplevel} nix/var/nix/profiles/system-1-link
          ln -s system-1-link nix/var/nix/profiles/system

          # Point directly at the store path, as on the image that booted. The
          # exeInit activation snippet in configuration.nix re-points it at
          # each new generation on switch.
          ln -s ${toplevel}/init init

          mkdir -p etc run tmp var/lib root home/exedev
          chmod 1777 tmp
          chmod 0700 root
          cat > etc/passwd <<'EOF'
          root:x:0:0:System administrator:/root:/run/current-system/sw/bin/bash
          exedev:x:1000:100::/home/exedev:/run/current-system/sw/bin/bash
          nobody:x:65534:65534:Unprivileged account:/var/empty:/run/current-system/sw/bin/nologin
          EOF
          cat > etc/group <<'EOF'
          root:x:0:
          wheel:x:1:exedev
          users:x:100:
          nogroup:x:65534:
          EOF
          cat > etc/shadow <<'EOF'
          root:!:1::::::
          exedev:!:1::::::
          nobody:!:1::::::
          EOF
          chmod 0640 etc/shadow
          cat ${toplevel}/etc/os-release > etc/os-release
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
