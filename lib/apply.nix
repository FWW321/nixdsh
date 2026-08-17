# typed 插件层 → 各 profile 的增量渲染(nixvim 式):
#   plugins.<name>.enable → 源(source 或 pkgs.dshPlugins.<name>)追加进目标
#   profile 的 plugins;settings/patches 渲染为 patch 行追加进其 userPatches
# 目标:plugin.profiles 非空取其与已声明 profile 的交集;空 = 所有 profile
# patchId 语义:settings 非空时才要求;行 = { id; config = settings; }
#
# 同时承载:face 推导与自动 profile、_usageAssert(typed×inBox 冲突拦截)、
# in-box 行、MCP insert 行、webSearch/webFetch 缝行组(disable/insert/选择器)
{ lib, inBoxFaces, renderSecretAttrs, secretEnvName }:

let
  inherit (lib)
    any
    attrNames
    attrValues
    concatMap
    concatStringsSep
    filter
    listToAttrs
    mapAttrs
    mapAttrsToList
    nameValuePair
    optionalAttrs
    ;

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
               # 无先验区分,不猜)—— 只查可判定的 settings 声明;
               # 唯一可靠例外是 deepseek-official(llm-deepseek 固定 id)
               piAiOrphan = piAiNull && (cfg.settings or { }) ? "llm-pi-ai";
               dshOrphan = dshNull && (cfg.defaultModel or null) != null
                 && cfg.defaultModel.provider == "deepseek-official";
                # fetch 缝(镜像 ws 组):无 base 自带集,选中必在声明表
                wfNull = (cfg.webFetch or null) == null;
                wfProviders = cfg.webFetchProviders or { };
                wfUnknown = !wfNull && !builtins.elem cfg.webFetch (attrNames wfProviders);
                wfOrphanProviders = wfNull && wfProviders != { };
                wfClash = !wfNull && (inbox "tool-web").enable == false;
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
              else if wfClash then
                throw "programs.dsh: webFetch is set but inBoxPlugins disables tool-web — the fetch tool row must stay enabled (webFetch renders its fetch: true restatement)"
              else if wfUnknown then
                throw "programs.dsh: webFetch = \"${cfg.webFetch}\" is not a declared webFetchProviders entry — the fetch seam has no base-shipped backend; declare the backend first"
              else if wfOrphanProviders then
                throw "programs.dsh: webFetchProviders is non-empty but webFetch = null (capability disabled) — declared backends would never run; set webFetch to a declared id or clear the table"
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
      # ── 强一致性:face 树独占插件通道 ──────────────────────────────
      # 手写 profile 嵌 face bundle(交互插件)→ throw。软一致性的三个
      # 漏洞(face=false 压制/face 改名/手写树绕开推导)全部源于双通道
      # 都能建交互树;收口后 per-插件选项(defaultPreset)恒有锚,face
      # 改名自动跟随,树生命周期严格绑定插件。
      # 检测:in-box 字符串命中 inBoxFaces(web-app/headless)/ derivation
      # 源带 passthru.dshFace(registry 收录时人审)。路径源无元数据,
      # 不可检 —— 文档纪律:交互 bundle 走插件通道。
      # 手写 profiles 的存在本身合法(非交互命名组合:base+功能插件+
      # patches);userPatchesFile 是全权委托,检测不到,同属文档纪律。
      _faceExclusivityAssert =
        let
          isFaceSource = s:
            builtins.isString s && inBoxFaces ? ${s}
            || lib.isDerivation s && (s.passthru or { }).dshFace or null != null;
          offenders =
            concatMap
              (pname:
                let p = (cfg.profiles or { }).${pname}; in
                map
                  (s: { profile = pname; source = s; })
                  (filter isFaceSource (p.plugins or [ ])))
              (attrNames (cfg.profiles or { }));
          fmt = o: "${o.profile} ← ${if builtins.isString o.source then o.source else toString o.source}";
        in
        if offenders != [ ] then
          throw "programs.dsh: face bundles in hand-written profiles (${concatStringsSep "; " (map fmt offenders)}) — interactive trees come exclusively from the plugin channel (plugins.<name>.enable auto-generates the face profile); hand-written profiles are for non-interactive named compositions"
        else null;
      allProfileNames = (attrNames cfg.profiles) ++ (attrNames facePlugins);

      # ── 默认 preset(per-face 值 + 全局兜底,行 patch 形态)──────────
      # 消费者是树上的 agent-presets roster 行,不是插件 —— 但值的
      # 声明点挂交互插件(defaultPreset 经 faceName 找树,改名自动跟随)。
      # 非 face 插件设值 → 无树可渲染 → throw(强一致性的对偶面)。
      # settings 协调:行 config 是 settings 的 base,settings 用户层
      # 恒胜 → 任一 per-face 值生效时全局不进 settings(否则遮蔽全部
      # 行),改下沉为各树行 patch 的兜底值。
      globalDefaultPreset = cfg.defaultPreset or null;
      _defaultPresetAssert =
        let
          enabledPlugins = lib.filterAttrs (_: p: p.enable) (cfg.plugins or { });
          noTree = filter
            (name:
              (cfg.plugins.${name}.defaultPreset or null) != null
              && faceOf name cfg.plugins.${name} == null)
            (attrNames enabledPlugins);
          freeformClash =
            (cfg.settings or { }) ? "agent-presets"
            && ((cfg.defaultPreset or null) != null
              || any (name: (cfg.plugins.${name}.defaultPreset or null) != null)
                (attrNames enabledPlugins));
        in
        if noTree != [ ] then
          throw "programs.dsh.plugins.${builtins.head noTree}: defaultPreset set on a non-face plugin (no interactive tree to render into — face trees come exclusively from face plugins; global defaultPreset covers the rest)"
        else if freeformClash then
          throw "programs.dsh: settings.\"agent-presets\" freeform declaration conflicts with defaultPreset/plugins.<name>.defaultPreset — the settings user layer would shadow the row patches; drop the freeform section or the typed option"
        else null;
      # per-插件值 → 树名(经 faceName 推导,与 faceProfiles 生成同链)
      faceDefaultPresetRows =
        let
          faceNameOf = name: p:
            let f = faceOf name p; in
            if f == true then lib.removePrefix "dsh-" name else f;
          fromPlugins = lib.flatten (mapAttrsToList
            (name: p:
              let v = p.defaultPreset or null; in
              if p.enable && v != null then [{ tree = faceNameOf name p; value = v; }] else [ ])
            (cfg.plugins or { }));
        in
        listToAttrs (map (e: nameValuePair e.tree e.value) fromPlugins);
      hasFaceDefaultPreset = faceDefaultPresetRows != { };
      # 最终行集:per-树值,缺省回落全局(仅自动 face 树有 roster 行;
      # 手写 profile/headless 无行 → 行 patch warn-skip 无害,不渲染)
      defaultPresetRows =
        if !hasFaceDefaultPreset then { }
        else
          mapAttrs
            (tree: _:
              { id = "agent-presets"; config.default = faceDefaultPresetRows.${tree} or globalDefaultPreset; })
            facePlugins;
      # 只设全局 → settings 热缝(renderSettings 消费);设了 per-face
      # → 全局不进 settings(hasFaceDefaultPreset 协调),树行兜底已含
      effectiveGlobalPreset =
        if hasFaceDefaultPreset then null else globalDefaultPreset;

      # ── 权限模式(新会话默认;宿主组合层,per-face 物理成立)─────────
      # 三行同步一致(sandbox-policy.mode / approval.policy /
      # permission.defaultPreset),knobs 不匹配任何 preset → 上游
      # 推断 "custom" → throw(dsh-permission-presets :116)。
      # 与 defaultPreset 的 settings 协调不同:permission 的 settings
      # 命名空间是 UI 手选的运行时用户层,nixdsh 不写也不清 —— 行
      # config 是组合层基底,UI 手选后遮蔽本选项(caveat 入文档)
      _permissionAssert =
        let
          enabledPlugins = lib.filterAttrs (_: p: p.enable) (cfg.plugins or { });
          noTree = filter
            (name: (cfg.plugins.${name}.permissionMode or null) != null && faceOf name cfg.plugins.${name} == null)
            (attrNames enabledPlugins);
        in
        if noTree != [ ] then
          throw "programs.dsh.plugins.${builtins.head noTree}: permissionMode set on a non-face plugin (no interactive tree to render into; global programs.dsh.permissionMode covers the rest)"
        else null;
      globalPermissionMode = cfg.permissionMode or null;
      # per-树值(推导链同 defaultPresetRows);perProfile 注入三行,
      # later-wins 胜过全局行(全局也进 perProfile 的同一列表前部)
      facePermissionRows =
        let
          faceNameOf = name: p:
            let f = faceOf name p; in
            if f == true then lib.removePrefix "dsh-" name else f;
          fromPlugins = lib.flatten (mapAttrsToList
            (name: p:
              let v = p.permissionMode or null; in
              if p.enable && v != null then [{ tree = faceNameOf name p; value = v; }] else [ ])
            (cfg.plugins or { }));
        in
        listToAttrs (map (e: nameValuePair e.tree e.value) fromPlugins);
      permissionRowsFor = tree:
        let mode = facePermissionRows.${tree} or globalPermissionMode; in
        if mode == null then [ ]
        else [
          { id = "sandbox-policy"; config.mode = mode; }
          { id = "approval"; config.policy = if mode == "danger-full-access" then "never" else "ask"; }
          { id = "permission"; config.defaultPreset = mode; }
        ];
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
       # 追加在 inBoxPatches 之后,同 id 后行胜过(_usageAssert 拦显式
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
            # submodule 输出 row.id 恒存在(default null),`or` 不触发,
            # 须显式判空(裸 attrs 声明两种路径都走对)
            rowId =
              if hasRow then
                (let id = p.row.id or null; in
                 if id != null then id else rowIdOf p.row.name)
              else "web-search-${id}";
            rowName = if hasRow then p.row.name else null;
            # secretFile 派生:行 config 未显式给 apiKeyEnv 时注入派生值
            #(行自描述,免疫上游默认漂移;显式 apiKeyEnv 优先)
            rowConfig =
              let
                base = if hasRow then (p.row.config or { }) else (removeAttrs p [ "settings" "source" ]);
              in
              if hasRow && (p.row.secretFile or null) != null && !(base ? apiKeyEnv) then
                base // { apiKeyEnv = secretEnvName p.row.secretFile; }
              else base;
          source = if hasRow then (p.source or null) else null;
          # 同 rowId:submodule 下 or 不触发,显式判空
          namespace =
            let ns = if hasRow then (p.row.settingsNamespace or null) else null; in
            if ns != null then ns else "web-search-${id}";
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
      # ── fetch 缝(镜像 ws 组;差异:无 base 自带后端 → 无裸 attrs 形态,
      # 无骨架行(默认态 = base 现状 fetch: false,非禁行),选中必声明)
      cfgWf = cfg.webFetch or null;
      cfgWfProviders = cfg.webFetchProviders or { };
      wfBackend = id: p:
        let
          rowIdOf = name:
            let tail = lib.removePrefix "dsh-" (lib.last (lib.splitString "/" name)); in
            if lib.hasPrefix "web-fetch-" tail then tail else "web-fetch-${tail}";
          base = p.row.config or { };
        in
        {
          # 显式判空:submodule 输出 row.id/settingsNamespace 恒存在(default
          # null),`or` 不触发(checks 裸 attrs 直调测不到 module 路径)
          rowId =
            let id = p.row.id or null; in
            if id != null then id else rowIdOf p.row.name;
          rowName = p.row.name;
          rowConfig =
            if (p.row.secretFile or null) != null && !(base ? apiKeyEnv) then
              base // { apiKeyEnv = secretEnvName p.row.secretFile; }
            else base;
          source = p.source or null;
          namespace =
            let ns = p.row.settingsNamespace or null; in
            if ns != null then ns else "web-fetch-${id}";
        };
      wfBackends = mapAttrs wfBackend cfgWfProviders;
      # 选中 → insert 行 + web 行重述 fetchProvider + tool-web 行重述
      # fetch: true(base 的 SSRF 保险丝;委托型 provider 无此面,显式
      # 打开 —— 打开动作本身即"我信任这个 provider 的 SSRF 姿态"声明)
      wfProviderRows =
        let sel = if cfgWf == null then null else wfBackends.${cfgWf} or null; in
        lib.optionals (sel != null) [
          { id = sel.rowId; name = sel.rowName; config = sel.rowConfig; }
          { id = "web"; config = { fetchProvider = cfgWf; }; }
          { id = "tool-web"; config = { fetch = true; }; }
        ];
      wfDisable =
        # 声明未选中后端行(备案待命 → 禁行,死卡清理;同 ws 语义)
        lib.filter (id: id != cfgWf) (attrNames cfgWfProviders);
      wfDisableRows = map (id: { id = wfBackends.${id}.rowId; disabled = true; }) wfDisable;
      wfProviderSources =
        let sel = if cfgWf == null then null else wfBackends.${cfgWf} or null; in
        lib.optionals (sel != null)
          (if sel.source != null then [ sel.source ]
           else [ (registryLookup sel.rowId) ]);
       # fetch 缝行组(未选中禁行 + 选中 insert/选择器/保险丝)
       wfRows = wfDisableRows ++ wfProviderRows;

      # ── subagent 委托实例(subagents.<name> → dsh-tool-subagent 行)───
      # 新行 id 不在树上 → insert 通道(同 MCP;裸 patch 只会 warn+skip)。
      # 行落宿主组合层 global 层:preset 会话经 dsh-tools view() 的
      # global 基底看到新 toolName(只遮蔽同名),故不进 buildPreset
      # rows —— 与 wf/ws 的同 id 遮蔽根因不同。child 组合/权限固定
      # 见 README subagent 调研节。
      # assert 单独出口:结果集 WHNF(顶层 seq 链)即炸,不依赖行被消费
      subagentRender =
        let
          entries = lib.filterAttrs (_: p: p.enable or false) (cfg.subagents or { });
          toolNameOf = name: p: p.toolName or "subagent_${name}";
          # 工具名查重(实例间 + base 全局名/控制工具):撞名 = 上游
          # boot 期 "already registered"(上游 TODO 已认晚期),前移到
          # eval 期。control 工具(send_message 等)是全局注册,同样在
          # global 层冲突
          reservedToolNames = [
            "subagent" "subagent_fork"
            "send_message" "interrupt_agent" "list_agents" "report"
          ];
          names = mapAttrsToList toolNameOf entries;
          dupNames = filter (n: builtins.length (filter (m: m == n) names) > 1)
            (lib.unique names);
          reservedHit = filter (n: builtins.elem n reservedToolNames) names;
          # 生成行 id 撞 base 既有 id(attr 名 "fork"/"" → tool-subagent-fork
          # /tool-subagent)→ insert 出重复 id,entryMap 混乱
          idClash = filter (name: builtins.elem name [ "fork" "" ]) (attrNames entries);
          # agentOptions/toolFilter 空值过滤后渲染(全空省略整键);
          # `or` 缺省:裸 attrs fixture 不走 module system 无 default
          agentOpts = p:
            let ao = p.agentOptions or null; in
            if ao == null then { }
            else lib.filterAttrs (_: v: v != null) {
              provider = ao.provider or null;
              model = ao.model or null;
              maxTokens = ao.maxTokens or null;
            };
          filterOpts = p:
            let
              tf = p.toolFilter or null;
              allow = if tf == null then [ ] else tf.allow or [ ];
              deny = if tf == null then [ ] else tf.deny or [ ];
            in
            (lib.optionalAttrs (allow != [ ]) { inherit allow; })
            // (lib.optionalAttrs (deny != [ ]) { inherit deny; });
        in
        {
          assertion =
            if idClash != [ ] then
              throw "programs.dsh.subagents: instance name(s) ${concatStringsSep ", " idClash} would generate row ids clashing with base tree rows (tool-subagent/tool-subagent-fork); pick another name"
            else if dupNames != [ ] then
              throw "programs.dsh.subagents: duplicate toolName(s) ${concatStringsSep ", " dupNames} across instances — the model-facing name registers once per tool layer"
            else if reservedHit != [ ] then
              throw "programs.dsh.subagents: toolName(s) ${concatStringsSep ", " reservedHit} collide with base/global control tools (subagent, subagent_fork, send_message, interrupt_agent, list_agents, report); override toolName explicitly"
            else null;
          rows = mapAttrsToList
            (name: p: {
              insert = [({
                id = "tool-subagent-${name}";
                name = "@deepseek-ai/dsh-tool-subagent";
                config = {
                  provider = p.provider or "spawn";
                  toolName = toolNameOf name p;
                }
                // (optionalAttrs ((p.backgroundMode or null) != null) { backgroundMode = p.backgroundMode; })
                // (optionalAttrs ((p.enableRunInBackground or null) != null) { enableRunInBackground = p.enableRunInBackground; })
                // (optionalAttrs (agentOpts p != { }) { agentOptions = agentOpts p; })
                // (optionalAttrs ((p.persona or null) != null) { persona = p.persona; })
                // (optionalAttrs (filterOpts p != { }) { toolFilter = filterOpts p; })
                // (optionalAttrs ((p.maxDepth or null) != null) { maxDepth = p.maxDepth; });
              }) ];
            })
            entries;
        };
      _subagentAssert = subagentRender.assertion;
      subagentRows = subagentRender.rows;


      # ── preset 自动发现(插件托管 preset,liangshen 形态)─────────────
      # enabled 插件经 sourceOf 解析后的源(source null 的零 source 插件
      # 也在解析后拿到 registry derivation):passthru.dshPresets(registry,
      # update.py 收录时探测物化)/ 直扫 presets/ 目录(path 源)。
      # 发现即接管 —— 物化剥 tui marker 后 ensurePackagedPresets 视为
      # conflict 永不碰;插件 disable → 孤儿清理随动。用户显式
      # presets.<name> 声明与发现撞名 → 显式胜(声明即接管先例,
      # 合流在 hm-module 侧:discovered // declared)
      # 单次扫描双轨:{ presets = 接管面(既有语义); origins = 插件归属
      # (preset id → 插件名;dsh-presets 命令数据源,lib.presetOrigins 消费) }
      discovered =
        let
          scanSrc = src:
            if builtins.isPath src then
              (if builtins.pathExists "${toString src}/presets" then
                listToAttrs (map
                  (id: { name = id; value = "${toString src}/presets/${id}"; })
                  (filter
                    (id: builtins.pathExists "${toString src}/presets/${id}/agent.cordis.yml"
                      && builtins.readFileType "${toString src}/presets/${id}" == "directory")
                    (attrNames (builtins.readDir "${toString src}/presets"))))
              else { })
            else if lib.isDerivation src && (src.passthru or { }) ? dshPresets then
              listToAttrs (map
                (id: { name = id; value = "${toString src}/presets/${id}"; })
                src.passthru.dshPresets)
            else { };
          # 黑名单过滤 + typo/残留 fail-loud:排除 id 必须在探测集内
          # (拼错,或上游已删该 preset 而排除表未清 → 配置腐烂,报错清理)
          filterExcluded = name: p: scanned:
            let
              excluded = p.excludedPresets or [ ];
              unknown = filter (id: !scanned ? ${id}) excluded;
            in
            if unknown != [ ] then
              throw "programs.dsh.plugins.${name}: excludedPresets lists '${builtins.head unknown}' but the plugin ships no such preset (detected: ${concatStringsSep ", " (attrNames scanned)}) — typo, or stale after upstream drop?"
            else builtins.removeAttrs scanned excluded;
          scanOf = name: p:
            let r = builtins.tryEval (sourceOf name p); in
            if r.success then filterExcluded name p (scanSrc r.value) else { };
        in
        # tryEval:sourceOf 对未知插件 throw(与插件分发同语义),发现面
        # 不放大 —— 单个插件源解析失败不影响其余(该错误在分发路径已
        # fail-loud,这里不必重复炸)。
        # presets = false 全禁(与 face=false 的"压制自动通道"同构);
        # 与 excludedPresets 非空同设 → 矛盾声明 throw
        builtins.foldl'
          (acc: name:
            let
              p = (cfg.plugins or { }).${name} or null;
              merge = scanned: {
                presets = acc.presets // scanned;
                origins = acc.origins // mapAttrs (_: _: name) scanned;
              };
            in
            if p == null || !p.enable then acc
            else if !(p.presets or true) then
              (if (p.excludedPresets or [ ]) != [ ] then
                throw "programs.dsh.plugins.${name}: presets = false (take over none) conflicts with a non-empty excludedPresets — pick one"
               else acc)
            else merge (scanOf name p))
          { presets = { }; origins = { }; }
          (attrNames (cfg.plugins or { }));
      discoveredPresets = discovered.presets;
      discoveredOrigins = discovered.origins;
     in
     builtins.seq _faceExclusivityAssert (builtins.seq _defaultPresetAssert (builtins.seq _permissionAssert (builtins.seq _subagentAssert {
      # 全局 in-box 条目行(typed 插件层 patch 之后再追加;同一 id 后行胜过)
      inherit inBoxPatches;
      # MCP 服务器行(同样全局,追加在 in-box 行之后)
      mcpPatches = mcpPatches;
      # 三态 typed 选项的行组(disable + 后端行 + 选择器行;追加在 in-box 行之后)
      inherit capabilityPatches wsProviderRows wsSelectorRow wfRows;
      # secret 占位符引用的文件路径清单(wrapper 注入块消费)
      inherit mcpSecretRefs;
      # face 插件自动生成的 profile(与显式 profiles 同形,键 = face 名)
      inherit facePlugins;
      # 插件源自动发现的 preset(显式声明合流在消费侧,显式胜)
      inherit discoveredPresets;
      # discovered 归属配套输出(preset id → 插件名;dsh-presets 命令链)
      inherit discoveredOrigins;
      # 默认 preset:per-face 行集(键 = 树名)+ 协调标志/全局值(renderSettings
      # 消费:per-face 生效时全局不进 settings,防 settings 用户层遮蔽行)
      inherit defaultPresetRows hasFaceDefaultPreset;
      effectiveGlobalPreset = effectiveGlobalPreset;
      # 权限模式:全局行组(进所有树前部;per-face 行 later-wins 胜)
      inherit permissionRowsFor;
      # profile 名 → { extraPlugins; extraPatches; }(追加在原始列表之后;
      # 覆盖显式 profile 与自动 face 两类)
      perProfile = listToAttrs
        (map
          (profileName: nameValuePair profileName {
            extraPlugins =
              (map (c: c.plugin.source)
                (filter (c: builtins.elem profileName c.profiles) contributions))
              ++ (lib.filter (s: s != null) wsProviderSources)
              ++ (lib.filter (s: s != null) wfProviderSources);
            extraPatches =
              (concatMap (c: c.patches)
                (filter (c: builtins.elem profileName c.profiles) contributions))
              ++ inBoxPatches
              ++ capabilityPatches
              ++ wsProviderRows
              ++ wsSelectorRow
              ++ wfRows
              ++ mcpPatches
              ++ subagentRows
              ++ (lib.optionals (defaultPresetRows ? ${profileName})
                [ (defaultPresetRows.${profileName}) ])
              ++ (if globalPermissionMode == null then [ ] else permissionRowsFor profileName)
              ++ (lib.optionals (facePermissionRows ? ${profileName})
                (permissionRowsFor profileName));
          })
          allProfileNames);
     }))) ;
in
{
  inherit applyPlugins;
}
