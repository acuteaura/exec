# NixOS configuration for the exe.dev MCP aggregator container image.
#
# exe.dev boots OCI images as KVM microVMs (Cloud Hypervisor) with an
# external, host-provided kernel — similar to privileged Docker. The guest
# has full access to /sys, /proc, cgroups, and KVM, and runs its own systemd
# as PID 1.
#
# We deliberately do NOT set boot.isContainer = true. That profile is tuned
# for unprivileged Docker containers: it disables agetty, sets
# services.openssh.startWhenNeeded = false, turns off the firewall, and
# trims boot to a container-minimal path. On a KVM microVM several of those
# choices are wrong or unnecessary:
#
#   - We want the firewall on (only port 80 needs to be open).
#   - Store path registration is handled at image build time instead
#     (includeNixDB in image.nix), so Nix on the VM knows the closure is
#     valid and `nixos-rebuild` doesn't rewrite live store paths.
#   - The profile mounts /proc and /sys read-only in places; a microVM
#     expects them writable (exeuntu's init-wrapper remounts /proc/sys rw).
#
# Instead we build a lean server image directly: systemd boots to
# multi-user.target, one service runs the MCP aggregator, and /init is a
# symlink to the NixOS toplevel so exe.dev's exetini exec's systemd as PID 1.
#
# The image is consumed via:
#   ssh exe.dev new --image=ghcr.io/acuteaura/exec/mcp:latest
# exe.dev prefers EXPOSE port 80, so the aggregator listens there.

{ pkgs, config, lib, ... }:

let
  # The gateway config is a read-only Nix store template. mcp-gateway expands
  # `${VAR}` references from the process environment at load time, so the
  # admin bearer token is injected via the MCP_GATEWAY_ADMIN_TOKEN env var
  # (set on the systemd unit) rather than baked into the closure — secrets
  # never go into the Nix store. Rotate by changing the env var and
  # restarting the service (or override /var/lib/mcp-gateway/gateway.yaml).
  #
  # The template is copied into the service's StateDirectory
  # (/var/lib/mcp-gateway) at start. We do NOT serve it straight from /etc
  # because mcp-gateway derives its control-plane store + audit-log directory
  # from the config file's parent (../<stem>-control-plane). Under /etc that
  # sibling is read-only, so the gateway logs a "control-plane audit log
  # unavailable (Permission denied)" warning and disables governance
  # mutations. Putting the config in the writable StateDirectory lets the
  # control-plane store open cleanly.
  gatewayConfig = pkgs.writeText "gateway.yaml" ''
    # MCP Gateway configuration — baked into the image as a template.
    # See https://github.com/MikkoParkkola/mcp-gateway#readme

    server:
      host: "0.0.0.0"
      port: 80
      # exe.dev's HTTPS proxy authenticates external callers (the VM is
      # private by default; only users with VM access can reach it). The
      # gateway refuses to bind 0.0.0.0 with public tool paths unless we
      # explicitly opt in here.
      allow_unauthenticated_network_bind: true

    # Meta-MCP: expose a compact tool surface (gateway_search_tools,
    # gateway_invoke, …) that discovers backend tools on demand. This keeps
    # prompt overhead low regardless of how many backends are connected.
    meta_mcp:
      enabled: true
      cache_tools: true
      cache_ttl: 300s

    # Tool endpoints are public so MCP clients can call them without the
    # admin token. The dashboard and management routes stay authenticated.
    # The token is resolved from the environment at load time.
    auth:
      enabled: true
      bearer_token: "''${MCP_GATEWAY_ADMIN_TOKEN}"
      single_user: true
      public_paths:
        - "/health"
        - "/mcp"

    backends:
      context7:
        command: "context7-mcp --transport stdio"
        description: "Up-to-date, version-specific library docs (Context7)"
  '';

  # A single store path whose bin/ contains everything the gateway and its
  # spawned backends need. Cleaner than a lib.makeBinPath [...] string in
  # the unit and keeps PATH to one element.
  gatewayBin = pkgs.symlinkJoin {
    name = "mcp-gateway-bin";
    paths = [ pkgs.mcp-gateway pkgs.context7-mcp pkgs.coreutils pkgs.bash ];
  };
