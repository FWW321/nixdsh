# filepath: ~/nixos-config/pkgs/dsh/lib.nix
# dsh profile 模型 + nixvim 式实例化 lib
#
# 三层(自底向上):
#   mkPlugin      插件源(flake=false input 路径/derivation) → 插件记录
#                 读 package.json 取 packageName 与 dsh.bundle.patch(有 patch 才是 profile layer)
#   mkProfile     插件有序组合 → profile 声明(in-box 名单 + nix 插件分类,唯一性校验)
#   buildProfile  profile 声明 → 不可变 store 工件:
#                 package.json(dsh.profile.bundles 层序 + dependencies) + node_modules/ 符号链接
#                 + cordis.patch.yml(用户 patch 层)。层序在求值期纯 Nix 计算,derivation 只做链接
#   mkDsh         nixvim 的 mkNixvim 同构:evalModules 求值 programs.dsh options →
#                 渲染 settings + 绑定 profile 的 dsh wrapper 二进制
#
# 与 Samuka007/dsh-nix 的差异:去掉 pnpm spec 网络解析类(第三方插件走 flake=false
# input,即 Nix 路径;fetchSpecs 的 fixed-output + impure env 与本仓库风格不符),
# layers/dependencies 由 build-time jq 重构为 eval-time 纯 Nix(更确定性、可检视)
#
# in-box bundles:dsh 自带、随安装分发,profile 只引用名字不做 symlink
{ lib }:

