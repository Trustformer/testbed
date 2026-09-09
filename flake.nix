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
            # conda lives in the testbed root, and chipyard finds it through HOME.
            # Search upward from the working directory rather than assuming it is the
            # root, so entering the sandbox from a subdirectory still works.
            cy_root="$CY_TESTBED"
            if [ -z "$cy_root" ]; then
              cy_root=$(pwd)
              while [ ! -d "$cy_root/conda" ] && [ "$cy_root" != / ]; do
                cy_root=$(dirname "$cy_root")
              done
              [ -d "$cy_root/conda" ] || cy_root=$(pwd)
            fi
            export HOME="$cy_root"
            unset cy_root

            # Lets scripts/cy detect that it is already inside the sandbox.
            export CY_FHS=1
            export LD_LIBRARY_PATH=${libPath}
            if [ -f "$HOME/conda/etc/profile.d/conda.sh" ]; then
              source "$HOME/conda/etc/profile.d/conda.sh"
              conda activate base
            else
              echo "note: no conda under $HOME/conda -- see README.md" >&2
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
