{
  description = "Chipyard development shell";

  # To update flake.lock to the latest nixpkgs: `nix flake update`
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # output format guide https://nixos.wiki/wiki/Flakes#Output_schema
  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      libPath = pkgs.lib.makeLibraryPath [
        pkgs.zlib # libz.so.1
      ];

      fhs = pkgs.buildFHSEnv {
          name = "chipyard-fhs";

          targetPkgs = pkgs: (with pkgs; [
            cmake
            fish
            zlib
            gtkwave

            # Needed before the conda environment exists: build-setup.sh and the
            # chipyard makefiles shell out to these before `conda activate`.
            git
            wget
            curl
            which
            procps
            gnumake
          ]);

          profile = ''
            HOME=$(pwd)
            # Lets scripts/cy detect that it is already inside the sandbox.
            export CY_FHS=1
            export LD_LIBRARY_PATH=${libPath}
            if [ -f ~/conda/etc/profile.d/conda.sh ]; then
              source ~/conda/etc/profile.d/conda.sh
              conda activate base
            fi
          '';

        };
    in
    {
      devShells.${system}.default = fhs.env;

      # `nix develop --command ...` does not work for an FHS env: the shellHook
      # execs the sandbox and the command is dropped. Use this for non-interactive
      # / scripted use instead:
      #     nix run .#fhs -- -c 'command'
      packages.${system} = {
        fhs = fhs;
        default = fhs;
      };
    };
}
