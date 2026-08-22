# 纯求值夹具:nix-unit 域专用(applyPlugins 直调底座 + wrapper stub cfg)。
# 构建期夹具(bundle 物化/in-tree 端到端)在 checks/fixtures.nix,后者
# 复用本文件的纯部分 —— 单一真源
{ pkgs, dshLib }:

let
  applyBase = {
    plugins = { };
    profiles = {
      default = { };
    };
    inBoxPlugins = { };
  };

  # applyPlugins 直调:公共底座 + overlay(测试只写差异面)
  applyWith =
    cfg:
    dshLib.applyPlugins {
      inherit pkgs;
      cfg = applyBase // cfg;
    };

  # renderWrapper stub cfg:fake package 无 bin.js → upstreamSubcommands
  # 回落内置名单 {web,plugin}(保留名负例依赖此行为)
  mkFakeCfg =
    overrides:
    {
      settings = { };
      telemetry = {
        mode = null;
      };
      providers = { };
      defaultModel = null;
      environment = { };
      dshHome = "/tmp/fake-dsh-home";
      package = pkgs.hello;
      defaultProfile = "base";
      extraArgs = [ ];
    }
    // overrides;
in
{
  inherit applyWith mkFakeCfg;
}