let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    concatStringsSep
    escapeShellArg
    filter
    getExe
    listToAttrs
    mapAttrs
    mapAttrsToList
    nameValuePair
    optionalString
    unique
    ;

  # dsh 安装自带的 bundle(profile 里按名字引用,dsh 运行时从自身安装解析)
  inBoxNames = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
    "@deepseek-ai/dsh-headless"
  ];

  mkPlugin =
    {
      packageName ? null,
      path,
      patchPath ? null,
    }:
    let
      # 源三态,元数据解析优先级:显式参数 > package.json(路径) > passthru(dshPlugins derivation)
      # 1. 本地路径(flake=false input)求值期可检视:直接读 package.json
      # 2. derivation(如 pkgs.dshPlugins.<name>)不可求值期检视,
      #    packageName/patch 从 overlay.nix 物化的 passthru 读(update.sh 生成时捕获)
      manifest =
        if builtins.isPath path then
          let manifestPath = "${toString path}/package.json"; in
          if builtins.pathExists manifestPath then
            builtins.fromJSON (builtins.readFile manifestPath)
          else
            throw "dsh plugin: missing package.json at ${manifestPath}"
        else
          null;
      passthruMeta = if lib.isDerivation path && path ? passthru then path.passthru else { };
      resolvedPackageName =
        if packageName != null then packageName
        else if manifest != null then (manifest.name or null)
        else (passthruMeta.packageName or null);
      checkedPackageName =
        if resolvedPackageName == null || resolvedPackageName == "" then
          throw "dsh plugin: packageName required (set explicitly, provide package.json, or use pkgs.dshPlugins)"
        else
          resolvedPackageName;
      declaredPatch =
        if manifest != null then (((manifest.dsh or { }).bundle or { }).patch or null)
        else (passthruMeta.dshBundlePatch or null);
      resolvedPatchPath = if patchPath != null then patchPath else declaredPatch;
    in
    {
      packageName = checkedPackageName;
      # store 化:本地路径进 store,保证 profile 工件引用的不可变性
      packagePath = if builtins.isPath path then builtins.path { inherit path; } else path;
      patchPath = resolvedPatchPath;
      # 有 cordis patch 的插件才是 profile layer(进 dsh.profile.bundles 数组)
      isLayer = resolvedPatchPath != null;
    };

  mkProfile =
    {
      name,
      plugins,
      userPatchesFile ? null,
      userPatches ? [ ],
    }:
    let
      classify =
        plugin:
        if builtins.isString plugin then
          if builtins.elem plugin inBoxNames then
            { kind = "in-box"; name = plugin; }
          else
            throw "dsh profile '${name}': unknown string plugin '${plugin}' — strings must be in-box bundle names (${concatStringsSep ", " inBoxNames}); third-party plugins are pkgs.dshPlugins.<name> derivations or Nix paths"
        else
          # attrs 且带 packagePath = mkPlugin 产出的记录;其余(derivation/path)按源处理
          { kind = "nix"; plugin = if plugin ? packagePath then plugin else mkPlugin { path = plugin; }; };
      classified = map classify plugins;
      nixPlugins = map (e: e.plugin) (filter (e: e.kind == "nix") classified);
      packageNames = map (p: p.packageName) nixPlugins;
      unique =
        if builtins.length packageNames == builtins.length (lib.unique packageNames) then true
        else throw "dsh profile '${name}': plugin packageNames must be unique";
    in
    assert unique; {
      inherit name userPatchesFile userPatches;
      plugins = classified;
      # 层序 = in-box 名 + 有 patch 的 nix 插件名,保持用户声明顺序(dsh 按 bundle 顺序叠加)
      layers =
        map
          (e:
            if e.kind == "in-box" then e.name
            else if e.plugin.isLayer then e.plugin.packageName
            else null)
          classified;
    };

  buildProfile =
    {
      pkgs,
      profile,
    }:
    let
      nixPlugins = map (e: e.plugin) (filter (e: e.kind == "nix") profile.plugins);
      layers = filter (l: l != null) profile.layers;
      manifest = builtins.toJSON {
        name = profile.name;
        version = "0.0.0";
        private = true;
        dsh.profile.bundles = layers;
        dependencies = listToAttrs
          (map (p: nameValuePair p.packageName (toString p.packagePath)) nixPlugins);
      };
      linkPlugin = p: ''
        mkdir -p "$out/node_modules/$(dirname ${escapeShellArg p.packageName})"
        ln -s ${escapeShellArg (toString p.packagePath)} "$out/node_modules/${escapeShellArg p.packageName}"
      '';
      patchContent =
        if profile.userPatchesFile != null then
          ''cp ${escapeShellArg (toString profile.userPatchesFile)} "$out/cordis.patch.yml"''
        else
          ''printf '%s' ${escapeShellArg (builtins.toJSON profile.userPatches)} > "$out/cordis.patch.yml"'';
    in
    pkgs.runCommand "dsh-profile-${profile.name}"
      {
        # dsh 每次 boot 会改写 profile 根 cordis.yml,activation 侧负责拷贝+chmod(见 hm-module)
        meta.description = "Immutable dsh profile bundle '${profile.name}' (layers: ${concatStringsSep ", " layers})";
      }
      ''
        mkdir -p "$out/node_modules"
        printf '%s' ${escapeShellArg manifest} > "$out/package.json"
        printf '[]\n' > "$out/cordis.yml"
        ${patchContent}
        ${concatStringsSep "\n" (map linkPlugin nixPlugins)}
      '';

  # settings 渲染:freeform settings 为底,typed core(telemetry.mode /
  # providers / defaultModel)后合并覆盖。providers 渲染进 llm-pi-ai 命名
  # 空间段 —— dsh-llm-pi-ai 的用户层(上游:cordis 树 base 配置 ⊕ 本段,
  # 按 provider 深合并,免重启);typed 条目逐 provider 覆盖 freeform 同名
  # 条目;defaultModel 渲染进 agent-default-model 段(schema 实测于源码)
  renderSettings =
    { settings, telemetry, providers ? { }, defaultModel ? null }:
    let
      # 省略 null/空的字段;settings 逃生口最后并(未 typed 字段直通)。
      # `or` 缺省:renderSettings 可脱离 module system 直接调用(checks/测试)
      renderProvider = p:
        (lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
          apiKeyEnv = p.apiKeyEnv or null;
          displayName = p.displayName or null;
          api = p.api or null;
          baseURL = p.baseURL or null;
          models = p.models or [ ];
          modelOverrides = p.modelOverrides or { };
          retryPolicy = p.retryPolicy or { };
          defaultContextWindow = p.defaultContextWindow or null;
          defaultMaxTokens = p.defaultMaxTokens or null;
          compat = p.compat or { };
        }) // (p.settings or { });
      nsBase = settings.llm-pi-ai or { };
      freeformProviders = nsBase.providers or { };
    in
    settings
    // (
      if telemetry.mode == null then { } else {
        telemetry = (settings.telemetry or { }) // { mode = telemetry.mode; };
      }
    )
    // (
      if providers == { } then { } else {
        "llm-pi-ai" = nsBase // {
          providers = freeformProviders // (mapAttrs (_: renderProvider) providers);
        };
      }
    )
    // (
      if defaultModel == null then { } else {
        "agent-default-model" = (settings."agent-default-model" or { }) //
          (lib.filterAttrs (_: v: v != null) {
            inherit (defaultModel) provider model;
            reasoningEffort = defaultModel.reasoningEffort or null;
          });
      }
    );

  # wrapper 渲染(TonyWu20 的 yq-merge 语义 + DSH_HOME):
  # - 声明 settings 每次启动 merge 进 settings.yaml:声明值覆盖同名键,本地其他键保留
  #   (dsh Web UI 会运行时改配置,yq merge 是唯一不与之打架的声明式方案)
  # - profile 注入:调用无显式 --profile 且非 web/plugin 子命令(它们拒绝父级 --profile)时
  #   自动补 --profile <name>;fixedProfile 非 null 时强制绑定该 profile
  renderWrapper =
    {
      cfg,
      pkgs,
      name ? "dsh",
      fixedProfile ? null,
    }:
    let
      effectiveProfile = if fixedProfile != null then fixedProfile else cfg.defaultProfile;
      settingsJSON =
        if renderSettings { inherit (cfg) settings telemetry providers defaultModel; } == { } then null
        else builtins.toJSON (renderSettings { inherit (cfg) settings telemetry providers defaultModel; });
      settingsPrelude = optionalString (settingsJSON != null) ''
        dsh_home="''${DSH_HOME:-$HOME/.dsh}"

        if [ -L "$dsh_home/settings.yaml" ]; then
          rm "$dsh_home/settings.yaml"
        fi

        mkdir -p "$dsh_home"
        tmp="$(mktemp "$dsh_home/settings.yaml.XXXXXX")"

        if [ -f "$dsh_home/settings.yaml" ]; then
          ${getExe pkgs.yq-go} '. * load("${pkgs.writeText "dsh-settings.yaml" settingsJSON}")' \
            "$dsh_home/settings.yaml" > "$tmp"
        else
          cp ${escapeShellArg (toString (pkgs.writeText "dsh-settings.yaml" settingsJSON))} "$tmp"
        fi

        chmod 0600 "$tmp"

        if [ ! -f "$dsh_home/settings.yaml" ] || ! cmp -s "$tmp" "$dsh_home/settings.yaml"; then
          mv "$tmp" "$dsh_home/settings.yaml"
        else
          rm "$tmp"
        fi
      '';
      envPrelude = concatStringsSep "\n"
        (mapAttrsToList
          (n: v: "export ${n}=${escapeShellArg v}")
          cfg.environment);
      profilePrelude = optionalString (effectiveProfile != null) ''
        wants_profile=0
        is_subcommand=0
        for arg in "$@"; do
          case "$arg" in
            --) break ;;
            --profile) wants_profile=1 ;;
            --profile=*) wants_profile=1 ;;
            web|plugin) is_subcommand=1 ;;
          esac
        done

        if [ "$wants_profile" -eq 0 ] && [ "$is_subcommand" -eq 0 ]; then
          set -- --profile ${escapeShellArg effectiveProfile} "$@"
        fi
      '';
      argsStr = concatStringsSep " " (map escapeShellArg cfg.extraArgs);
    in
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      export DSH_HOME="${cfg.dshHome}"
      ${envPrelude}
      ${settingsPrelude}
      ${profilePrelude}
      exec ${getExe cfg.package} ${argsStr} "$@"
    '';

  # nixvim 式 typed 插件层 → 各 profile 的增量渲染:
  #   plugins.<name>.enable → 源(source 或 pkgs.dshPlugins.<name>)追加进目标
  #   profile 的 plugins;settings/patches 渲染为 patch 行追加进其 userPatches
  # 目标:plugin.profiles 非空取其与已声明 profile 的交集;空 = 所有 profile
  # patchId 语义:settings 非空时才要求;行 = { id; config = settings; }
  applyPlugins =
    { cfg, pkgs }:
    let
      enabled = filter (p: p.enable) (attrValues cfg.plugins);
      # 名字→源:缺省 registry(不在 registry 且未显式给 source 时,mkPlugin
      # 端 passthru 缺 packageName 会 throw —— 提前给友好错误)
      sourceOf = name: p:
        if p.source != null then p.source
        else if pkgs ? dshPlugins && pkgs.dshPlugins ? ${name} then pkgs.dshPlugins.${name}
        else throw "programs.dsh.plugins.${name}: no source given and '${name}' not in pkgs.dshPlugins (add it to plugins/names.txt and run the updater, or set source)";
      targetsFor = p:
        if p.profiles == [ ] then attrNames cfg.profiles
        else filter (n: builtins.elem n (attrNames cfg.profiles)) p.profiles;
      patchRows = p:
        (lib.optional (p.settings != { }) { id = p.patchId; config = p.settings; })
        ++ p.patches;
      contributions = mapAttrsToList
        (name: con: {
          profiles = targetsFor con;
          plugin = { inherit name; source = sourceOf name con; };
          patches = patchRows con;
        })
        (lib.filterAttrs (_: p: p.enable) cfg.plugins);
    in
    {
      # profile 名 → { extraPlugins; extraPatches; }(追加在原始列表之后)
      perProfile = listToAttrs
        (map
          (profileName: nameValuePair profileName {
            extraPlugins =
              map (c: c.plugin.source)
                (filter (c: builtins.elem profileName c.profiles) contributions);
            extraPatches =
              concatMap (c: c.patches)
                (filter (c: builtins.elem profileName c.profiles) contributions);
          })
          (attrNames cfg.profiles));
    };

  # nixvim 式独立实例化:不依赖 HM/NixOS eval,即可求值出一个绑定配置的 dsh
  # (flake checks、未来抽独立 flake 时的对外 API)
  mkDsh =
    { pkgs, modules ? [ ], extraSpecialArgs ? { } }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; } // extraSpecialArgs;
        modules = [
          (import ./modules/options.nix)
          {
            programs.dsh.package = lib.mkDefault pkgs.dsh;
          }
        ] ++ modules;
      };
      cfg = evaluated.config.programs.dsh;
      wrapper = renderWrapper { inherit cfg pkgs; };
      applied = applyPlugins { inherit cfg pkgs; };
      withPlugins = name: p:
        let inc = applied.perProfile.${name} or { extraPlugins = [ ]; extraPatches = [ ]; }; in
        {
          plugins = p.plugins ++ inc.extraPlugins;
          userPatchesFile = p.userPatchesFile;
          userPatches = p.userPatches ++ inc.extraPatches;
        };
      profileBundles = mapAttrs
        (name: p: buildProfile {
          inherit pkgs;
          profile = mkProfile { inherit name; } // (withPlugins name p);
        })
        cfg.profiles;
    in
    {
      inherit (evaluated) config options;
      wrapper = wrapper;
      package = wrapper;
      inherit profileBundles;
    };
in
{
  inherit
    inBoxNames
    mkPlugin
    mkProfile
    buildProfile
    renderSettings
    renderWrapper
    applyPlugins
    mkDsh
    ;
}
