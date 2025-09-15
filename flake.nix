{
  description = "Zig 0.15.1 overlay flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls-overlay.url = "github:zigtools/zls/0.15.0";
    zls-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, zig-overlay, zls-overlay, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system}."0.15.1";
      zls = zls-overlay.packages.${system}.default;
    in {
      formatter.${system} = pkgs.alejandra;

      packages.${system} = {
        default = zig;
        zls = zls;
        zig = zig;
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ zig zls pkgs.bashInteractive ];

        shellHook = ''
          echo "Zig version: ${zig.version}"
          echo "ZLS version: ${zls.version}"

          export PROMPT_NAME='dev:zig@${zig.version}';
        '';
      };
    };
}