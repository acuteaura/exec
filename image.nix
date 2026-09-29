{ pkgs, nixos }:

# Build an OCI (Docker-compatible) image from a NixOS system closure.
#
# We use dockerTools.buildImage because it supports runAsRoot (we need to
# create the /init symlink and a runtime directory skeleton). The resulting
# tarball is loadable with `docker load` and pushable with `docker push`.
#
# The image's /init is a symlink to the NixOS toplevel's init (systemd),
# matching what exe.dev's exetini expects to exec as PID 1.

let
  inherit (nixos.config.system.build) toplevel;

  # The store paths the image must contain: the system closure. buildImage
  # copies these into the image root.
  storePaths = [ toplevel ];

  image =
    pkgs.dockerTools.buildImage
      {
        # The repository will host multiple images eventually; the `mcp`
        # suffix distinguishes this one (the MCP aggregation gateway) from
        # any future target.
        name = "acuteaura/exec-mcp";
        tag = "latest";

        # The closure and its runtime dependencies.
        copyToRoot = storePaths;

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

        # Run after the store paths are laid down: create the /init symlink
        # and the runtime directory skeleton the image needs.
        runAsRoot = ''
          ${pkgs.dockerTools.shadowSetup}
          # /init -> the NixOS toplevel init (systemd).
          ln -sf ${toplevel}/init /init
          # Runtime directories systemd expects to exist.
          mkdir -p /run /tmp /var/lib /etc
          chmod 1777 /tmp
          # /etc/machine-id must exist (empty => first boot) so systemd doesn't
          # re-enable units we disabled.
          : > /etc/machine-id
          # Create the exedev user's home so the service WorkingDirectory exists.
          mkdir -p /home/exedev
          chown -R 1000:1000 /home/exedev
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
