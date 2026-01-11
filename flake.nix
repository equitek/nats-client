{
  description = "nats-client - A Haskell client for NATS messaging protocol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        haskellPackages = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            nats-client = hself.callCabal2nix "nats-client" ./. { };
          };
        };

        packageName = "nats-client";
      in
      {
        packages = {
          ${packageName} = haskellPackages.${packageName};
          default = self.packages.${system}.${packageName};
        };

        devShells.default = haskellPackages.shellFor {
          packages = p: [ p.${packageName} ];
          buildInputs = with pkgs; [
            haskellPackages.cabal-install
            haskellPackages.haskell-language-server
            haskellPackages.hlint
            haskellPackages.ghcid
          ];
          withHoogle = true;
        };
      });
}
