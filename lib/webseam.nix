# web 缝统一行组(search + fetch 单一 owner)—— A 级修复的核心:
#
# 此前 ws/wf 两缝各自追加 patch 行:两个 id="web" 的行互相整行替换
# (后行胜)→ searchProvider 与 fetchProvider 互相踩踏,同设两缝即
# 静默丢一边(webSearch="deepseek-official" + webFetch 也丢 base 的
# searchProvider);tool-web 重述只写 fetch:true 丢 base 的
# searchTimeoutMs: 60000(搜索路由超时 60s → 掉回工具默认 30s)。
# 现在每 id 至多一行、由本模块合并两缝的贡献、全键重述:
#
#   web      config = { searchProvider = 选中值或 base 值恒重述;
#                      fetchProvider = fetch 缝选中才出 }
#   tool-web 仅 fetch 缝开时重述 { fetch = true; searchTimeoutMs = 60000; }
#            (search 单开不动 base 行:fetch:false + 60000 原样)
#
# patch 整行替换语义(dsh 源码注释 "A patch replaces the targeted
# row's whole config")下,重述 = 纪律;上面两行是纪律的全部载体。
# 骨架禁行只在**双缝全关**时出(任一缝开,web/tool-web 必须活);
# web-search-deepseek 禁行 = 搜索关闭或选中非 base 后端(base 树
# 自带该行,禁行非幽灵)。
#
# 声明未选中的非 base 后端**不再出禁行**:它们的 insert 行只在被
# 选中时才存在,树里从来没有行,disable 只会换来每次 boot 的
# "patch: entry not found" 警告(cordis-plugin-include 实测行为)。
#
# ⚠ "选中才启用"的前提:provider 切换在上游是行级变化(dsh-web
# 源码实证:WebRuntime 无 settings 命名空间,searchProvider 是行
# Config,构造器一次性定格,env DSH_WEB_SEARCH_PROVIDER 也仅 boot
# 读)。若上游将来把选择 id 接进 settings 热重载,本组应收敛为
# "声明即在,选择器热切"。
{ lib, secretEnvName, registry }:

