{
  description = "LZig4 development shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    systems = [
      "x86_64-linux"
      "i686-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "armv6l-linux"
      "armv7l-linux"
    ];

    pkgs = nixpkgs.legacyPackages;

    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {
    devShells = forAllSystems (system: {
      default = import ./nix/shell.nix { pkgs = pkgs.${system}; };
    });

    packages = forAllSystems (system: {
      default = pkgs.${system}.callPackage ./nix/default.nix {};
    });
  };
}
