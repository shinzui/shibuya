{ pkgs, ghcVersion, ... }:
let
  haskellPkgs = pkgs.haskell.packages."${ghcVersion}";
in
{
  projectRootFile = "flake.nix";
  programs.nixpkgs-fmt.enable = true;
  programs.fourmolu.enable = true;
  programs.fourmolu.package = haskellPkgs.fourmolu;
  programs.cabal-gild.enable = true;
  programs.cabal-gild.package = haskellPkgs.cabal-gild;
}
