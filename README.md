# acuteaura/exec

A NixOS-based OCI container image for [exe.dev](https://exe.dev) that runs an
**MCP aggregation server** on port 80. Built with Nix + systemd, pushed to
`ghcr.io/acuteaura/exec/mcp`.

## What's in it

- **`mcp-gateway`** — a single Rust binary ([MikkoParkkola/mcp-gateway][gw])
  that aggregates many MCP backends behind one streamable-HTTP `/mcp`
  endpoint with [Meta-MCP][meta] (a compact tool surface that discovers
  backend tools on demand, so prompt overhead stays low no matter how many
  backends you add).
- **`context7-mcp`** — wired as the first stdio backend, giving every client
  up-to-date, version-specific library documentation.
- **systemd** as PID 1, via a `/init` symlink to the NixOS toplevel — exactly
  what exe.dev's exetini expects to exec.

[gw]: https://github.com/MikkoParkkola/mcp-gateway
[meta]: https://github.com/MikkoParkkola/mcp-gateway#meta-mcp

## Why NixOS and not `boot.isContainer`?

exe.dev boots OCI images as **KVM microVMs** (Cloud Hypervisor) with an
external, host-provided kernel — closer to a privileged container than a
classic unprivileged one. The stock NixOS `boot.isContainer = true` profile is
[tuned for unprivileged Docker][dic]: it turns off the firewall, disables
`startWhenNeeded` ssh, and mounts parts of `/proc`/`/sys` read-only. On a KVM
microVM those choices are wrong or unnecessary, so `configuration.nix` builds
a lean server image directly and explicitly sets `boot.isContainer = false`.
See the header comment in [`configuration.nix`](./configuration.nix) for the
full rationale.

[dic]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/docker-image.nix

## Layout

| File | Purpose |
|------|---------|
| `flake.nix` | Flake entry point: builds the NixOS config + OCI image. |
| `configuration.nix` | The NixOS system config (systemd, networking, the aggregator service, baked gateway config). |
| `image.nix` | Wraps the closure in an OCI image via `dockerTools.buildImage`, sets exe.dev labels, creates `/init`. |
| `.github/workflows/build.yml` | CI: builds the image with Nix and pushes it to `ghcr.io/acuteaura/exec/mcp`. |

## Build locally

```bash
nix build .#image          # -> result is a docker-loadable tarball
# or stream it:
nix build .#streamImage && ./result | docker load
```

## Run on exe.dev

The GitHub workflow pushes to `ghcr.io/acuteaura/exec/mcp:latest` on every push
to `main`. To boot a VM from it:

```bash
ssh exe.dev new --image=ghcr.io/acuteaura/exec/mcp:latest
```

Because the image is published to ghcr.io, pass `--registry-auth` if the
package is private:

```bash
ssh exe.dev new --image=ghcr.io/acuteaura/exec/mcp:latest \
    --registry-auth=<user>:<github-pat-with-read:packages>
```

exe.dev's HTTPS proxy prefers `EXPOSE 80`, so the aggregator is reachable at
`https://<vm-name>.exe.xyz/` once the VM is up.

## Using the aggregator from an MCP client

Point any streamable-HTTP MCP client at the VM:

```
URL:      https://<vm-name>.exe.xyz/mcp
Transport: streamable HTTP
```

The `/mcp` tool endpoint is public (the VM is private by default — only
users with access can reach it through exe.dev's proxy). The dashboard and
management routes are guarded by an admin bearer token supplied via the
`MCP_GATEWAY_ADMIN_TOKEN` environment variable (interpolated into the config
at load time) — see `configuration.nix`.

## Reconfiguring a running VM

The flake exposes `nixosConfigurations.exe-mcp` (matching the VM's
hostname), so you can rebuild and switch a running VM in place:

```bash
git clone https://github.com/acuteaura/exec.git && cd exec
sudo nixos-rebuild switch --flake .#exe-mcp
```

Flakes are enabled in the image, and `nixos-rebuild` will pick up changes
from the local checkout and activate them on the live system.

exe.dev VMs refuse systemd transient units, so `nixos-rebuild` must not wrap
`switch-to-configuration` in `systemd-run` (otherwise it fails with
`Failed to start transient service unit: Access denied`). The image sets
`NIXOS_REBUILD_NO_SYSTEMD_RUN=1` and keeps it across `sudo`. On a VM booted
from an older image that lacks this, pass it explicitly for the first switch:

```bash
sudo env NIXOS_REBUILD_NO_SYSTEMD_RUN=1 nixos-rebuild switch --flake .#exe-mcp
```

The variable comes from `/etc/profile`, so open a new login shell after
switching before relying on the plain `sudo nixos-rebuild switch`.

### Adding more backends

Edit `/var/lib/mcp-gateway/gateway.yaml` on the running VM and restart the
service, or rebuild the image with a new entry under `backends:`:

```yaml
backends:
  context7:
    command: "context7-mcp --transport stdio"
  my-server:
    url: "https://mcp.example.com/mcp"   # HTTP backend
```

```bash
sudo systemctl restart mcp-gateway
```

or, from this repo on the VM:

```bash
sudo nixos-rebuild switch --flake .#exe-mcp
```

## Configuration

- **Port**: 80 (`EXPOSE 80`, exe.dev proxy picks it up automatically).
- **context7 API key**: optional. Pass at boot for higher rate limits:
  `ssh exe.dev new --env CONTEXT7_API_KEY=... --image=...`.
- **Admin token**: change `adminToken` in `configuration.nix` and rebuild.
