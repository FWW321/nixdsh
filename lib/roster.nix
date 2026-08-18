# ── 默认 preset + roster 接管(两行舞,face 树)───────────────────
# 机制(实证 profile-boot-*.js:180):clobber 只打 id "agent-presets"
# —— 禁 base 行(随之行失效),异 id 重插同包实例带自定义 roots,
# roster = [farm(system), user]。default 直接进新行 config
# (settings 协调退役:行恒在,settings 用户层恒胜行 —— freeform
# 撞 typed 仍 throw)。值的声明点挂交互插件(defaultPreset 经
# faceName 找树,改名自动跟随);非 face 插件设值 → throw。
#
# 舞的资格(faces.rosterEligible):仅对带 base agent-presets 行的
# face 树生效 —— headless(in-box 实测无此行)出舞 = 幽灵禁行警告
# + 向无 preset 语义的树注入服务;第三方 face 无元数据时缺省接管
# (宁多勿丢),可经 plugins.<name>.presetRoster 显式压制。
{ lib, faces, buildPresetFarm, shippedPresetNames }:

let
  inherit (lib)
    any
    attrNames
    concatStringsSep
    elem
    filter
    filterAttrs
    findFirst
    optionalString
    ;
in
{
  mk = { cfg, pkgs, declared, discovered, webSeamRows }:
    let
      globalDefaultPreset = cfg.defaultPreset or null;
      faceDefaultRows = faces.faceValues cfg pkgs "defaultPreset";
      # id 枚举校验(eval 期可知全集 = shipped ∪ declared ∪ discovered;
      # shipped 经 readDir 枚举,与 buildPresetFarm 同源同 IFD 前例)。
      # 模块 enum 类型引用兄弟配置会递归,故以 fail-loud 断言等价实现。
      # 手写 $DSH_HOME preset 仍可 UI 手选(roster user 根热发现),
      # 但不得锚定声明式默认 —— 要锚定就经 presets.<id>.source 声明
      # 接管(DSH_HOME 清空后默认仍在)。黑名单 id 被踢出 discovered
      # → 同样拒(矛盾声明)。
      knownIds =
        (attrNames declared)
        ++ (attrNames discovered)
        ++ (shippedPresetNames pkgs);
      knownMsg = concatStringsSep ", " knownIds;
      enabledPlugins = filterAttrs (_: p: p.enable) (cfg.plugins or { });
      # 舞资格:face 插件名 → bool(defaultPreset 锚定与舞行同资格)
      eligible = name: p:
        faces.faceOf pkgs name p != null
        && faces.rosterEligible { inherit cfg pkgs name p; };
      # 违规 offender 先绑定(表项只做判定的消息渲染,免重复推导)
      noTreeOffender = findFirst
        (name: (cfg.plugins.${name}.defaultPreset or null) != null
          && faces.faceOf pkgs name cfg.plugins.${name} == null)
        null (attrNames enabledPlugins);
      noRosterOffender = findFirst
        (name: (cfg.plugins.${name}.defaultPreset or null) != null
          && !(eligible name cfg.plugins.${name}))
        null (attrNames enabledPlugins);
      badFaces = filter (t: !elem faceDefaultRows.${t} knownIds) (attrNames faceDefaultRows);
      headBadFace = builtins.head badFaces;
      freeformClash =
        (cfg.settings or { }) ? "agent-presets"
        && (globalDefaultPreset != null
          || any (name: (cfg.plugins.${name}.defaultPreset or null) != null)
            (attrNames enabledPlugins));
      violations = [
        {
          # 非 face 插件设值:无树可渲染
          cond = noTreeOffender != null;
          msg = "programs.dsh.plugins.${noTreeOffender}: defaultPreset set on a non-face plugin (no interactive tree to render into — face trees come exclusively from face plugins; global defaultPreset covers the rest)";
        }
        {
          # 无 roster 资格的 face 上设值:值只会渲染进不存在的舞行
          cond = noRosterOffender != null;
          msg = "programs.dsh.plugins.${noRosterOffender}: defaultPreset set on a face tree that carries no agent-presets roster row (headless, or presetRoster = false) — the value would have no anchor";
        }
        {
          # freeform settings 用户层恒胜行 → 声明冲突
          cond = freeformClash;
          msg = "programs.dsh: settings.\"agent-presets\" freeform declaration conflicts with defaultPreset/plugins.<name>.defaultPreset — the settings user layer would shadow the roster rows; drop the freeform section or the typed option";
        }
        {
          cond = globalDefaultPreset != null && !elem globalDefaultPreset knownIds;
          msg = "programs.dsh.defaultPreset: '${globalDefaultPreset}' is not a known preset (known: ${knownMsg}) — typo, or a hand-written runtime preset? Declare it via programs.dsh.presets.<id>.source to anchor the declarative default (hand-written presets stay UI-selectable)";
        }
        {
          cond = badFaces != [ ];
          msg = "programs.dsh.plugins.*.defaultPreset (tree '${headBadFace}'): '${faceDefaultRows.${headBadFace}}' is not a known preset (known: ${knownMsg}) — typo, excludedPresets blacklisted, or hand-written? Declare it via programs.dsh.presets.<id>.source (hand-written presets stay UI-selectable)";
        }
      ];
      first = findFirst (v: v.cond) null violations;
      assertion = if first != null then throw first.msg else null;

      # roster 根:全部 preset 重放产物(shipped 全量 —— 手选逃逸关闭
      # + discovered + declared(声明即接管,同名胜)。行组 = web 缝
      # 正向行(禁行/insert 无 config 键被 buildPreset 自然滤掉)
      farm = buildPresetFarm {
        inherit pkgs;
        rows = webSeamRows;
        inherit declared discovered;
      };
      # 两行舞:禁 base 行(clobber 只打 id "agent-presets",随之失效)
      # + 异 id 重插同包实例带 farm roots。default = per-face 值,
      # 缺省全局,再缺省 standard(与 base 行原值同)。
      danceRows = tree:
        let
          fallback = if globalDefaultPreset != null then globalDefaultPreset else "standard";
          default = faceDefaultRows.${tree} or fallback;
        in
        [
          { id = "agent-presets"; disabled = true; }
          {
            insert = [ {
              id = "agent-presets-nix";
              name = "@deepseek-ai/dsh-agent-presets";
              config = {
                inherit default;
                roots = [ { path = toString farm; trust = "system"; } ];
              };
            } ];
          }
        ];
    in
    builtins.seq assertion {
      inherit faceDefaultRows farm danceRows;
    };
}
