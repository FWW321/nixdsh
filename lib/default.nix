# nixdsh lib:profile 模型 + nixvim 式实例化
#
# 三层(自底向上):
#   patch/inbox/secret(基础层:行渲染、bundle 模型、secret 双通道)
#   registry/faces/webseam/llmseam/permission/mcprows/subagents/
#   discovery/roster/settings/preset(域层:每域内聚,断言随域)
#   apply/wrapper/mkDsh(组合层:装配 per-profile 增量、CLI 入口、
#   evalModules 顶层组装)
# 依赖为单向 DAG:patch → inbox;secret → 域层 → apply → wrapper → mkDsh
#
# 与 Samuka007/dsh-nix 的差异:去掉 pnpm spec 网络解析类(第三方插件走 flake=false
# input,即 Nix 路径;fetchSpecs 的 fixed-output + impure env 与本仓库风格不符),
# layers/dependencies 由 build-time jq 重构为 eval-time 纯 Nix(更确定性、可检视)
{ lib }:

let
  patch = import ./patch.nix { inherit lib; };
  inbox = import ./inbox.nix {
    inherit lib;
    inherit (patch) patchesToYaml;
  };
  secret = import ./secret.nix { inherit lib; };
  registry = import ./registry.nix {
    inherit lib;
    inherit (inbox) inBoxFaces;
  };
  faces = import ./faces.nix { inherit lib registry; };
  settings = import ./settings.nix {
    inherit lib;
    inherit (secret) secretEnvName;
  };
  preset = import ./preset.nix {
    inherit lib;
    inherit (patch) isRawYaml;
  };
  webseam = import ./webseam.nix {
    inherit lib;
    inherit (secret) secretEnvName;
    inherit registry;
  };
  llmseam = import ./llmseam.nix { inherit lib; };
  permission = import ./permission.nix {
    inherit lib;
    inherit (patch) rawYaml;
  };
  mcprows = import ./mcprows.nix {
    inherit lib;
    inherit (secret) renderSecretAttrs;
  };
  subagents = import ./subagents.nix { inherit lib; };
  discovery = import ./discovery.nix { inherit lib registry; };
  roster = import ./roster.nix {
    inherit lib faces;
    inherit (preset) buildPresetFarm shippedPresetNames;
  };
  apply = import ./apply.nix {
    inherit lib;
    inherit (settings) validatePresets;
    inherit (preset) shippedPresetNames;
    inherit registry faces webseam llmseam permission mcprows subagents discovery roster;
  };
  wrapper = import ./wrapper.nix {
    inherit lib;
    inherit (settings) renderSettings;
    inherit (secret) secretEnv secretPlaceholder;
  };
  mkDshLayer = import ./mkDsh.nix {
    inherit lib;
    inherit (wrapper) renderWrapper;
    inherit (apply) applyPlugins;
    inherit (inbox) buildProfile mkProfile;
  };
in
{
  # 公共 API(与拆分前 lib.nix 的导出面一致 + patch 层)
  inherit (patch)
    rawYaml
    patchesToYaml
    ;
  inherit (inbox)
    inBoxNames
    mkPlugin
    mkProfile
    buildProfile
    ;
  inherit (secret)
    secretEnvName
    secretEnv
    secretPlaceholder
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
  inherit (preset)
    buildPreset
    buildPresetFarm
    mkPresetOriginsCmd
    presetOrigins
    shippedPreset
    shippedPresetNames
    ;
}
