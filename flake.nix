{
  description = "nim-libvterm - libvterm bindings + Screen API + extended-state overlay for Nim";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nim
              nimble
              just
              nixfmt-rfc-style
              # Sanitizer-augmented Nim builds need clang on Linux. The
              # Justfile's `test-asan` recipe expects clang in $PATH.
              clang
              # Valgrind for the secondary leak-budget check.
              valgrind
              # zlib (headers + lib) -- the production PNG path uses
              # stb_image which bundles its own inflater, but the test
              # fixture helper `encodePng` in tests/test_helpers.nim
              # still wraps libz to *deflate* generated PNG bytes. The
              # Justfile pushes -I/-L flags through
              # NIM_LIBVTERM_ZLIB_{INCLUDE,LIB} so the build is hermetic.
              zlib
              zlib.dev
            ];
            shellHook = ''
              ${preCommit.shellHook}
              export NIM_LIBVTERM_ZLIB_INCLUDE="${pkgs.zlib.dev}/include"
              export NIM_LIBVTERM_ZLIB_LIB="${pkgs.zlib}/lib"
              echo "nim-libvterm dev shell -- nim $(nim --version 2>&1 | head -1)"
            '';
          };
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "nim-libvterm";
            version = "0.1.0";
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src vendor nim_libvterm.nimble README.md LICENSE $out/
            '';
          };
        };
    };
}
