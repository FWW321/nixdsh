# settings 渲染与源校验:
#   renderSettings  freeform settings 为底,typed core(telemetry/providers/
#                   defaultModel/webSearch/webFetch/llmDeepseek)后合并覆盖
#   validatePresets agent 预设源校验(目录须含 agent.cordis.yml)
#   validateSkills  skill 源校验(.md 平铺 / 目录束含 SKILL.md)
{ lib, secretEnvName }:

let
  inherit (lib) mapAttrs;

  # settings 渲染:freeform settings 为底,typed core(telemetry.mode /
  # providers / defaultModel)后合并覆盖。providers 渲染进 llm-pi-ai 命名
  # 空间段 —— dsh-llm-pi-ai 的用户层(上游:cordis 树 base 配置 ⊕ 本段,
  # 按 provider 深合并,免重启);typed 条目逐 provider 覆盖 freeform 同名
  # 条目;defaultModel 渲染进 agent-default-model 段(schema 实测于源码)
  renderSettings =
    { settings, telemetry, providers ? { }, defaultModel ? null
    , webSearch ? null, webSearchProviders ? { }, llmDeepseek ? null
    , webFetch ? null, webFetchProviders ? { } }:
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
          # secretFile 派生:显式 apiKeyEnv 优先,缺省从文件名派生(自描述)
          apiKeyEnv =
            let env = p.apiKeyEnv or null; in
            if env != null then env
            else if (p.secretFile or null) != null then secretEnvName p.secretFile
            else null;
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
      # fetch 后端参数:镜像 wsSettings(选中段才渲染;段名 web-fetch-<id>
      # 或 row.settingsNamespace 覆盖)
      wfSelected = webFetch;
      wfSelectedDecl =
        if wfSelected == null then null
        else (webFetchProviders.${wfSelected} or { });
      wfSelectedNs =
        if wfSelectedDecl ? row && wfSelectedDecl.row ? settingsNamespace then wfSelectedDecl.row.settingsNamespace
        else "web-fetch-${wfSelected}";
      wfSettings =
        let
          decl =
            if wfSelectedDecl ? settings then wfSelectedDecl.settings
            else { };
        in
        if wfSelected == null then { }
        else sectionIf wfSelectedNs decl;
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
    // wfSettings
    // (sectionIf "llm-deepseek" llmDeepseek);

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
in
{
  inherit renderSettings validatePresets validateSkills;
}
