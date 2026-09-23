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
#   - isContainer enables the Nix store path-registration oneshot, which is
#     harmless but pointless for a read-only closure baked into the image.
#   - The profile mounts /proc and /sys read-only in places; a microVM
#     expects them writable (exeuntu's init-wrapper remounts /proc/sys rw).
#
# Instead we build a lean server image directly: systemd boots to
# multi-user.target, one service runs the MCP aggregator, and /init is a
# symlink to the NixOS toplevel so exe.dev's exetini exec's systemd as PID 1.
#
# The image is consumed via:
#   ssh exe.dev new --image=ghcr.io/acuteaura/exec:latest
# exe.dev prefers EXPOSE port 80, so the aggregator listens there.

{ pkgs, config, lib, ... }:

let
  # An opaque admin token. For a single-user aggregator this just guards the
  # dashboard / management API; the /mcp tool endpoint is public. Rotate by
  # editing /etc/mcp-gateway/gateway.yaml on the running VM and restarting
  # the service, or by rebuilding the image with a new value here.
  adminToken = "mcpgw_exe_dev_change_me";
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
  fileSystems."/".options = [ "defaults" "x-systemd.growfs" ];

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

  networking.hostName = "exe-mcp";
  networking.useNetworkd = true;

  # exe.dev microVMs get a single NIC (eth0) with DHCP. Configure networkd
  # explicitly so it manages the link and network-online.target converges.
  networking.useDHCP = false;
  systemd.network = {
    enable = true;
    networks."10-eth" = {
      matchConfig.Name = "eth0";
      DHCP = "yes";
      # In docker (where eth0 is already configured by the engine), networkd
      # leaves the link unmanaged and wait-online would hang. Don't block boot
      # on a link that may already be up out-of-band.
      linkConfig.RequiredForOnline = "no";
    };
  };

  # Don't let network-online.target block the aggregator from starting if a
  # link never reaches the configured state (e.g. in docker, or if the exe.dev
  # proxy provisions networking host-side).
  systemd.services.systemd-networkd-wait-online.serviceConfig.TimeoutStartSec =
    lib.mkForce 10;
  systemd.services.systemd-networkd-wait-online.environment.SYSTEMD_RELAX_ESP_CHECKS =
    "yes";

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
  ];

  # ------------------------------------------------------------------
  # MCP aggregator service
  # ------------------------------------------------------------------

  # The gateway configuration is baked into the image. context7 is wired as
  # a stdio backend: the gateway spawns `context7-mcp --transport stdio` and
  # multiplexes its tools behind a single /mcp endpoint (Meta-MCP mode).
  #
  # context7 works without an API key (lower rate limits). Set
  # CONTEXT7_API_KEY at `ssh exe.dev new --env CONTEXT7_API_KEY=...` time to
  # raise them.

  environment.etc."mcp-gateway/gateway.yaml".text = ''
    # MCP Gateway configuration — baked into the image.
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
    auth:
      enabled: true
      bearer_token: "${adminToken}"
      single_user: true
      public_paths:
        - "/health"
        - "/mcp"

    backends:
      context7:
        command: "context7-mcp --transport stdio"
        description: "Up-to-date, version-specific library docs (Context7)"
  '';

  systemd.services.mcp-gateway = {
    description = "MCP Gateway aggregation server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.mcp-gateway}/bin/mcp-gateway serve --config /etc/mcp-gateway/gateway.yaml";
      Restart = "on-failure";
      RestartSec = 5;
      # context7 may be spawned; keep the PATH minimal but include the store.
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.context7-mcp pkgs.coreutils ]}"
      ];
      # Run as an unprivileged user.
      User = "exedev";
      Group = "users";
      WorkingDirectory = "/home/exedev";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "mcp-gateway";
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

  # First-boot housekeeping: grow the root fs to fill the VM disk. exe.dev
  # gives the VM a block device larger than the image and expects the guest
  # to grow the fs. We write the fstab entry declaratively (above) so this
  # activation script is intentionally a no-op.
  system.activationScripts.growfs = lib.mkForce "";

  system.stateVersion = "25.05";
}
