# dsh flake checks(不阻塞日常 rebuild,nix flake check 时跑)
# 分层验证(共识 Q6/Q16):包内 installCheck 已覆盖 CLI 本身;此处覆盖
# profile 组合与 typed 层渲染。域文件:
#   ./profile.nix  bundle 工件形状/正例 boot/缺 base 负例/face 四态/in-box 行/
#                  patch YAML 渲染层(patch.nix)
#   ./seam.nix     webSearch/webFetch 行组(含双缝组合回归)/负例/secretFile 桥/
#                  in-tree×4/roster 舞资格/权限整表
#   ./mcp.nix      MCP 行渲染/名校验/secret 注入行为/insert 通道端到端
#   ./sources.nix  providers 合并语义/presets/skills 校验/preset 重放 drift
# 共享夹具(applyWith/mkFakeCfg/materialize/inTreeCheck)在 ./fixtures.nix
# 负例强制模式:逐域 seq(域断言 seq 在域结果头部,WHNF 即达)——
# 旧的 `f { }` 调用 + 顶层 seq 组合在 Nix≥2.34 下或空洞或硬错,勿复用
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
