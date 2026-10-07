{
  description = "exe.dev NixOS container image running an MCP aggregation server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # exe.dev microVMs are x86_64-linux KVM guests with an external
      # (host-provided) kernel. We only target that system.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The NixOS configuration for the image. See configuration.nix for the
      # rationale behind NOT using boot.isContainer.
      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };

      # An OCI image built from the NixOS system closure. /init is the systemd
      # toplevel, which exe.dev's exetini exec's as PID 1. See image.nix.
      image = pkgs.callPackage ./image.nix {
        inherit nixos;
      };
    in
    {
      # The flake attr `exe-mcp` is the build target for this image (the
      # runtime hostname is set dynamically by exe.dev, not hardcoded — see
      # networking.hostName in configuration.nix). Use it with:
      #   sudo nixos-rebuild switch --flake .#exe-mcp
      # `container` remains as an alias for the OCI image build path.
      nixosConfigurations.exe-mcp = nixos;
      nixosConfigurations.container = nixos;

      packages.${system} = {
        # The resolved image tarball (a docker-loadable archive).
        default = image.imageTarball;
        image = image.imageTarball;
        # A script that streams the OCI tarball to stdout. Useful in CI:
        #   nix build .#streamImage && ./result | docker load
        streamImage = image.streamScript;
      };

      # `nix run .#load` streams the freshly built image into the local
      # docker daemon.
      apps.${system}.load = {
        type = "app";
        program = "${pkgs.writeShellScriptBin "load-image" ''
          set -euo pipefail
          ${image.streamScript}/bin/stream-image | docker load
        ''}/bin/load-image";
      };
    };
}
