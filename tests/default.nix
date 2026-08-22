# nix-unit 域聚合:tests output 入口(flake 挂 tests.<system>)。
# 本地秒级迭代(免沙箱):
#   nix shell nixpkgs#nix-unit -c nix-unit --flake .#tests.x86_64-linux --show-trace
# CI/nix flake check 经 checks/dsh-nix-unit 沙箱运行同一份套件
{ pkgs }:

let
  dshLib = import ../lib { inherit (pkgs) lib; };
  fx = import ./fixtures.nix { inherit pkgs dshLib; };
in
{
  profile = import ./profile.nix { inherit pkgs dshLib fx; };
  seam = import ./seam.nix { inherit pkgs dshLib fx; };
  mcp = import ./mcp.nix { inherit pkgs dshLib fx; };
  sources = import ./sources.nix { inherit pkgs dshLib fx; };
}
