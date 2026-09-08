{
  description = "NixOS configuration for Oracle Cloud VPS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }@inputs: {
    nixosConfigurations.oracle = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./disko.nix
        ./hardware-configuration.nix
        ./configuration.nix
      ];
    };

    devShells.x86_64-linux.default = let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in pkgs.mkShell {
      packages = [ pkgs.age pkgs.just pkgs.kubectl pkgs.micro pkgs.sops ];
    };

    devShells.aarch64-linux.default = let
      pkgs = import nixpkgs { system = "aarch64-linux"; };
    in pkgs.mkShell {
      packages = [ pkgs.age pkgs.just pkgs.kubectl pkgs.micro pkgs.sops ];
    };
  };
}
