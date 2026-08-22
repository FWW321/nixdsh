# typed 插件层 → 各 profile 的增量渲染(nixvim 式组合器):
#   plugins.<name>.enable → 源(source 或 pkgs.dshPlugins.<name>)追加进目标
#   profile 的 plugins;settings/patches 渲染为 patch 行追加进其 userPatches
#
# 各域内聚在独立模块(高内聚低耦合,单向依赖):
#   ./registry.nix     源解析与元数据(lookup/sourceOf/faceOfSource)
#   ./faces.nix        face 推导/自动 profile/per-face 值表/roster 资格
#   ./webseam.nix      web 缝行组(search+fetch 单 owner,全键重述)
#   ./llmseam.nix      llm-deepseek/llm-pi-ai 三态行组
#   ./permission.nix   权限三行(presets 整表 + workspaceRoot raw 重述)
#   ./mcprows.nix      MCP insert 行 + secret refs + 名校验
#   ./subagents.nix    subagent 委托实例行
#   ./discovery.nix    插件托管 preset 自动发现
#   ./roster.nix       defaultPreset 枚举校验 + 两行舞 + preset farm
# 本文件只做装配:per-插件 contributions、in-box 行、行序组合、
# 跨域断言(表驱动)。patchId 语义:settings 非空时才要求;
# 行 = { id; config = settings; }。
{ lib
, validatePresets
, shippedPresetNames
, registry
, faces
, webseam
, llmseam
, permission
, mcprows
, subagents
, discovery
, roster
}:

