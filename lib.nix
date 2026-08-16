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
    optionalAttrs
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
    { settings, telemetry, providers ? { }, defaultModel ? null
    , webSearch ? null, webSearchProviders ? { }, llmDeepseek ? null }:
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
      # 配置承载型三态的 settings 侧:{}(启用零配置)不出段 —— 段空
      # 即上游默认;attrs 出段(yq merge 叠在树上);null 在 patch 层
      # 禁行,与 settings 无涉
      sectionIf = ns: attrs:
        if attrs == null || attrs == { } then { }
        else { ${ns} = (settings.${ns} or { }) // attrs; };
      # webSearch 后端参数:渲染进**选中后端**的 settings 段。段名从声明
      # 归一(namespace;裸 attrs 声明 = "web-search-<id>" 惯例;base 的
      # deepseek-official 段名 web-search-deepseek 由惯例覆盖,显式
      # row.settingsNamespace 优先)。仅选中段渲染(未选中行已禁,段无消费者)
      wsSelected = webSearch;
      wsSelectedDecl =
        if wsSelected == null then null
        else (webSearchProviders.${wsSelected} or { });
      wsSelectedNs =
        if wsSelected == "deepseek-official" then "web-search-deepseek"
        else if wsSelectedDecl ? row && wsSelectedDecl.row ? settingsNamespace then wsSelectedDecl.row.settingsNamespace
        else "web-search-${wsSelected}";
      wsSettings =
        let
          decl = if wsSelected == "deepseek-official"
            then wsSelectedDecl # 裸 attrs = 参数直渲染
            else if wsSelectedDecl ? settings then wsSelectedDecl.settings
            else if wsSelectedDecl ? row && wsSelectedDecl ? row.config then { }
            else if wsSelectedDecl ? row then { }
            else wsSelectedDecl;
        in
        if wsSelected == null then { }
        else sectionIf wsSelectedNs decl;
    in
    settings
    // (
      if telemetry.mode == null then { } else {
        telemetry = (settings.telemetry or { }) // { mode = telemetry.mode; };
      }
    )
    // (
      if providers == null || providers == { } then { } else {
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
    )
    // wsSettings
    // (sectionIf "llm-deepseek" llmDeepseek);

  # 上游 CLI 子命令集(自动):commander 在 bin.js 的注册模式
  # program.command("<name>")。上游加子命令自动进保留集;
  # 文件缺失(非 dsh 包/测试 stub)回落内置名单;文件在但零匹配 →
  # throw(上游布局变化,fail-loud 提示更新此处正则)
  upstreamSubcommands = package:
    let
      binJs = "${toString package}/lib/bin.js";
      fallback = [ "web" "plugin" ];
    in
    if !builtins.pathExists binJs then fallback
    else
      let
        parts = builtins.split ''program\.command\("''
          (builtins.readFile binJs);
        cmds = lib.filter (c: c != null) (
          map
            (p: if builtins.isString p
              then builtins.match ''([a-z0-9-]+)".*'' p
              else null)
            parts
        );
        names = lib.flatten cmds;
      in
      if names == [ ] then
        throw "nixdsh: upstream dsh CLI layout changed (no program.command registrations in ${binJs}); update upstreamSubcommands in lib.nix"
      else lib.unique names;

  # bash 补全(bash-completion 的 XDG_DATA_HOME 用户目录约定):
  # $1 位置补全 = 子命令分发名单 + 上游 web/plugin;--profile 值补全 =
  # 全部 profiles(含 web)。flags 不猜(各 app 自带 --help,launcher
  # allowUnknownOption 透传)。名单 build 期静态 → 补全零运行时开销
  renderCompletion =
    {
      name ? "dsh",
      subcommands ? [ ],   # 可分发的 profile 子命令(不含 web)
      profiles ? [ ],      # --profile 合法值(含 web)
      upstream ? [ ],      # 上游子命令(web/plugin)
    }:
    let
      wordList = concatStringsSep " " (lib.unique (subcommands ++ upstream));
      profileList = concatStringsSep " " (lib.unique (profiles ++ upstream));
    in
    ''
      # generated by nixdsh — subcommand dispatch: dsh <profile> ≡ dsh --profile <profile>
      _dsh() {
        local cur prev
        cur="''${COMP_WORDS[COMP_CWORD]}"
        prev="''${COMP_WORDS[COMP_CWORD-1]}"
        if [ "$COMP_CWORD" -eq 1 ] && [[ "$cur" != -* ]]; then
          COMPREPLY=( $(compgen -W "${wordList}" -- "$cur") )
          return
        fi
        if [ "$prev" = "--profile" ]; then
          COMPREPLY=( $(compgen -W "${profileList}" -- "$cur") )
          return
        fi
      }
      complete -F _dsh ${name}
    '';

  # agent 预设源校验(rc.5 dsh-agent-presets 实测):目录须含组合文件
  # agent.cordis.yml(preset.yml 元数据/.mjs 插件可选)。纯文件零构建,
  # 上游热发现免重启 —— 物化即生效
  validatePresets = presets:
    mapAttrs
      (name: p:
        if !builtins.pathExists "${toString p.source}/agent.cordis.yml" then
          throw "programs.dsh.presets.${name}.source: agent.cordis.yml missing in ${toString p.source} (a preset directory = agent.cordis.yml + optional preset.yml and .mjs plugins)"
        else p.source)
      presets;

  # skill 源校验(dsh-skill-filesystem 实测):单文件 .md 或目录束(目录
  # 须含 SKILL.md)。返回 { name → target 相对路径 }(文件 → <名>.md,
  # 目录 → <名>/),供 activation 物化;非法源 throw。
  # readFileType(非 pathType —— 后者是 lib.filesystem 函数,builtin
  # 只有 readFileType,记错名曾在全版本炸):能区分 directory/regular,
  # 文件与目录语义不同,显式判型比存在性探测更贴切
  validateSkills = skills:
    mapAttrs
      (name: s:
        let
          src = toString s.source;
          type = builtins.readFileType src;
        in
        if type == "directory" then
          if builtins.pathExists "${src}/SKILL.md" then "${name}"
          else throw "programs.dsh.skills.${name}.source: directory ${src} has no SKILL.md (a directory skill bundles <name>/SKILL.md + optional resources)"
        else if type == "regular" && lib.hasSuffix ".md" src then "${name}.md"
        else throw "programs.dsh.skills.${name}.source: ${src} must be a .md skill or a directory containing SKILL.md")
      skills;

  # ── secret 通道(通用模式,当前消费面 mcpServers)──────────────────
  # 上游实测约束:dsh MCP config.env/headers 是值直存(z.dict(String),无
  # apiKeyEnv 间接层),且子进程 spawn 用 scrubbedParentEnv 擦掉父环境里
  # KEY|PASSWORD|SECRET|TOKEN 名(官方注释:转交凭证"goes through the
  # spec's explicit env")—— 值必须在 config 里。而 profile bundle 是
  # 全局可读 store 工件,密钥值不可 build 期渲染。
  # 方案(同 nixpkgs replace-secret / sops-nix 哲学):store 渲染占位符
  # "@dsh-secret:<path>@",wrapper 启动期对物化副本注入真值 + chmod 600
  # (settingsPrelude 同机时机;轮换安全:每次启动重注,密钥文件更新即生效)
  secretPlaceholder = path: "@dsh-secret:${path}@";
  # 值渲染:string 直存;{ secretFile; prefix? } → 占位符(prefix 拼前;
  # submodule 输出 prefix 恒存在(null),须显式判空而非 `or`)
  renderSecretVal = v:
    if builtins.isString v then { text = v; refs = [ ]; }
    else if v ? secretFile then
      let pre = if v.prefix or null == null then "" else v.prefix; in
      { text = pre + secretPlaceholder (toString v.secretFile); refs = [ (toString v.secretFile) ]; }
    else { text = toString v; refs = [ ]; };
  # attrsOf 值渲染:返回 { data = 同形 attrs;text-only; refs = 去重 refs }
  renderSecretAttrs = attrs:
    let
      rendered = mapAttrs (_: renderSecretVal) attrs;
    in
    {
      data = mapAttrs (_: r: r.text) rendered;
      refs = lib.unique (concatMap (r: r.refs) (attrValues rendered));
    };

  # wrapper 渲染(TonyWu20 的 yq-merge 语义 + DSH_HOME):
  # - 声明 settings 每次启动 merge 进 settings.yaml:声明值覆盖同名键,本地其他键保留
  #   (dsh Web UI 会运行时改配置,yq merge 是唯一不与之打架的声明式方案)
  # - profile 子命令分发:dsh <profile> ... → dsh --profile <profile> ...(上游
  #   CLI 子命令集封闭 {web,plugin},`dsh web` 即官方的 profile-子命令样板,
  #   第三方 face 无入口,wrapper 层补同形态;名单含手写 profiles + 自动
  #   face,用户零声明)。web 排除:上游原生子命令已等价 boot profiles.web;
  #   其余撞上游子命令 → throw(拦截上游命令语义,如 plugin 的 pnpm 管理)
  # - profile 注入:调用无显式 --profile 且非 web/plugin 子命令(它们拒绝父级 --profile)时
  #   自动补 --profile <name>;fixedProfile 非 null 时强制绑定该 profile
  #   (face 分发改写后 --profile 已显式存在,注入逻辑自然跳过)
  renderWrapper =
    {
      cfg,
      pkgs,
      name ? "dsh",
      fixedProfile ? null,
      subcommands ? [ ],
    }:
    let
      effectiveProfile = if fixedProfile != null then fixedProfile else cfg.defaultProfile;
      # webSearch/llmDeepseek 不随 inherit:renderSettings 缺省 null,
      # stub cfg(无该键)与真实 cfg(默认 null)等价;显式 attrs 时模块
      # 系统保证键存在,inherit (cfg) 反而会炸 stub 调用方
      settingsJSON =
        if renderSettings { inherit (cfg) settings telemetry providers defaultModel; webSearch = cfg.webSearch or null; webSearchProviders = cfg.webSearchProviders or { }; llmDeepseek = cfg.llmDeepseek or null; } == { } then null
        else builtins.toJSON (renderSettings { inherit (cfg) settings telemetry providers defaultModel; webSearch = cfg.webSearch or null; webSearchProviders = cfg.webSearchProviders or { }; llmDeepseek = cfg.llmDeepseek or null; });
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
      # secret 注入块(mcpServers env/headers 占位符 → 真值):每次启动跑,
      # 轮换安全(secret 文件更新即生效);改动物化副本 patch 文件(用户
      # 目录,可 0600),store 工件永不含密钥。secret 文件缺失 → fail-loud
      # 退出,不静默带占位符启动。
      # 占位符清单 = mcpPatches 渲染行文本回收(单一事实源,防与渲染链
      # 漂移;insert 包裹后占位符在嵌套 config 里,扫整行 JSON)
      secretPrelude =
        let
          mcpRows = (applyPlugins { inherit cfg pkgs; }).mcpPatches;
          placeholders = lib.flatten
            (map
              (row:
                let m = builtins.match ".*(@dsh-secret:[^\"]*@).*" (builtins.toJSON row);
                in if m == null then [ ] else m)
              mcpRows);
        in
        optionalString (placeholders != [ ]) ''
          _secrets=(
          ${concatStringsSep "\n" (map (p: "  ${escapeShellArg p}") placeholders)}
          )
          for _pf in "$dsh_home"/profiles/*/cordis.patch.yml; do
            [ -f "$_pf" ] || continue
            _changed=0
            _tmp="$(mktemp "$_pf.XXXXXX")"
            cp "$_pf" "$_tmp"
            for _ph in "''${_secrets[@]}"; do
              if grep -qF "$_ph" "$_tmp"; then
                _path="$(printf '%s' "$_ph" | sed -e 's/^@dsh-secret://' -e 's/@$//')"
                if [ ! -r "$_path" ]; then
                  echo "dsh: secret file '$_path' (MCP placeholder) unreadable" >&2
                  rm -f "$_tmp"; exit 1
                fi
                ${getExe pkgs.replace-secret} "$_ph" "$_path" "$_tmp" || { rm -f "$_tmp"; exit 1; }
                _changed=1
              fi
            done
            if [ "$_changed" -eq 1 ]; then
              chmod 0600 "$_tmp"
              mv "$_tmp" "$_pf"
            else
              rm -f "$_tmp"
            fi
          done
        '';
      # 只给主 wrapper(fixedProfile = null)。仅拦 $1(与上游子命令同粒度),
      # -- 之后的位置参数不碰;web 排除(上游原生 web 子命令已等价 boot
      # profiles.web)。撞上游子命令(eval 期 throw,名单自动提取):
      # 上游子命令语义 ≠ profile boot(如 plugin 是 pnpm 管理),分发会
      # 静默拦截上游命令
      _clashAssert =
        let
          reserved = upstreamSubcommands cfg.package;
          clashing = filter (f: f != "web" && builtins.elem f reserved) subcommands;
        in
        if clashing != [ ] then
          throw "programs.dsh: profile/face names clash with upstream dsh subcommands (${concatStringsSep ", " clashing}; reserved: ${concatStringsSep ", " reserved}). Rename the profile or the face — dispatch would shadow the upstream command."
        else null;
      dispatchFaces = filter (f: f != "web") subcommands;
      faceDispatch =
        builtins.seq _clashAssert
          (optionalString (dispatchFaces != [ ]) ''
            if [ $# -gt 0 ]; then
              case "$1" in
                ${concatStringsSep "|" dispatchFaces})
                  _dsh_face="$1"
                  shift
                  set -- --profile "$_dsh_face" "$@"
                  ;;
              esac
            fi
          '');
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
      dsh_home="${cfg.dshHome}"
      ${secretPrelude}
      ${settingsPrelude}
      ${faceDispatch}
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
      # registry 尾名反查:键名 "dsh-tui" → "@deepseek-harness-tui/dsh-tui"
      # (nixvim 式零 source)。attr 名 <scope>/<pkg>,pkg == <键名> 或
      # "dsh-<键名>" 双形态;唯一匹配取之,空 = null(调用方决定报错语义),
      # 多匹配 throw 列候选(须显式 source)
      registryLookup = name:
        let
          table = pkgs.dshPlugins or { };
          tailOf = k: lib.last (lib.splitString "/" k);
          candidates = lib.filterAttrs
            (k: _: tailOf k == name || tailOf k == "dsh-${name}")
            table;
          ns = attrNames candidates;
        in
        if ns == [ ] then null
        else if builtins.length ns == 1 then table.${builtins.head ns}
        else throw "programs.dsh.plugins.${name}: registry tail-name lookup is ambiguous (${concatStringsSep ", " ns}); set source explicitly";
      # 名字→源:缺省 registry(不在 registry 且未显式给 source 时,mkPlugin
      # 端 passthru 缺 packageName 会 throw —— 提前给友好错误)。
      # face 插件跳过分发:源取 p.source / in-box 键名映射(headless →
      # @deepseek-ai/dsh-headless)/ registry 尾名反查
      faceSourceOf = name: p:
        if p.source != null then p.source
        else if inBoxFaces ? "@deepseek-ai/dsh-${name}" then "@deepseek-ai/dsh-${name}"
        else if registryLookup name != null then registryLookup name
        else throw "programs.dsh.plugins.${name}: face plugin requires a source (registry entry, in-box bundle, or explicit source)";
      sourceOf = name: p:
        if p.source != null then p.source
        else if pkgs ? dshPlugins && pkgs.dshPlugins ? ${name} then pkgs.dshPlugins.${name}
        else if registryLookup name != null then registryLookup name
        else throw "programs.dsh.plugins.${name}: no source given and '${name}' not in pkgs.dshPlugins (add it to plugins/names.txt and run the updater, or set source)";
      # 交互面插件 → 自动 profile(base + 本源)。face 插件互斥不参与分发
      # (进其他树 = duplicate entry / TTY 致死,均实测),功能插件分发到
      # 所有 face(profiles = [] 缺省语义含自动生成的 face)。
      # face 推导(源解析感知):显式 plugins.<name>.face > source 的
      # passthru.dshFace(registry 收录时人审)/ inBoxFaces(in-box 表) >
      # 零 source 时先解析源(registry 反查 derivation 同样带 dshFace)再读。
      # 无法纯自动判定互斥(id 冲突之外还有 TTY 等运行期约束,eval 期
      # 不可见),故判定下沉为插件元数据 —— 用户侧只需 enable。
      # face 名约束 kebab-case:它被拼进文件路径($DSH_HOME/profiles/<face>)
      # 与子命令名(dsh <face>),同上游 settingsNamespace 的模式
      validFace = f:
        builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" f != null;
      dshFaceOf = s:
        if lib.isDerivation s then (s.passthru or { }).dshFace or null
        else if builtins.isString s && inBoxFaces ? ${s} then inBoxFaces.${s}
        else null;
      deriveFace = name: p:
        if p.face != null then p.face
        else if p.source != null then dshFaceOf p.source
        else
          # 零 source:in-box 键名反查 > registry 反查(两者都返回源,读元数据)
          if inBoxFaces ? "@deepseek-ai/dsh-${name}" then inBoxFaces."@deepseek-ai/dsh-${name}"
          else if registryLookup name != null then dshFaceOf (registryLookup name)
          else null;
      # 最终 face 名:null = 非交互面;false = 显式压制(registry 标记的
      # face 当功能插件用)→ 也归 null;true = 从 attr 键派生(剥一次
      # "dsh-" 前缀,免 `dsh dsh-tui` 冗余子命令 —— cargo cargo-xx 惯例;
      # 字符串 face 与 registry 元数据不动:前者尊重显式,后者收录时
      # 已是人审终名);字符串 = 具体名。faceOf 之后只剩 null|true|str
      faceOf = name: p:
        let f = deriveFace name p; in
        if f == false then null else f;
      facePlugins =
        let
          enabled = lib.filterAttrs (name: p: p.enable && faceOf name p != null) cfg.plugins;
          faceName = name: p:
            let f = faceOf name p; in
            if f == true then lib.removePrefix "dsh-" name else f;
          faceNames = lib.attrValues (lib.mapAttrs faceName enabled);
          _dupAssert =
            if builtins.length faceNames != builtins.length (lib.unique faceNames) then
              throw "programs.dsh.plugins: duplicate face names (${concatStringsSep ", " faceNames})"
            else if any (f: !validFace f) faceNames then
              throw "programs.dsh.plugins: face names must be kebab-case ([a-z0-9-], got: ${concatStringsSep ", " faceNames}) — face becomes a profile directory and the dsh <face> subcommand name"
            else null;
           # 依赖冲突:skills/presets 的发现插件在 base 树默认启用,显式
           # disable 会让物化文件无人消费 —— 静默失效比报错更糟,eval 期
           # fail-loud。(MCP 插件随 insert 行自带,无此冲突;presets 的
           # roster 行只在 tui/web 树存在,headless 本就无 preset 语义,
           # 属上游 per-face 行为而非冲突)
           # 三态 typed 选项 × inBoxPlugins 同组 id 显式对着干 → 同理
           # fail-loud(typed 层与用户层会产出语义冲突的行组)
           _usageAssert =
             let
               inbox = id: (cfg.inBoxPlugins or { }).${id} or { enable = null; };
               # 中间绑定而非 `inbox "x".enable` 直连:避免选择器解析歧义
               skillProvider = inbox "skill-filesystem";
               presetRoster = inbox "agent-presets";
                wsNull = (cfg.webSearch or null) == null;
                dshNull = (cfg.llmDeepseek or null) == null;
                piAiNull = (cfg.providers or { }) == null;
                wsProviders = cfg.webSearchProviders or { };
                # 选择器形态:webSearch 非 null → id 必须在声明表 ∪ base
                # 自带集;非 base id 必须已声明(包源/参数都在声明条目)
                wsKnown =
                  [ "deepseek-official" ] ++ (attrNames wsProviders);
                wsUnknown = !wsNull && !builtins.elem cfg.webSearch wsKnown;
                wsOrphanProviders = wsNull && wsProviders != { };
                # typed 启用(非 null)但 inBoxPlugins 显式禁同组行
                wsClash =
                 !wsNull && (inbox "web").enable == false
                 || !wsNull && (inbox "web-search-deepseek").enable == false
                 || !wsNull && (inbox "tool-web").enable == false
                 || !wsNull && (inbox "web-search-exa").enable == false;
               dshClash = !dshNull && (inbox "llm-deepseek").enable == false;
               piAiClash = piAiNull && (inbox "llm-pi-ai").enable == false;
               # typed 禁用(null)但配置仍指向它 —— 意图自相矛盾。
               # 注意:defaultModel.provider 无法 eval 期判归属(pi-ai
               # catalog 路由名与 llm-deepseek id "deepseek-official"
               # 无先验区分,不猜) —— 只查可判定的 settings 声明;
               # 唯一可靠例外是 deepseek-official(llm-deepseek 固定 id)
               piAiOrphan = piAiNull && (cfg.settings or { }) ? "llm-pi-ai";
               dshOrphan = dshNull && (cfg.defaultModel or null) != null
                 && cfg.defaultModel.provider == "deepseek-official";
             in
             if (cfg.skills or { }) != { } && skillProvider.enable == false then
               throw "programs.dsh: skills are declared but inBoxPlugins.skill-filesystem.enable = false — no filesystem skill provider would discover them; remove the skills or re-enable the provider"
             else if (cfg.presets or { }) != { } && presetRoster.enable == false then
               throw "programs.dsh: presets are declared but inBoxPlugins.agent-presets.enable = false — the preset roster is disabled; remove the presets or re-enable the roster"
              else if wsClash then
                throw "programs.dsh: webSearch is set but inBoxPlugins disables one of web/web-search-deepseek/web-search-exa/tool-web — use webSearch alone (null disables the capability rows)"
              else if wsUnknown then
                throw "programs.dsh: webSearch = \"${cfg.webSearch}\" is not a declared webSearchProviders entry nor \"deepseek-official\" — declare the backend in webSearchProviders or select a known id"
              else if wsOrphanProviders then
                throw "programs.dsh: webSearchProviders is non-empty but webSearch = null (capability disabled) — declared backends would never run; set webSearch to a declared id or clear the table"
             else if dshClash then
               throw "programs.dsh: llmDeepseek is set but inBoxPlugins.\"llm-deepseek\".enable = false — use llmDeepseek alone (null disables the row)"
             else if piAiClash then
               throw "programs.dsh: providers = null but inBoxPlugins.\"llm-pi-ai\".enable = false is redundant — providers = null already disables the row"
             else if piAiOrphan then
               throw "programs.dsh: providers = null but settings.\"llm-pi-ai\" is declared (or defaultModel routes through pi-ai) — a disabled adapter cannot consume them; set providers = {} or drop the declarations"
             else if dshOrphan then
               throw "programs.dsh: llmDeepseek = null but defaultModel.provider = \"deepseek-official\" — the default route points at a disabled adapter; enable llmDeepseek or re-route defaultModel"
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
        builtins.seq _dupAssert (builtins.seq _usageAssert gen);
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
      # MCP 服务器行(rc.5 dsh-mcp-client 实测):插件不在默认树,每 server
      # 一个条目,包裹成 insert 行 —— cordis patch applier 对组合树里不
      # 存在的 id 只 warn+skip(实测 cordis-plugin-include:`patch: entry
      # not found`,7 行全丢、/mcp 空屏),新条目必须走 insert 通道
      # (data.push)。config 判别联合由 transport 定形;null/空省略;
      # settings 逃生口最后并。env/headers 值支持 secretFile 形态 →
      # 占位符渲染(见 renderSecretVal),refs 收集给 wrapper 注入。
      # 插件随行:设置 mcpServers 即插入 @deepseek-ai/dsh-mcp-client,
      # 无法经 inBoxPlugins 关闭(id 不在树上,disable 行同样 not-found
      # 跳过)—— 不装就删 mcpServers 条目
      mcpSecret =
        let
          renderServer = name: m:
            let
              common = { inherit (m) transport; serverName = name; }
                // (lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                  toolCallTimeoutMs = m.toolCallTimeoutMs or null;
                  failOnStartupError = m.failOnStartupError or null;
                })
                // (m.settings or { });
              body =
                if m.transport == "stdio" then
                  lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                    inherit (m) args env;
                    command = m.command or null;
                    cwd = m.cwd or null;
                  }
                else
                  lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                    url = m.url or null;
                      headers = m.headers or { };
                    };
            in
            {
              id = "mcp-${name}";
              name = "@deepseek-ai/dsh-mcp-client";
              config = common // body;
            };
          renderedServers = mapAttrs renderServer (cfg.mcpServers or { });
          # env/headers 二次渲染为占位符,同时收集 refs
          withSecrets = mapAttrs
            (name: row:
              let
                env' = if row.config ? env then (renderSecretAttrs row.config.env).data else { };
                headers' = if row.config ? headers then (renderSecretAttrs row.config.headers).data else { };
                allRefs =
                  (if row.config ? env then (renderSecretAttrs row.config.env).refs else [ ])
                  ++ (if row.config ? headers then (renderSecretAttrs row.config.headers).refs else [ ]);
              in
              {
                row = row // {
                  config = removeAttrs row.config [ "env" "headers" ]
                    // (optionalAttrs (env' != { }) { env = env'; })
                    // (optionalAttrs (headers' != { }) { headers = headers'; });
                };
                refs = allRefs;
              })
            renderedServers;
        in
        {
          rows = map (row: { insert = [ row ]; })
            (attrValues (mapAttrs (_: w: w.row) withSecrets));
          refs = lib.unique (concatMap (w: w.refs) (attrValues withSecrets));
        };
      mcpPatches = mcpSecret.rows;
      mcpSecretRefs = mcpSecret.refs;
       # 配置承载型三态的 patch 侧。webSearch 是选择器形态(README:声明
       # 必有效,在场或被选择器解释):
       #   null  → 骨架(web/tool-web)+ base 自带后端(deepseek)全禁
       #   str   → 骨架启用(树自带行不动);未选中后端禁行(死卡清理:
       #           未选中 provider 在场只有死 UI/必败调用)
       # 追加在 inBoxPatches 之后,同 id 后行胜出(_usageAssert 拦显式
       # 冲突;顺带的 enable=null 不表态无冲突)。
       # ⚠ "选中才启用"的前提:provider 切换在上游是**行级变化**
       # (dsh-web 源码实证:WebRuntime 无 settings 命名空间,
       # searchProvider 是行 Config,构造器一次性定格,env
       # DSH_WEB_SEARCH_PROVIDER 也仅 boot 读)——声明并在场但未选中
       # 只会留死卡,禁行无运行时代价。若上游将来把选择 id 接进 settings
       # 热重载(即可运行时切换),此策略应改为"声明即在,选择器热切",
       # 本行组随之收敛为能力骨架行(web/tool-web)。
       cfgWs = cfg.webSearch or null;
       cfgWsProviders = cfg.webSearchProviders or { };
       # 后端声明归一:id → { rowId; rowName(null=base 自带); rowConfig;
       # source(null=base 自带); namespace(null=无 settings 段) }。
       # 预置 = 默认值里的完整声明(语法糖,非代码分支):新后端接入 =
       # 一条声明带 row/source,零 nixdsh 改动(开放注册表)
       wsBackend = id: p:
         let
           # 显式声明(带 row.name 的 = 非 base 自带);裸 attrs = base
           # 自带后端的纯参数声明(向后兼容预置写法)
           hasRow = p ? row && p.row ? name;
           # 行 id 缺省 = 包名尾段剥 dsh- 前缀:@tonydua/dsh-web-search-exa
           # → web-search-exa(与包自 bundle patch 的行 id 约定一致);
           # 尾段已带 web-search- 前缀则原样,无前缀才补(命名自由的后端)
           rowIdOf = name:
             let tail = lib.removePrefix "dsh-" (lib.last (lib.splitString "/" name)); in
             if lib.hasPrefix "web-search-" tail then tail else "web-search-${tail}";
         in
         {
           rowId =
             if hasRow then (p.row.id or (rowIdOf p.row.name))
             else "web-search-${id}";
           rowName = if hasRow then p.row.name else null;
           rowConfig = if hasRow then (p.row.config or { }) else (removeAttrs p [ "settings" "source" ]);
           source = if hasRow then (p.source or null) else null;
           namespace = if hasRow then (p.row.settingsNamespace or null) else "web-search-${id}";
         };
       wsBackends = mapAttrs wsBackend
         (cfgWsProviders // { "deepseek-official" = cfgWsProviders."deepseek-official" or { }; });
       # 未选中后端行(声明了但未选中 → 禁行;base 自带的 deepseek 行
       # 同理:能力禁用或选中别的)
       wsDisable =
        # 骨架:能力禁用时
        (lib.optionals (cfgWs == null) [ "web" "tool-web" ])
        # base 自带 deepseek 行:能力禁用,或选中的不是它
        ++ (lib.optionals (cfgWs == null || cfgWs != "deepseek-official")
          [ "web-search-deepseek" ])
        # 非 base 后端行(声明了但未选中;有 rowId 的才算得出)
        ++ (lib.filter (id: id != cfgWs && wsBackends.${id}.rowName != null)
          (attrNames cfgWsProviders));
       capabilityPatches =
        (map (id: { inherit id; disabled = true; }) wsDisable)
        ++ (lib.optionals ((cfg.llmDeepseek or null) == null)
          [ { id = "llm-deepseek"; disabled = true; } ])
        ++ (lib.optionals ((cfg.providers or { }) == null)
          [ { id = "llm-pi-ai"; disabled = true; } ]);
      # 选中后端(带 row.name = 非 base)→ insert 行;base 自带后端无行
      #(树里已有)。行 config = 声明的 row.config
      wsProviderRows =
        let sel = if cfgWs == null then null else wsBackends.${cfgWs} or null; in
        lib.optionals (sel != null && sel.rowName != null) [
          {
            id = sel.rowId;
            name = sel.rowName;
            config = sel.rowConfig;
          }
        ];
      # 选中后端的包源(非 base 自带才有;声明 source 或 registry 尾名反查)
      wsProviderSources =
        let sel = if cfgWs == null then null else wsBackends.${cfgWs} or null; in
        lib.optionals (sel != null && sel.rowName != null)
          (if sel ? source && sel.source != null && sel != null then [ sel.source ]
           else [ (registryLookup sel.rowId) ]);
      # 选中非 base 后端 → web 行重述 searchProvider(patch 整行替换,
      # base 行只此一键,重述干净)
      wsSelectorRow =
        if cfgWs != null && cfgWs != "deepseek-official" then
          [ { id = "web"; config = { searchProvider = cfgWs; }; } ]
        else [ ];
    in
    {
      # 全局 in-box 条目行(typed 插件层 patch 之后再追加;同一 id 后行胜出)
      inherit inBoxPatches;
      # MCP 服务器行(同样全局,追加在 in-box 行之后)
      mcpPatches = mcpPatches;
      # 三态 typed 选项的行组(disable + 后端行 + 选择器行;追加在 in-box 行之后)
      inherit capabilityPatches wsProviderRows wsSelectorRow;
      # secret 占位符引用的文件路径清单(wrapper 注入块消费)
      inherit mcpSecretRefs;
      # face 插件自动生成的 profile(与显式 profiles 同形,键 = face 名)
      inherit facePlugins;
      # profile 名 → { extraPlugins; extraPatches; }(追加在原始列表之后;
      # 覆盖显式 profile 与自动 face 两类)
      perProfile = listToAttrs
        (map
          (profileName: nameValuePair profileName {
            extraPlugins =
              (map (c: c.plugin.source)
                (filter (c: builtins.elem profileName c.profiles) contributions))
              ++ (lib.filter (s: s != null) wsProviderSources);
            extraPatches =
              (concatMap (c: c.patches)
                (filter (c: builtins.elem profileName c.profiles) contributions))
              ++ inBoxPatches
              ++ capabilityPatches
              ++ wsProviderRows
              ++ wsSelectorRow
              ++ mcpPatches;
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
          profile = mkProfile ({ inherit name; } // (withPlugins name p));
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
    renderCompletion
    upstreamSubcommands
    validatePresets
    validateSkills
    applyPlugins
    mkDsh
    ;
}
