# Dev shell, built from the haskell-nix-dev base flake's mkDevShell (GHC 9.12.4 +
# cabal + HLS). Project-specific dev tools go in extraNativeBuildInputs below, or
# via `haskellProject.extraDevPackages`.
#
# mkDevShell already provides: the GHC compiler, cabal, HLS (when withHls),
# pkg-config, and zlib, plus a LANG=en_US.UTF-8 export. Only tools BEYOND those
# are listed in extraNativeBuildInputs.
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch ]";
      description = "Extra packages to add to the dev shell.";
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};

      mkProjectShell = ghc: hsdev.mkDevShell {
        inherit ghc;
        withHls = true;
        extraNativeBuildInputs =
          [
            pkgs.xz
            pkgs.just
            pkgs.postgresql
            pkgs.process-compose
            pkgs.jq
          ]
          ++ config.haskellProject.extraDevPackages;
        shellHook = ''
          ${config.pre-commit.installationScript}

          # Database paths - all relative to project root
          export PGHOST="$PWD/db"
          export PGDATA="$PGHOST/db"
          export PGLOG=$PGHOST/postgres.log
          export PGDATABASE=shibuya

          # Connection string for application use
          export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

          # Create directories
          mkdir -p $PGHOST
          mkdir -p .dev

          # Initialize database cluster on first entry
          if [ ! -d $PGDATA ]; then
            initdb --auth=trust --no-locale --encoding=UTF8
          fi
        '';
      };
    in
    {
      devShells.default = mkProjectShell "ghc9124";
      devShells.ghc9124 = mkProjectShell "ghc9124";
    };
}
