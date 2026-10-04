{
  description = "nim-libvterm - libvterm bindings + Screen API + extended-state overlay for Nim";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
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
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/<this repo>` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            fi
            unset _own_repo_root
          '';

          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                extraPackages = with pkgs; [
                  bash
                  coreutils
                  just
                  nim
                  nixfmt-rfc-style
                ];
                language = "system";
                pass_filenames = false;
              };
            };
          };
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                bash
                nim
                nimble
                just
                nixfmt-rfc-style
                # Sanitizer-augmented Nim builds need clang on Linux. The
                # Justfile's `test-asan` recipe expects clang in $PATH.
                clang
                # zlib (headers + lib) -- the production PNG path uses
                # stb_image which bundles its own inflater, but the test
                # fixture helper `encodePng` in tests/test_helpers.nim
                # still wraps libz to *deflate* generated PNG bytes. The
                # Justfile pushes -I/-L flags through
                # NIM_LIBVTERM_ZLIB_{INCLUDE,LIB} so the build is hermetic.
                zlib
                zlib.dev
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                # Valgrind is used by the existing Linux-only leak-budget job.
                pkgs.valgrind
              ];
            shellHook = ''
              ${ownRepoOnly preCommit.shellHook}
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
