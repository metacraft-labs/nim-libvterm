# Owning compiler/Zlib SDK from the immutable source closure in flake.lock.
{
  system ? builtins.currentSystem,
}:
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  root =
    assert builtins.isString lock.root && builtins.hasAttr lock.root lock.nodes;
    lock.nodes.${lock.root};
  resolve =
    reference: depth:
    assert depth <= builtins.length (builtins.attrNames lock.nodes);
    if builtins.isString reference then
      assert builtins.hasAttr reference lock.nodes;
      reference
    else
      assert builtins.isList reference && reference != [ ] && builtins.all builtins.isString reference;
      builtins.foldl' (
        node: segment: resolve lock.nodes.${node}.inputs.${segment} (depth + 1)
      ) lock.root reference;
  sourceFor =
    name:
    let
      node = lock.nodes.${resolve root.inputs.${name} 0};
    in
    assert node.locked.type == "github";
    assert builtins.isString node.locked.owner && node.locked.owner != "";
    assert builtins.isString node.locked.repo && node.locked.repo != "";
    assert builtins.match "[0-9a-f]{40}" node.locked.rev != null;
    assert builtins.match "sha256-[A-Za-z0-9+/]{43}=" node.locked.narHash != null;
    builtins.fetchTree node.locked;
  pkgs = import (sourceFor "nixpkgs").outPath { inherit system; };
  nim = pkgs.nim;
  zlib = pkgs.zlib;
  # Canonical Linux Nim C backend is stdenv GCC; Darwin selection requires
  # separate native source/profile proof before this branch is qualified.
  baseCompiler = if pkgs.stdenv.isDarwin then pkgs.clang else pkgs.stdenv.cc;
  compiler = pkgs.wrapCCWith {
    cc = baseCompiler.cc;
    nixSupport = {
      cc-cflags = "-I${pkgs.lib.getDev zlib}/include";
      cc-ldflags = "-L${pkgs.lib.getLib zlib}/lib -rpath ${pkgs.lib.getLib zlib}/lib";
    };
  };
  nimWrapper = pkgs.writeShellScriptBin "nim" ''
    export CC="${compiler}/bin/${if pkgs.stdenv.isDarwin then "clang" else "gcc"}"
    export CXX="${compiler}/bin/${if pkgs.stdenv.isDarwin then "clang++" else "g++"}"
    exec "${nim}/bin/nim" "$@"
  '';
in
assert builtins.elem system [
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-darwin"
  "aarch64-darwin"
];
pkgs.symlinkJoin {
  name = "libvterm-owning-compiler-zlib-sdk";
  paths = [
    nimWrapper
    compiler
    pkgs.bash
  ];
  passthru = {
    inherit
      nim
      nimWrapper
      zlib
      compiler
      baseCompiler
      ;
    bash = pkgs.bash;
  };
}
