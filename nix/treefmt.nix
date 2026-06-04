# treefmt-nix as a flake-parts module (wires `nix fmt` + a treefmt flake check).
# fourmolu and cabal-gild are taken from the ghc9124 package set so they match
# the project's compiler.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { pkgs, ... }:
    let
      haskellPkgs = pkgs.haskell.packages.ghc9124;
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";
        programs.nixpkgs-fmt.enable = true;
        programs.fourmolu.enable = true;
        programs.fourmolu.package = haskellPkgs.fourmolu;
        programs.cabal-gild.enable = true;
        programs.cabal-gild.package = haskellPkgs.cabal-gild;
      };
    };
}
