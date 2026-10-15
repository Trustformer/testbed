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

      # gcc + newlib-nano for TinyRocket-class cores (rv32imac, soft float); the conda
      # toolchain ships only rv64 libraries, and nixpkgs' cached riscv32 one is ilp32d.
      rv32 = import nixpkgs {
        localSystem = system;
        crossSystem = {
          config = "riscv32-none-elf";
          libc = "newlib-nano";
          gcc = { arch = "rv32imac_zicsr"; abi = "ilp32"; };
        };
      };

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
          ]) ++ [ rv32.buildPackages.gcc ];

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
        rv32-gcc = rv32.buildPackages.gcc;
        # Python for marsfw/plot.py: nix shell .#plot -c python3 marsfw/plot.py
        plot = pkgs.python3.withPackages (p: [ p.matplotlib ]);
        # Python for scripts/*.py: nix shell .#python -c scripts/<script>.py
        python = pkgs.python3;
        # Yosys and the SKY130 standard cells (OpenROAD's sky130hd copy) for scripts/mars-area.py
        yosys = pkgs.yosys;
        sky130hd-lib = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/e5cc6e799f5ddf36e6bdf2d8c5db73373b88f52c/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib";
          hash = "sha256-7A4QZ6Nci/ILEeWNHorFMyYGfk2shKElzBuRejUY0Nk=";
        };
        # Every single-port SKY130 SRAM macro of the OpenRAM test chip, for scripts/mars-fw-area.py
        sky130-sram-lefs = pkgs.linkFarm "sky130-sram-lefs" (map (m: {
          name = "${m.name}.lef";
          path = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/VLSIDA/openram_testchip/e48c011f35f18e37880e75108e2d704b43842320/lef/${m.name}.lef";
            inherit (m) hash;
          };
        }) [
          { name = "sky130_sram_1kbyte_1rw_32x256_8";  hash = "sha256-yA1niHQJ1YxtIFdEZLmpKfUL22dgUmZmIQSMLFNCAXc="; }
          { name = "sky130_sram_2kbyte_1rw_32x512_8";  hash = "sha256-kS2IUkyMEOtJ9BoH3cC9dOTlkCJSF1d6mHMsbgijdE0="; }
          { name = "sky130_sram_4kbyte_1rw_32x1024_8"; hash = "sha256-P6mN3w2XjAp8ODpLuTFB+wmZiT4e0osfbKvjppcqdBc="; }
          { name = "sky130_sram_4kbyte_1rw_64x512_8";  hash = "sha256-pOglGEhJJTFzK60YkwutzYNa1NtDGLQIFwTR3ErYS3w="; }
          { name = "sky130_sram_8kbyte_1rw_64x1024_8"; hash = "sha256-A2Z8iwzW16eDJzEWSH4o+TWeRzc4WG8mdRYWf1ebidk="; }
        ]);
        default = fhs;
      };
    };
}