in
{
  # ------------------------------------------------------------------
  # Boot / init
  # ------------------------------------------------------------------

  # No initrd, no bootloader: the kernel is supplied by the exe.dev host.
  # systemd is the only init and is exec'd as PID 1 via the /init symlink.
  boot.initrd.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.isContainer = lib.mkForce false;

  # The root filesystem is the read-only Nix store closure inside the OCI
  # image. exe.dev gives the VM a writable block device for / , so this is
  # only the initial seed. /etc, /var, /run are tmpfs / writable overlays
  # created by systemd at runtime.
  fileSystems."/".device = "/dev/vda";
  fileSystems."/".fsType = "ext4";

  # Grow the root fs on first boot. On exe.dev the root is a real ext4 on
  # /dev/vda and we want to grow it to fill the VM's (much larger) disk. We do
  # NOT use the `x-systemd.growfs` fstab option because it generates a
  # `systemd-growfs-root.service` and an activation snippet that writes to
  # /etc/fstab — which fails on the read-only rootfs of an overlay (docker) and
  # leaves the system degraded, with no ConditionFileSystem= available to guard
  # it. Instead we run our own guarded oneshot that checks the fstype at
  # runtime and only acts on ext4.
  systemd.services.exe-growfs = {
    description = "Grow root filesystem (ext4 only)";
    after = [ "systemd-remount-fs.service" ];
    before = [ "systemd-fsck-root.service" "local-fs.target" ];
    wantedBy = [ "local-fs.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "exe-growfs" ''
        set -euo pipefail
        fstype=$(findmnt -n -o FSTYPE / || true)
        if [ "$fstype" = "ext4" ]; then
          device=$(findmnt -n -o SOURCE /)
          echo "Growing $device (ext4) mounted at /"
          ${pkgs.e2fsprogs}/bin/resize2fs "$device" || true
        else
          fstype=''${fstype:-<none>}
          echo "Root fstype is $fstype; skipping growfs"
        fi
      '';
    };
  };

  # ------------------------------------------------------------------
  # Users / shell
  # ------------------------------------------------------------------

  users.users.root.initialHashedPassword = "!"; # no password login
  users.mutableUsers = false;
  # exe.dev terminates SSH at the host proxy and never runs a guest sshd
  # (services.openssh.enable = false below), so there is no local login path
  # to lock. Silence the "no password or SSH key" assertion.
  users.allowNoPasswordLogin = true;

  # exe.dev SSH sessions come in as the `exedev` user by convention; mirror
  # exeuntu so `ssh exe.dev new --image=...` drops into a familiar shell.
  users.users.exedev = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    initialHashedPassword = "!";
    shell = pkgs.bashInteractive;
  };
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  # ------------------------------------------------------------------
  # Networking
  # ------------------------------------------------------------------

  # Leave the hostname empty so NixOS does not manage /etc/hostname. exe.dev
  # passes the VM name on the kernel cmdline (ip=...:<hostname>:eth0:...) and
  # exe-init writes it to /etc/hostname before systemd starts; with hostName
  # unset NixOS leaves that file alone, so the gateway VM adopts whatever
  # name exe.dev gave it at `ssh exe.dev new` time.
  networking.hostName = "";
  networking.useNetworkd = true;

  # exe.dev microVMs get a single NIC (eth0) with DHCP. Configure networkd so
  # it manages the link.
  networking.useDHCP = false;
  systemd.network = {
    enable = true;
    networks."10-eth" = {
      matchConfig.Name = "eth0";
      DHCP = "yes";
    };
  };

  # The aggregator only binds 0.0.0.0:80 — it does not need any link to be
  # "online" to start serving. Disable the wait-online service entirely so it
  # can never time out and leave the system in a degraded state. (networkd
  # still configures the interface; this just stops network-online.target from
  # gating services on link state.) This also covers the docker test case
  # where the engine configures eth0 out-of-band and networkd leaves it
  # unmanaged, making wait-online hang forever.
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
  systemd.targets.network-online.enable = lib.mkForce false;

  # Only expose the aggregator. SSH (if ever needed) is handled host-side by
  # exe.dev's proxy, not by a guest sshd.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 80 ];
  };

  services.openssh.enable = false;

  # ------------------------------------------------------------------
  # Packages
  # ------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    bashInteractive
    coreutils
    curl
    gitMinimal
    ripgrep
    sqlite
    vim
    # The aggregator itself and its first backend are installed system-wide so
    # the systemd unit can invoke them by absolute path without a shell PATH.
    mcp-gateway
    context7-mcp
    # CLI wrapper that points mcp-gateway at the live config in the
    # StateDirectory by default, so `mcp-gatewayctl` Just Works from a shell
    # without remembering the --config flag.
    (pkgs.writeShellScriptBin "mcp-gatewayctl" ''
      exec ${pkgs.mcp-gateway}/bin/mcp-gateway \
        --config "''${MCP_GATEWAY_CONFIG:-/var/lib/mcp-gateway/gateway.yaml}" \
        "$@"
    '')
  ];

  # ------------------------------------------------------------------
  # MCP aggregator service
  # ------------------------------------------------------------------

  # context7 works without an API key (lower rate limits). Set
  # CONTEXT7_API_KEY at `ssh exe.dev new --env CONTEXT7_API_KEY=...` time to
  # raise them. The config itself is the `gatewayConfig` store path above,
  # copied into /var/lib/mcp-gateway at service start.

  systemd.services.mcp-gateway = {
    description = "MCP Gateway aggregation server";
    # No After=/Wants= on network-online.target: binding 0.0.0.0:80 works as
    # soon as the socket layer is up, and stdio backends (context7) dial out
    # lazily on first use and retry on their own. Waiting for "online" only
    # coupled the service to link state (and to a wait-online unit that can
    # time out).
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "exec";
      # Copy the baked config into the StateDirectory so the gateway's
      # control-plane store/audit log (derived from this file's directory)
      # land in a writable location. Only seed on first boot so edits the
      # operator makes to the live file survive service restarts.
      StateDirectory = "mcp-gateway";
      StateDirectoryMode = "0750";
      ExecStartPre = "${gatewayBin}/bin/sh -c 'test -e /var/lib/mcp-gateway/gateway.yaml || install -m 0640 ${gatewayConfig} /var/lib/mcp-gateway/gateway.yaml'";
      ExecStart = "${gatewayBin}/bin/mcp-gateway serve --config /var/lib/mcp-gateway/gateway.yaml";
      Restart = "on-failure";
      RestartSec = 5;
      # context7 may be spawned; keep the PATH minimal but self-contained.
      Environment = [
        "PATH=${gatewayBin}"
      ];
      # MCP_GATEWAY_ADMIN_TOKEN is the dashboard/management bearer token,
      # interpolated into the config at load time. Load it from an env file
      # if the operator created one (e.g. via `ssh exe.dev new --env ...
      # --image=...` or by writing /var/lib/mcp-gateway/env` by hand) so
      # the secret isn't baked into the unit.
      EnvironmentFile = [ "-/var/lib/mcp-gateway/env" ];
      # Run as an unprivileged user.
      User = "exedev";
      Group = "users";
      WorkingDirectory = "/home/exedev";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "mcp-gateway";
      # The gateway binds 0.0.0.0:80; port 80 is a privileged port (<1024)
      # and the process runs as non-root user exedev. Grant the ambient
      # capability so binding succeeds without running as root.
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    };
  };

  # ------------------------------------------------------------------
  # Misc
  # ------------------------------------------------------------------

  # Quiet, fast boot; no docs to keep the image small.
  documentation.enable = false;
  documentation.doc.enable = false;
  documentation.info.enable = false;
  documentation.man.enable = false;

  # No kernel or firmware in the image — the host owns the kernel.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  boot.kernel.enable = false;

  # ------------------------------------------------------------------
  # Nix / flakes — enable on the running VM so `sudo nixos-rebuild switch
  # --flake .#exe-mcp` works for live reconfiguration from this repo.
  # ------------------------------------------------------------------
  nix = {
    package = pkgs.nixVersions.stable;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # exe.dev KVM microVMs restrict systemd's transient-unit creation, so
  # `nixos-rebuild switch` fails with "Access denied" when it tries to run
  # `switch-to-configuration` via `systemd-run`. Setting this env var makes
  # nixos-rebuild call `switch-to-configuration` directly (it just updates
  # the system profile symlinks and reloads units — no transient service
  # needed), so `sudo nixos-rebuild switch --flake .#exe-mcp` works.
  #
  # sudo resets the environment (env_reset), so without env_keep the variable
  # would be stripped and `sudo nixos-rebuild switch` would still go through
  # systemd-run. Keep it across sudo.
  environment.variables.NIXOS_REBUILD_NO_SYSTEMD_RUN = "1";
  security.sudo.extraConfig = ''
    Defaults env_keep += "NIXOS_REBUILD_NO_SYSTEMD_RUN"
  '';

  # exe.dev boots whatever /init points at. The image points it at the
  # toplevel it was built with; re-point it at the generation being activated
  # so a `nixos-rebuild switch` survives reboot. (Not a bootloader: `nixos-rebuild
  # boot` does not run activation and so does not update it.)
  system.activationScripts.exeInit = ''
    if [ -L /init ] || [ ! -e /init ]; then
      ln -sfn "$systemConfig/init" /init.tmp && mv -T /init.tmp /init || true
    fi
  '';

  system.stateVersion = "25.05";
}
