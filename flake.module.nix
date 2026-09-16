# Project-specific flake customizations. seihou never generates, touches, or
# migrates this file, so it survives every nix-haskell-flake template upgrade.
# See flake.module.nix.example for the full menu of extension points.
{
  perSystem = { pkgs, ... }: {
    # xz/liblzma, kept for deps that link against it. Previously listed directly
    # in nix/haskell.nix before this project adopted the seihou-managed module.
    haskellProject.extraDevPackages = [ pkgs.xz ];
  };
}
