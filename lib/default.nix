# nixdsh lib:profile 模型 + nixvim 式实例化
#
# 三层(自底向上):
#   mkPlugin/mkProfile/buildProfile(./inbox.nix)
#       插件源 → profile 声明 → 不可变 store 工件
#   renderSettings/applyPlugins(./settings.nix ./apply.nix)
#       typed options → settings 段 + patch 行组
#   renderWrapper/mkDsh(./wrapper.nix ./mkDsh.nix)
#       CLI 入口 + evalModules 顶层组装
# secret 双通道(env 桥/占位符)在 ./secret.nix;依赖为单向 DAG:
#   inbox,secret → settings,apply → wrapper → mkDsh
#
# 与 Samuka007/dsh-nix 的差异:去掉 pnpm spec 网络解析类(第三方插件走 flake=false
# input,即 Nix 路径;fetchSpecs 的 fixed-output + impure env 与本仓库风格不符),
# layers/dependencies 由 build-time jq 重构为 eval-time 纯 Nix(更确定性、可检视)
{ lib }:

let
  inbox = import ./inbox.nix { inherit lib; };
  secret = import ./secret.nix { inherit lib; };
  settings = import ./settings.nix {
    inherit lib;
    inherit (secret) secretEnvName;
  };
  apply = import ./apply.nix {
    inherit lib;
    inherit (secret) renderSecretAttrs secretEnvName;
    inherit (inbox) inBoxFaces;
  };
  wrapper = import ./wrapper.nix {
    inherit lib;
    inherit (settings) renderSettings;
    inherit (secret) secretEnv;
    inherit (apply) applyPlugins;
  };
  mkDshLayer = import ./mkDsh.nix {
    inherit lib;
    inherit (wrapper) renderWrapper;
    inherit (apply) applyPlugins;
    inherit (inbox) buildProfile mkProfile;
  };
in
{
  # 公共 API(与拆分前 lib.nix 的导出面一致)
  inherit (inbox)
    inBoxNames
    mkPlugin
    mkProfile
    buildProfile
    ;
  inherit (secret)
    secretEnvName
    secretEnv
    ;
  inherit (settings)
    renderSettings
    validatePresets
    validateSkills
    ;
  inherit (apply)
    applyPlugins
    ;
  inherit (wrapper)
    renderWrapper
    renderCompletion
    upstreamSubcommands
    ;
  inherit (mkDshLayer)
    mkDsh
    ;
}
