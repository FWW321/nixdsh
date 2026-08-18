# filepath: ~/code/FWW321/nixdsh/plugins-modules/status-rotator.nix
# per-plugin typed module 示例(nixvim modules/plugins/<name>.nix 同构)。
#
# 机制说明(module system 硬约束):attrsOf submodule 的 plugins.<name> 不能
# 被外部模块追加 options(nixvim 同样如此,它没有全局 plugins option)。
# 因此 typed 层挂在独立短路径 programs.dsh.<短名>.<选项>,由 config 块
# 回填通用层 plugins.<packageName> —— 对用户呈现为纯 typed 体验:
#
#   programs.dsh.status-rotator = {
#     enable = true;
#     intervalMs = 5000;
#   };
#
# 无需 typed 层的插件直接用通用层(任意插件零样板):
#   programs.dsh.plugins.dsh-status-rotator = {
#     enable = true;
#     settings = { intervalMs = 5000; };
#     profiles = [ "web" ];
#   };
{ config, lib, ... }:

let
  cfg = config.programs.dsh.status-rotator;
in
{
  options.programs.dsh.status-rotator = {
    enable = lib.mkEnableOption "dsh-status-rotator(状态栏轮换文案)";

    # 注:该插件运行时配置走其自身 config.json(gen-config.cjs 生成,
    # Nix 下为只读 symlink,插件回退 example 默认;v0.3.0+ 在设置页
    # 可视化编辑,PUT 原子写回会在只读 symlink 上失败 —— 改文案仍走
    # 覆盖 config.json 路径)。typed 键仅覆盖 Nix 能真实落地的部分
    # (enable/profiles)。带行级配置面的插件可完整 typed 化(见
    # config 块注释)。
    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "web" ];
      description = "目标 profile(该插件只影响 web UI)";
    };
  };

  config = lib.mkIf cfg.enable {
    # 回填通用层:名字 = registry packageName → source 免声明。
    # status-rotator v0.3.0 起自带 cordis bundle patch(一行 insert),
    # 通用层从 passthru.dshBundlePatch 自动发现并物化;typed 侧无行级
    # 配置面(运行时配置走插件自己的 config.json 机制)。有行级配置面
    # 的插件(dsh-sysmon 等)的 typed module 应在此渲染:
    #   patches = [ { id = "..."; config = { inherit (cfg) intervalMs; }; } ];
    programs.dsh.plugins.dsh-status-rotator = {
      enable = true;
      inherit (cfg) profiles;
    };
  };
}
