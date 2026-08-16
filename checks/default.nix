# dsh flake checks(不阻塞日常 rebuild,nix flake check 时跑)
# 分层验证(共识 Q6/Q16):包内 installCheck 已覆盖 CLI 本身;此处覆盖
# profile 组合与 typed 层渲染。域文件:
#   ./profile.nix  bundle 工件形状/正例 boot/缺 base 负例/face 四态/in-box 行
#   ./seam.nix     webSearch/webFetch 选择器行组/负例/secretFile 桥/in-tree×3
#   ./mcp.nix      MCP 行渲染/secret 注入行为/insert 通道端到端
#   ./sources.nix  providers 合并语义/presets/skills 校验
# 共享夹具(applyWith/mkFakeCfg/materialize/inTreeCheck)在 ./fixtures.nix
{ pkgs }:

let
  dshLib = import ../lib { inherit (pkgs) lib; };
  fx = import ./fixtures.nix { inherit pkgs dshLib; };
in
{}
// (import ./profile.nix { inherit pkgs dshLib fx; })
// (import ./seam.nix { inherit pkgs dshLib fx; })
// (import ./mcp.nix { inherit pkgs dshLib fx; })
// (import ./sources.nix { pkgs = pkgs; lib = pkgs.lib; inherit dshLib fx; })