let
  inherit (lib)
    attrNames
    concatMap
    elem
    filter
    filterAttrs
    findFirst
    listToAttrs
    mapAttrsToList
    nameValuePair
    optional
    ;

  applyPlugins =
    { cfg, pkgs }:
    let
      # ── 各域(独立求值,断言随域)──────────────────────────────
      seam = webseam.mk { inherit cfg pkgs; };
      llm = llmseam.mk { inherit cfg; };
      mcp = mcprows.mk { inherit cfg; };
      subagent = subagents.mk { inherit cfg; };
      facePlugins = faces.faceProfiles { inherit cfg pkgs; };
      scanned = discovery.scan { inherit cfg pkgs; };
      declaredPresets = validatePresets (cfg.presets or { });
      rosterLayer = roster.mk {
        inherit cfg pkgs;
        discovered = scanned.presets;
        declared = declaredPresets;
        webSeamRows = seam.rows;
      };
      allProfileNames = (attrNames (cfg.profiles or { })) ++ (attrNames facePlugins);

      # ── 跨域断言(表驱动,首个命中即 throw)───────────────────
      # 依赖冲突:skills/presets 的发现插件在 base 树默认启用,显式
      # disable 会让物化文件无人消费 —— 静默失效比报错更糟,eval 期
      # fail-loud。(MCP 插件随 insert 行自带,无此冲突;presets 的
      # roster 行资格见 faces.rosterEligible,属上游 per-face 行为)
      inbox = id: (cfg.inBoxPlugins or { }).${id} or { enable = null; };
      skillProviderOff = (inbox "skill-filesystem").enable == false;
      presetRosterOff = (inbox "agent-presets").enable == false;
      violations = [
        {
          cond = (cfg.skills or { }) != { } && skillProviderOff;
          msg = "programs.dsh: skills are declared but inBoxPlugins.skill-filesystem.enable = false — no filesystem skill provider would discover them; remove the skills or re-enable the provider";
        }
        {
          cond = (cfg.presets or { }) != { } && presetRosterOff;
          msg = "programs.dsh: presets are declared but inBoxPlugins.agent-presets.enable = false — the preset roster is disabled; remove the presets or re-enable the roster";
        }
        {
          # 权限模式挂在非 face 插件上:无树可渲染(镜像 roster 的
          # defaultPreset 断言,同一"值挂树"纪律)
          cond = (findFirst
            (name: (cfg.plugins.${name}.permissionMode or null) != null
              && faces.faceOf pkgs name cfg.plugins.${name} == null)
            null (attrNames (filterAttrs (_: p: p.enable) (cfg.plugins or { })))) != null;
          msg = let name = findFirst
            (name: (cfg.plugins.${name}.permissionMode or null) != null
              && faces.faceOf pkgs name cfg.plugins.${name} == null)
            null (attrNames (filterAttrs (_: p: p.enable) (cfg.plugins or { }))); in
            "programs.dsh.plugins.${name}: permissionMode set on a non-face plugin (no interactive tree to render into; global programs.dsh.permissionMode covers the rest)";
        }
      ];
      crossAssert = let first = findFirst (v: v.cond) null violations; in
        if first != null then throw first.msg else null;

      # ── per-插件 contributions(功能插件分发)──────────────────
      targetsFor = p:
        if p.profiles == [ ] then allProfileNames
        else filter (n: elem n allProfileNames) p.profiles;
      patchRows = p:
        (optional (p.settings != { }) (
          if p.patchId == null then
            throw "programs.dsh.plugins: settings given but patchId is null"
          else { id = p.patchId; config = p.settings; }
        ))
        ++ p.patches;
      contributions = mapAttrsToList
        (name: con: {
          profiles = targetsFor con;
          plugin = { inherit name; source = registry.sourceOf pkgs name con; };
          patches = patchRows con;
        })
        (filterAttrs (name: p: p.enable && faces.faceOf pkgs name p == null) cfg.plugins);

      # in-box 条目行(全局,进所有 profile 的用户 patch 层;行级 disabled 键
      # 是 cordis loader 原生语义,实测可双向覆盖 bundle 层的 disabled)。
      # or-守卫:裸 attrs 直调路径(applyWith 夹具/外部调用)无 module
      # 默认值;enable 不表态(null)且无 config 的条目不发空行
      # (历史:dsh-inbox-rows 检查曾因 seq-列表空转未发现此路径 throw)
      inBoxPatches =
        mapAttrsToList
          (id: p:
            { inherit id; }
            // (lib.optionalAttrs ((p.enable or null) != null) { disabled = !p.enable; })
            // (lib.optionalAttrs ((p.config or { }) != { }) { inherit (p) config; }))
          (lib.filterAttrs
            (id: p: (p.enable or null) != null || (p.config or { }) != { })
            (cfg.inBoxPlugins or { }));

      # ── 权限模式:全局行组(进所有树前部;per-face 行 later-wins 胜)
      globalPermissionMode = cfg.permissionMode or null;
      facePermissionRows = faces.faceValues cfg pkgs "permissionMode";
      permissionRowsFor = tree:
        let mode = facePermissionRows.${tree} or globalPermissionMode; in
        if mode == null then [ ] else permission.rowsFor mode;

      # roster 舞资格按 face 插件逐个判定:带资格的 face 树名集合
      # (headless 等 base 无 agent-presets 行的树不出舞 —— 出了只有
      # 幽灵禁行警告 + 向无 preset 语义的树注入服务)
      rosterTrees = listToAttrs
        (map
          (name: nameValuePair (faces.faceNameOf pkgs name cfg.plugins.${name}) true)
          (attrNames (filterAttrs
            (name: p: p.enable
              && faces.faceOf pkgs name p != null
              && faces.rosterEligible { inherit cfg pkgs name p; })
            (cfg.plugins or { }))));
    in
    builtins.seq (faces.exclusivityAssert { inherit cfg pkgs; })
    (builtins.seq crossAssert
    (builtins.seq subagent.assertion {
      # 全局 in-box 条目行(typed 插件层 patch 之后再追加;同一 id 后行胜过)
      inherit inBoxPatches;
      # MCP 服务器行(全局,追加在 in-box 行之后)
      mcpPatches = mcp.rows;
      # secret 占位符引用的文件路径清单(wrapper 注入块消费,结构化单源)
      mcpSecretRefs = mcp.refs;
      # web 缝行组(disable/insert/重述,单 owner;追加在 in-box 行之后)
      webSeamRows = seam.rows;
      # LLM 适配器三态行组
      llmRows = llm.rows;
      # face 插件自动生成的 profile(与显式 profiles 同形,键 = face 名)
      inherit facePlugins;
      # 插件源自动发现的 preset(显式声明合流在消费侧,显式胜)
      discoveredPresets = scanned.presets;
      # discovered 归属配套输出(preset id → 插件名;dsh-presets 命令链)
      discoveredOrigins = scanned.origins;
      # roster 接管:farm 路径(dsh-presets 命令消费)+ 舞行进 face 树
      presetFarm = toString rosterLayer.farm;
      # 权限模式:全局行组(进所有树前部;per-face 行 later-wins 胜)
      inherit permissionRowsFor;
      # profile 名 → { extraPlugins; extraPatches; }(追加在原始列表之后;
      # 覆盖显式 profile 与自动 face 两类)
      perProfile = listToAttrs
        (map
          (profileName: nameValuePair profileName {
            extraPlugins =
              (map (c: c.plugin.source)
                (filter (c: elem profileName c.profiles) contributions))
              ++ seam.sources;
            extraPatches =
              (concatMap (c: c.patches)
                (filter (c: elem profileName c.profiles) contributions))
              ++ inBoxPatches
              ++ llm.rows
              ++ seam.rows
              ++ mcp.rows
              ++ subagent.rows
              ++ (lib.optionals (rosterTrees ? ${profileName})
                (rosterLayer.danceRows profileName))
              ++ (if globalPermissionMode == null then [ ] else permissionRowsFor profileName)
              ++ (lib.optionals (facePermissionRows ? ${profileName})
                (permissionRowsFor profileName));
          })
          allProfileNames);
    }));
in
{
  inherit applyPlugins;
}
