{
  description = "👻";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs-stable.url = "github:nixos/nixpkgs/release-24.11";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-compat.follows = "";
      };
    };
  };

  outputs = {
    self,
    nixpkgs-unstable,
    nixpkgs-stable,
    zig,
    ...
  }:
    builtins.foldl' nixpkgs-stable.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs-stable = nixpkgs-stable.legacyPackages.${system};
          pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
        in {
          devShell.${system} = pkgs-stable.callPackage ./nix/devShell.nix {
            zig = zig.packages.${system}."0.13.0";
            wraptest = pkgs-stable.callPackage ./nix/wraptest.nix {};
          };

          packages.${system} = let
            mkArgs = optimize: {
              inherit optimize;

              revision = self.shortRev or self.dirtyShortRev or "dirty";
            };
          in rec {
            ghostty-debug = pkgs-stable.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-releasesafe = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-releasefast = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseFast");

            ghostty = ghostty-releasefast;
            default = ghostty;
          };

          formatter.${system} = pkgs-stable.alejandra;

          nixosConfigurations = let
            makeVM = (
              path:
                nixpkgs-stable.lib.nixosSystem {
                  inherit system;
                  modules = [
                    {
                      nixpkgs.overlays = [
                        self.overlays.releasefast
                      ];
                    }
                    ./nix/vm/common.nix
                    path
                  ];
                }
            );
          in {
            "wayland-gnome-${system}" = makeVM ./nix/vm/wayland-gnome.nix;
          };

          apps.${system} = let
            wrapVM = (
              name: let
                program = pkgs-stable.writeShellScript "run-ghostty-vm" ''
                  SHARED_DIR=$(pwd)
                  export SHARED_DIR

                  ${self.nixosConfigurations."${name}-${system}".config.system.build.vm}/bin/run-ghostty-vm
                '';
              in {
                type = "app";
                program = "${program}";
              }
            );
          in {
            wayland-gnome = wrapVM "wayland-gnome";
          };
        }
        # Our supported systems are the same supported systems as the Zig binaries.
      ) (builtins.attrNames zig.packages)
    )
    // {
      overlays = {
        default = self.overlays.releasefast;
        releasefast = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-releasefast;
        };
        debug = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-debug;
        };
      };
    };

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
