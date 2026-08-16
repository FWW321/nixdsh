# in-box bundles 与 profile 三层模型(mkPlugin/mkProfile/buildProfile)
#
#   mkPlugin      插件源(flake=false input 路径/derivation) → 插件记录
#                 读 package.json 取 packageName 与 dsh.bundle.patch(有 patch 才是 profile layer)
#   mkProfile     插件有序组合 → profile 声明(in-box 名单 + nix 插件分类,唯一性校验)
#   buildProfile  profile 声明 → 不可变 store 工件:
#                 package.json(dsh.profile.bundles 层序 + dependencies) + node_modules/ 符号链接
#                 + cordis.patch.yml(用户 patch 层)。层序在求值期纯 Nix 计算,derivation 只做链接
#
# in-box bundles:dsh 自带、随安装分发,profile 只引用名字不做 symlink
{ lib }:

let
  inherit (lib)
    concatStringsSep
    escapeShellArg
    filter
    listToAttrs
    nameValuePair
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
in
{
  inherit inBoxNames inBoxFaces mkPlugin mkProfile buildProfile;
}