let
  inherit (lib)
    any
    attrNames
    concatStringsSep
    elem
    filterAttrs
    mapAttrs
    optional
    optionalAttrs
    optionals
    removeAttrs
    ;

  # ws 后端声明归一:id → { rowId; rowName(null=base 自带); rowConfig;
  # source(null=base 自带); namespace }。预置 = 默认值里的完整声明
  # (语法糖,非代码分支):新后端接入 = 一条声明带 row/source,零
  # nixdsh 改动(开放注册表)。
  # 显式声明(带 row.name 的)= 非 base 自带;裸 attrs = base 自带后端
  # 的纯参数声明(向后兼容预置写法)
  wsBackend = id: p:
    let
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

  # wf 后端声明归一:镜像 ws,差异 = 缝无 base 自带后端(无裸 attrs
  # 形态,一律完整声明带 row.name)
  wfBackend = id: p:
    let
      rowIdOf = name:
        let tail = lib.removePrefix "dsh-" (lib.last (lib.splitString "/" name)); in
        if lib.hasPrefix "web-fetch-" tail then tail else "web-fetch-${tail}";
      base = p.row.config or { };
    in
    {
      rowId =
        let rid = p.row.id or null; in
        if rid != null then rid else rowIdOf p.row.name;
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
in
{
  # { rows; sources; assertion } —— rows 进所有树的用户 patch 层与
  # preset farm 重放;yq 重放按 id 匹配改键,禁行/insert 行无 config
  # 自然滤掉;assertion = 首个命中的违规(fail-loud 表驱动)
  mk = { cfg, pkgs }:
    let
      cfgWs = cfg.webSearch or null;
      cfgWsProviders = cfg.webSearchProviders or { };
      cfgWf = cfg.webFetch or null;
      cfgWfProviders = cfg.webFetchProviders or { };
      wsBackends = mapAttrs wsBackend
        (cfgWsProviders // { "deepseek-official" = cfgWsProviders."deepseek-official" or { }; });
      wfBackends = mapAttrs wfBackend cfgWfProviders;
      wsSel = if cfgWs == null then null else wsBackends.${cfgWs} or null;
      wfSel = if cfgWf == null then null else wfBackends.${cfgWf} or null;
      searchOn = cfgWs != null;
      fetchOn = cfgWf != null;

      # ── 行组(每 id 单行,见模块头注)──────────────────────────
      skeletonDisables =
        # 双缝全关才禁骨架(base 树自带 web/tool-web 行,禁行非幽灵);
        # fetch 开而 search 关:两行必须活(fetch 走 web 行 fetchProvider,
        # 工具面走 tool-web),只禁搜索后端
        optionals (!searchOn && !fetchOn) [
          { id = "web"; disabled = true; }
          { id = "tool-web"; disabled = true; }
        ]
        # base 自带 deepseek 搜索后端:搜索关或选中别的 → 禁(行在场,
        # 禁行非幽灵;死卡清理)
        ++ optionals (cfgWs != "deepseek-official")
          [ { id = "web-search-deepseek"; disabled = true; } ];
      backendInserts =
        # 选中非 base 后端 → insert 行(base 自带后端树里已有,无行)
        optional (wsSel != null && wsSel.rowName != null)
          { id = wsSel.rowId; name = wsSel.rowName; config = wsSel.rowConfig; }
        ++ optional (wfSel != null)
          { id = wfSel.rowId; name = wfSel.rowName; config = wfSel.rowConfig; };
      webRestate =
        # 两缝合并的单一 web 行:选中非 base 搜索后端,或 fetch 选中
        # (base 行无 fetchProvider 键)→ 必须重述;searchProvider 恒重述
        # (选中值 / base 值),整行替换下丢键 = 静默坏运行时
        optional ((cfgWs != null && cfgWs != "deepseek-official") || fetchOn) {
          id = "web";
          config =
            { searchProvider = if cfgWs != null then cfgWs else "deepseek-official"; }
            // (optionalAttrs fetchOn { fetchProvider = cfgWf; });
        };
      toolWebRestate =
        # fetch 保险丝 + base 行超时键重述(丢 searchTimeoutMs 会把
        # 搜索路由超时从 60s 掉回工具默认 30s)
        optional fetchOn {
          id = "tool-web";
          config = {
            fetch = true;
            searchTimeoutMs = 60000;
          };
        };
      rows = skeletonDisables ++ backendInserts ++ webRestate ++ toolWebRestate;
      # 选中后端的包源(进所有 profile;非 base 才有)
      sources =
        optionals (wsSel != null && wsSel.rowName != null)
          (if wsSel.source != null then [ wsSel.source ] else [ (registry.lookup pkgs wsSel.rowId) ])
        ++ optionals (wfSel != null)
          (if wfSel.source != null then [ wfSel.source ] else [ (registry.lookup pkgs wfSel.rowId) ]);

      # ── 断言(表驱动,首个命中即 throw)────────────────────────
      inbox = id: (cfg.inBoxPlugins or { }).${id} or { enable = null; };
      wsNull = !searchOn;
      wfNull = !fetchOn;
      violations = [
        {
          # typed 启用(非 null)但 inBoxPlugins 显式禁同组行 —— typed 层
          # 与用户层会产出语义冲突的行组
          cond = !wsNull && any (id: (inbox id).enable == false)
            [ "web" "web-search-deepseek" "web-search-exa" "tool-web" ];
          msg = "programs.dsh: webSearch is set but inBoxPlugins disables one of web/web-search-deepseek/web-search-exa/tool-web — use webSearch alone (null disables the capability rows)";
        }
        {
          # 选择器形态:webSearch 非 null → id 必须在声明表 ∪ base 自带集
          cond = !wsNull && !elem cfgWs ([ "deepseek-official" ] ++ (attrNames cfgWsProviders));
          msg = "programs.dsh: webSearch = \"${cfgWs}\" is not a declared webSearchProviders entry nor \"deepseek-official\" — declare the backend in webSearchProviders or select a known id";
        }
        {
          # 非 base id 用裸 attrs 声明(无 row.name):选择器会指向一个
          # 从未 insert 的行 → 运行时静默无后端
          cond = !wsNull && cfgWs != "deepseek-official" && (wsSel.rowName or null) == null;
          msg = "programs.dsh: webSearch = \"${cfgWs}\" is declared as bare attrs but is not a base-shipped backend — non-base backends need a full declaration with row.name (insert row + package source)";
        }
        {
          # typed 禁用(null)但配置仍指向它 —— 意图自相矛盾
          cond = wsNull && cfgWsProviders != { };
          msg = "programs.dsh: webSearchProviders is non-empty but webSearch = null (capability disabled) — declared backends would never run; set webSearch to a declared id or clear the table";
        }
        {
          cond = !wfNull && (inbox "tool-web").enable == false;
          msg = "programs.dsh: webFetch is set but inBoxPlugins disables tool-web — the fetch tool row must stay enabled (webFetch renders its fetch: true restatement)";
        }
        {
          # fetch 缝无 base 自带集,选中必在声明表
          cond = !wfNull && !elem cfgWf (attrNames cfgWfProviders);
          msg = "programs.dsh: webFetch = \"${cfgWf}\" is not a declared webFetchProviders entry — the fetch seam has no base-shipped backend; declare the backend first";
        }
        {
          cond = wfNull && cfgWfProviders != { };
          msg = "programs.dsh: webFetchProviders is non-empty but webFetch = null (capability disabled) — declared backends would never run; set webFetch to a declared id or clear the table";
        }
      ];
      first = lib.findFirst (v: v.cond) null violations;
      assertion = if first != null then throw first.msg else null;
    in
    builtins.seq assertion { inherit rows sources; };
}
