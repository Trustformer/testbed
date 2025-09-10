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
          ]);

          profile = ''
            HOME=$(pwd)
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
    };
}
