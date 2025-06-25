{
  description = "Zig 0.14.1 overlay flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls_src = {
      # No upstream 0.14.1 is tagged.
      url = "github:zigtools/zls/0.14.0";
      # Upstream flake is misconfigured on this branch.
      # It uses its own version to fetch the zig binary from the overlay,
      # and 0.14.0 is no longer available.
      flake = false;
    };
  };

  outputs = { nixpkgs, zig-overlay, zls_src, ... }:
    let
      system = "x86_64-linux";
      deps = { linkFarm, fetchzip, fetchgit }: linkFarm "zig-packages" [
      {
        name = "known_folders-0.0.0-Fy-PJtLDAADGDOwYwMkVydMSTp_aN-nfjCZw6qPQ2ECL";
        path = fetchzip {
          name = "known_folders";
          url = "https://github.com/ziglibs/known-folders/archive/aa24df42183ad415d10bc0a33e6238c437fc0f59.tar.gz";
          hash = "sha256-YiJ2lfG1xsGFMO6flk/BMhCqJ3kB3MnOX5fnfDEcmMY=";
        };
      }

      {
        name = "N-V-__8AABhrAQAQLLLGadghhPsdxTgBk9N9aLVOjXW3ay0V";
        path = fetchzip {
          name = "diffz";
          url = "https://github.com/ziglibs/diffz/archive/ef45c00d655e5e40faf35afbbde81a1fa5ed7ffb.tar.gz";
          hash = "sha256-5/3W0Xt9RjsvCb8Q4cdaM8dkJP7CdFro14JJLCuqASo=";
        };
      }

      {
        name = "lsp_codegen-0.1.0-CMjjo0ZXCQB-rAhPYrlfzzpU0u0u2MeGvUucZ-_g32eg";
        path = fetchzip {
          name = "lsp-codegen";
          url = "https://github.com/zigtools/zig-lsp-codegen/archive/063a98c13a2293d8654086140813bdd1de6501bc.tar.gz";
          hash = "sha256-KzRi/a3FCS11Mryin9skkf3rFrIuoMP8+RcU0IuYNBA=";
        };
      }
    ];
    in let
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system}."0.14.1";
      target = builtins.replaceStrings ["darwin"] ["macos"] system;
      zls = pkgs.stdenvNoCC.mkDerivation {
        name = "zls";
        version = "0.14.0";
        meta.mainProgram = "zls";
        src = zls_src;
        nativeBuildInputs = [zig];
        dontConfigure = true;
        dontInstall = true;
        doCheck = true;
        buildPhase = ''
          PACKAGE_DIR=${pkgs.callPackage deps {}}
          zig build install --global-cache-dir $(pwd)/.cache --system $PACKAGE_DIR -Dtarget=${target} -Doptimize=ReleaseSafe --color off --prefix $out
        '';
        checkPhase = ''
          zig build test --global-cache-dir $(pwd)/.cache --system $PACKAGE_DIR -Dtarget=${target} --color off
        '';
      };
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
          
          export PS1="(dev:zig@${zig.version}) $PS1"
        '';
      };
    };
}