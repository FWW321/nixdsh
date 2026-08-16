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
    any
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

  # in-box 交互面:bundle 名 → face 名("web" 被 dsh web 子命令硬编码 boot)。
  # base 不在表中(公共内核层,不是交互面)。第三方交互面由 registry 的
  # face 字段物化(plugins/overlay.nix passthru.dshFace),显式 plugins.<name>.face
  # 优先生效 —— 三级推导:显式声明 > registry 元数据 > in-box 表
  inBoxFaces = {
    "@deepseek-ai/dsh-web-app" = "web";
    "@deepseek-ai/dsh-headless" = "headless";
  };

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
      # 显式 userPatchesFile 是全权委托,不再追加任何行(typed 层产物进
      # userPatches,同样不落;需要共存时改用内联 userPatches)
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
      # models 行缺 name 时补 "<供应商显示名>/<id>":上游回落是裸 id
      # (实测 rc.5 dsh-llm-pi-ai:name ?? catalog 基名 ?? id),多路由同名
      # 模型在 /model 无法区分;显式 name 原样保留,modelOverrides 不补
      # (其语义就是只改指定字段,catalog 模型已有可读基名)
      renderProvider = key: p:
        let
          # submodule 里 displayName 恒存在(default null),`or` 不触发,须显式判空
          display = p.displayName or null;
          label = if display == null then key else display;
          models = map
            (m: if m ? name then m else m // { name = "${label}/${m.id}"; })
            (p.models or [ ]);
        in
        (lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
          apiKeyEnv = p.apiKeyEnv or null;
          displayName = p.displayName or null;
          api = p.api or null;
          baseURL = p.baseURL or null;
          inherit models;
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
          providers = freeformProviders // (mapAttrs (k: renderProvider k) providers);
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
      # 端 passthru 缺 packageName 会 throw —— 提前给友好错误)。
      # face 插件跳过:它不进分发,源直接取自声明(p.source 或键名映射的
      # in-box bundle 名,如 headless → @deepseek-ai/dsh-headless)
      faceSourceOf = name: p:
        if p.source != null then p.source
        else if inBoxFaces ? "@deepseek-ai/dsh-${name}" then "@deepseek-ai/dsh-${name}"
        else throw "programs.dsh.plugins.${name}: face plugin requires an explicit source (or registry entry with face metadata)";
      sourceOf = name: p:
        if p.source != null then p.source
        else if pkgs ? dshPlugins && pkgs.dshPlugins ? ${name} then pkgs.dshPlugins.${name}
        else throw "programs.dsh.plugins.${name}: no source given and '${name}' not in pkgs.dshPlugins (add it to plugins/names.txt and run the updater, or set source)";
      # 交互面插件 → 自动 profile(base + 本源)。face 插件互斥不参与分发
      # (进其他树 = duplicate entry / TTY 致死,均实测),功能插件分发到
      # 所有 face(profiles = [] 缺省语义含自动生成的 face)。
      # face 三级推导:显式 plugins.<name>.face > source derivation 的
      # passthru.dshFace(registry 收录时人审) > inBoxFaces(in-box 表)。
      # 无法纯自动判定互斥(id 冲突之外还有 TTY 等运行期约束,eval 期
      # 不可见),故判定下沉为插件元数据 —— 用户侧只需 enable。
      # face 名约束 kebab-case:它被拼进文件路径($DSH_HOME/profiles/<face>)
      # 与 wrapper 名(dsh-<face>),同上游 settingsNamespace 的模式
      validFace = f:
        builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" f != null;
      deriveFace = name: p:
        if p.face != null then p.face
        else if p.source != null && lib.isDerivation p.source
          && (p.source.passthru or { }).dshFace or null != null then p.source.passthru.dshFace
        else if p.source != null && builtins.isString p.source
          && inBoxFaces ? ${p.source} then inBoxFaces.${p.source}
        # source 未给 → 按键名反查 in-box(web-app/headless 零声明齐活)
        else if p.source == null && inBoxFaces ? "@deepseek-ai/dsh-${name}"
          then inBoxFaces."@deepseek-ai/dsh-${name}"
        else null;
      # 最终 face 名:null = 非交互面;false = 显式压制(registry 标记的
      # face 当功能插件用)→ 也归 null;true = 从 attr 键派生(module system
      # 键唯一 → 无碰撞);字符串 = 具体名。faceOf 之后只剩 null|true|str
      faceOf = name: p:
        let f = deriveFace name p; in
        if f == false then null else f;
      facePlugins =
        let
          enabled = lib.filterAttrs (name: p: p.enable && faceOf name p != null) cfg.plugins;
          faceName = name: p:
            let f = faceOf name p; in
            if f == true then name else f;
          faceNames = lib.attrValues (lib.mapAttrs faceName enabled);
          _dupAssert =
            if builtins.length faceNames != builtins.length (lib.unique faceNames) then
              throw "programs.dsh.plugins: duplicate face names (${concatStringsSep ", " faceNames})"
            else if any (f: !validFace f) faceNames then
              throw "programs.dsh.plugins: face names must be kebab-case ([a-z0-9-], got: ${concatStringsSep ", " faceNames}) — face becomes a profile directory and dsh-<face> wrapper name"
            else null;
          gen = lib.mapAttrs'
            (name: p:
              let fname = faceName name p; in
              lib.nameValuePair fname (
                if p.profiles != [ ] then
                  throw "programs.dsh.plugins.${name}: face plugin cannot also list target profiles (faces are mutually exclusive trees)"
                else if builtins.elem fname (attrNames cfg.profiles) then
                  throw "programs.dsh: face '${fname}' conflicts with explicitly declared profiles.${fname}"
                else {
                  plugins = [ "@deepseek-ai/dsh-base" (faceSourceOf name p) ];
                  userPatchesFile = null;
                  userPatches = [ ];
                }
              ))
            enabled;
        in
        builtins.seq _dupAssert gen;
      allProfileNames = (attrNames cfg.profiles) ++ (attrNames facePlugins);
      targetsFor = p:
        if p.profiles == [ ] then allProfileNames
        else filter (n: builtins.elem n allProfileNames) p.profiles;
      patchRows = p:
        (lib.optional (p.settings != { }) (
          if p.patchId == null then
            throw "programs.dsh.plugins: settings given but patchId is null"
          else { id = p.patchId; config = p.settings; }
        ))
        ++ p.patches;
      contributions = mapAttrsToList
        (name: con: {
          profiles = targetsFor con;
          plugin = { inherit name; source = sourceOf name con; };
          patches = patchRows con;
        })
        (lib.filterAttrs (name: p: p.enable && faceOf name p == null) cfg.plugins);
      # in-box 条目行(全局,进所有 profile 的用户 patch 层;行级 disabled 键
      # 是 cordis loader 原生语义,实测可双向覆盖 bundle 层的 disabled)
      inBoxPatches =
        mapAttrsToList
          (id: p:
            { inherit id; }
            // (lib.optionalAttrs (p.enable != null) { disabled = !p.enable; })
            // (lib.optionalAttrs (p.config != { }) { inherit (p) config; }))
          cfg.inBoxPlugins;
    in
    {
      # 全局 in-box 条目行(typed 插件层 patch 之后再追加;同一 id 后行胜出)
      inherit inBoxPatches;
      # face 插件自动生成的 profile(与显式 profiles 同形,键 = face 名)
      inherit facePlugins;
      # profile 名 → { extraPlugins; extraPatches; }(追加在原始列表之后;
      # 覆盖显式 profile 与自动 face 两类)
      perProfile = listToAttrs
        (map
          (profileName: nameValuePair profileName {
            extraPlugins =
              map (c: c.plugin.source)
                (filter (c: builtins.elem profileName c.profiles) contributions);
            extraPatches =
              (concatMap (c: c.patches)
                (filter (c: builtins.elem profileName c.profiles) contributions))
              ++ inBoxPatches;
          })
          allProfileNames);
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
      allProfiles = cfg.profiles // applied.facePlugins;
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
        allProfiles;
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
