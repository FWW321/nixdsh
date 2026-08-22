# dsh flake checks(构建期域;`nix flake check` 触发)
# 分层验证:包内 installCheck 覆盖 CLI 本身;tests/(nix-unit)覆盖纯求值
# 面(行组金样/负例 expectedError/合并语义)——nix-unit 不进沙箱 checks:
# 测试实现 derivation 上下文(shipped presets/registry 源的 pathExists),
# 沙箱内无 daemon/build-hook 必炸;nix-unit 作者自己的 pyproject.nix 同样
# 以 CI 步骤跑(`nix flake check` 前:tests/nix-unit 一步)。本地:
#   nix shell nixpkgs#nix-unit -c nix-unit --flake .#tests.<system> --show-trace
# 此处只留真 boot/真执行/独立解析器(yq)交叉验证的构建期检查。
# 域文件:
#   ./profile.nix   bundle 工件/正例 boot/缺 base 负例/wrapper 行为
#   ./seam.nix      三家后端 + 双缝真 boot/roster/permission boot 级
#   ./mcp.nix       secret 注入/stderr 收纳行为级/insert 通道真 boot
#   ./sources.nix   yq 交叉验证/剥离物理性/farm 实然/origins 命令
#   ./npm-oracle.nix pack 物化产物 vs 上游 npm tarball(构建真实 dsh,bump 闸门)
#   ./options-doc.nix options 参考文档(nixosOptionsDoc 渲染 description 真源)
# 共享夹具(applyWith/mkFakeCfg/materialize/inTreeCheck)在 ./fixtures.nix
# (纯部分真源在 ../tests/fixtures.nix)
{ pkgs }:

let
  dshLib = import ../lib { inherit (pkgs) lib; };
  fx = import ./fixtures.nix { inherit pkgs dshLib; };
in
{ }
// (import ./profile.nix { inherit pkgs dshLib fx; })
// (import ./seam.nix { inherit pkgs dshLib fx; })
// (import ./mcp.nix { inherit pkgs dshLib fx; })
// (import ./sources.nix { inherit pkgs dshLib fx; })
// (import ./npm-oracle.nix {
  inherit pkgs;
  lib = pkgs.lib;
})
// (import ./options-doc.nix {
  inherit pkgs;
  lib = pkgs.lib;
  inherit dshLib;
})
