{
  description = "Haskell nix template";

  inputs = {
    # The shared base flake. Provides the GHC 9.12.4 / cabal / HLS toolchain via
    # `mkDevShell`, and the single pinned nixpkgs the whole fleet follows.
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ ];
    extra-trusted-public-keys = [ ];
  };

  # Thin flake-parts shell. The dev toolchain comes from the haskell-nix-dev base
  # flake (GHC 9.12.4 / cabal / HLS via mkDevShell); project wiring lives in the
  # imported ./nix modules. This is a multi-package repo built from source via
  # the shared registry, so there is no in-flake package build (no
  # flake.module.nix) — packages are built with cabal from inside the dev shell.
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;

      imports =
        [
          ./nix/haskell.nix
          ./nix/treefmt.nix
          ./nix/pre-commit.nix
        ]
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
