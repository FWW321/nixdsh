# 能力缝域(webSearch/webFetch 选择器):行组正例/负例冲突/双缝组合/
# secretFile env 桥/三家后端 in-tree 端到端
# 行组 API:applyPlugins 返回 webSeamRows(web 缝单 owner 全部行)+
# llmRows(llm 适配器三态行),按 perProfile 同序拼合断言
{ pkgs, dshLib, fx }:

let
  inherit (fx) applyWith inTreeCheck;
in
{
  # webSearch/webFetch 三态与行组形状。一个 check 遍历全部正例
  # (测试指南:同类场景合并):
  #   默认(双缝 null)→ 骨架禁行 + base 后端禁 + llm-deepseek 禁
  #   providers null → 追加 llm-pi-ai 禁
  #   选中 deepseek-official → 零 web 行(base 树行原样)
  #   选中 exa → deepseek 后端禁 + insert 行 + web 单行重述
  #   选中 exa+zhipu(双缝)→ web 单行双 provider(A1 回归)+ tool-web
  #     带超时键(A2 回归)
  #   fetch-only(zhipu)→ web/tool-web 不禁(fetch 需要它们)+ base
  #     searchProvider 恒重述
  dsh-capability-rows =
    let
      rowsOf = applied: applied.llmRows ++ applied.webSeamRows;
      defaults = rowsOf (applyWith { });
      piAiOff = rowsOf (applyWith { providers = null; });
      selDeepseek = rowsOf (applyWith { webSearch = "deepseek-official"; });
      exaDecl = {
        row = {
          name = "@tonydua/dsh-web-search-exa";
          config.apiKeyEnv = "EXA_API_KEY";
        };
        settings.numResults = 5;
      };
      selExa = applyWith {
        webSearch = "exa";
        webSearchProviders.exa = exaDecl;
      };
      # 双缝组合:A1 踩踏回归(此前两缝各出一行 id="web" 互相整行覆盖)
      both = applyWith {
        webSearch = "exa";
        webSearchProviders.exa = exaDecl;
        webFetch = "zhipu";
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      };
      # fetch-only:webSearch null + webFetch 选中(fetch 依赖 web 行)
      fetchOnly = applyWith {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      };
      # deepseek 搜索 + zhipu fetch:base 行的 searchProvider 也须保住
      dsAndFetch = applyWith {
        webSearch = "deepseek-official";
        webFetch = "zhipu";
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      };
      selExaRows = rowsOf selExa;
      bothRows = rowsOf both;
      fetchOnlyRows = rowsOf fetchOnly;
      dsAndFetchRows = rowsOf dsAndFetch;
      capIds = rows: map (r: r.id) rows;
      rowOf = rows: id: builtins.head (pkgs.lib.filter (r: r.id == id) rows);
      countOf = rows: id: builtins.length (pkgs.lib.filter (r: r.id == id) rows);
      # settings 侧:选中后端 attrs 渲染进对应段;无声明不出段
      st = dshLib.renderSettings {
        settings = { };
        telemetry = { mode = null; };
        webSearch = "deepseek-official";
        webSearchProviders."deepseek-official".maxUses = 3;
        llmDeepseek = { thinking = "enabled"; };
        providers = { };
        defaultModel = null;
      };
      stExa = dshLib.renderSettings {
        settings = { };
        telemetry = { mode = null; };
        webSearch = "exa";
        webSearchProviders.exa = {
          row.name = "@tonydua/dsh-web-search-exa";
          settings.numResults = 5;
        };
        llmDeepseek = null;
        providers = { };
        defaultModel = null;
      };
    in
    pkgs.runCommand "dsh-capability-rows-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg (capIds defaults == [ "llm-deepseek" "web" "tool-web" "web-search-deepseek" ])
        "capability: defaults must emit llm-deepseek + skeleton+base-backend disable rows")
      (pkgs.lib.assertMsg (capIds piAiOff == [ "llm-deepseek" "llm-pi-ai" "web" "tool-web" "web-search-deepseek" ])
        "capability: providers = null must add the llm-pi-ai disable row")
      (pkgs.lib.assertMsg (builtins.all (r: r.disabled == true) piAiOff)
        "capability: emitted skeleton rows must all carry disabled=true")
      (pkgs.lib.assertMsg (capIds selDeepseek == [ "llm-deepseek" ])
        "capability: selecting deepseek-official must emit only the independent llm-deepseek row (tree rows stand)")
      (pkgs.lib.assertMsg (capIds selExaRows == [ "llm-deepseek" "web-search-deepseek" "web-search-exa" "web" ])
        "capability: selecting exa must disable deepseek backend + insert exa row + restate web selector")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web-search-exa").name == "@tonydua/dsh-web-search-exa")
        "capability: exa row must reference the community package")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web-search-exa").config.apiKeyEnv == "EXA_API_KEY")
        "capability: exa row config must carry declared provider attrs")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web").config.searchProvider == "exa")
        "capability: web row must restate searchProvider = selected id")
      (pkgs.lib.assertMsg (builtins.length selExa.perProfile.default.extraPlugins == 1)
        "capability: selecting exa must add the package source to every profile")
      # ── A1 回归:双缝同设,web/tool-web 各恰一行,config 双 provider ──
      (pkgs.lib.assertMsg (countOf bothRows "web" == 1 && countOf bothRows "tool-web" == 1)
        "capability: both seams set must emit exactly one web row and one tool-web row (no id stomping)")
      (pkgs.lib.assertMsg ((rowOf bothRows "web").config == { searchProvider = "exa"; fetchProvider = "zhipu"; })
        "capability: the single web row must carry BOTH providers (whole-row replacement must not drop either seam)")
      (pkgs.lib.assertMsg ((rowOf bothRows "tool-web").config == { fetch = true; searchTimeoutMs = 60000; })
        "capability: tool-web restatement must keep the base searchTimeoutMs (60s search route, not the 30s tool default)")
      # deepseek 搜索 + fetch:base 的 searchProvider 同样保住
      (pkgs.lib.assertMsg ((rowOf dsAndFetchRows "web").config == { searchProvider = "deepseek-official"; fetchProvider = "zhipu"; })
        "capability: base-selected searchProvider must survive the fetch restatement")
      # ── fetch-only:骨架不禁(fetch 需要行活着),base searchProvider 恒重述 ──
      (pkgs.lib.assertMsg (countOf fetchOnlyRows "web" == 1 && countOf fetchOnlyRows "tool-web" == 1
        && (rowOf fetchOnlyRows "web").config == { searchProvider = "deepseek-official"; fetchProvider = "zhipu"; })
        "capability: fetch-only must keep web/tool-web alive (no skeleton disable) and restate the base searchProvider")
      # settings 侧
      (pkgs.lib.assertMsg (st ? "web-search-deepseek" && st."web-search-deepseek".maxUses == 3)
        "capability: selected deepseek-official attrs must render into settings.\"web-search-deepseek\"")
      (pkgs.lib.assertMsg (st ? "llm-deepseek" && st."llm-deepseek".thinking == "enabled")
        "capability: llmDeepseek attrs must render into settings.\"llm-deepseek\"")
      (pkgs.lib.assertMsg (stExa ? "web-search-exa" && stExa."web-search-exa".numResults == 5 && !(stExa ? "web-search-deepseek"))
        "capability: selected exa attrs must render into settings.\"web-search-exa\" only")
    ]) "touch $out");

  # 三态负例:typed 选项 × inBoxPlugins 显式冲突 / providers=null × settings
  # 声明 / llmDeepseek=null × defaultModel 指向 deepseek-official /
  # webSearch 未知 id / 裸 attrs 声明非 base id / 能力禁 × 声明表非空 → eval throw。
  # deepSeq applied:set 全域强制(各域断言 seq 在域结果内,deepSeq 必达);
  # 旧的 `f { }` 调用模式依赖"set WHNF 先强制外层断言链"的巧合,且
  # 顶层用 seq(列表 WHNF 不强推元素)会让整组断言空洞 —— 双双废弃
  dsh-capability-clash =
    let
      forceDomains = a:
        builtins.seq (a.facePlugins or null)
        (builtins.seq (a.webSeamRows or null)
        (builtins.seq (a.llmRows or null)
        (builtins.seq (a.mcpPatches or null)
        (builtins.seq (a.presetFarm or null)
        (builtins.seq (a.perProfile or null) null)))));
      tryThrow = applied: msg:
        let res = builtins.tryEval (forceDomains applied);
        in pkgs.lib.assertMsg (!res.success) msg;
    in
    pkgs.runCommand "dsh-capability-clash-check" { } (builtins.deepSeq ([
      (tryThrow (applyWith {
        webSearch = "deepseek-official";
        inBoxPlugins."web-search-deepseek".enable = false;
      }) "capability: webSearch set + inBoxPlugins disabling provider row must throw")
      (tryThrow (applyWith {
        webSearch = "deepseek-official";
        inBoxPlugins."tool-web".enable = false;
      }) "capability: webSearch set + inBoxPlugins disabling tool row must throw")
      (tryThrow (applyWith {
        llmDeepseek = { };
        inBoxPlugins."llm-deepseek".enable = false;
      }) "capability: llmDeepseek set + inBoxPlugins disable must throw")
      (tryThrow (applyWith {
        providers = null;
        settings."llm-pi-ai".foo = 1;
      }) "capability: providers=null + settings.llm-pi-ai declared must throw")
      (tryThrow (applyWith {
        llmDeepseek = null;
        webSearch = null;
        providers = { };
        defaultModel = { provider = "deepseek-official"; model = "deepseek-v4-pro"; };
      }) "capability: llmDeepseek=null + defaultModel → deepseek-official must throw")
      (tryThrow (applyWith {
        webSearch = "exa";
      }) "capability: webSearch = exa without a webSearchProviders.exa declaration must throw (not a base backend)")
      # 非 base id 用裸 attrs 声明:无 insert 行/无包源 → fail-loud
      (tryThrow (applyWith {
        webSearch = "exa";
        webSearchProviders.exa.maxUses = 3;
      }) "capability: webSearch = exa declared as bare attrs (no row.name) must throw (no insert row or package source could be rendered)")
      (tryThrow (applyWith {
        webSearch = null;
        webSearchProviders.exa = {
          row.name = "@tonydua/dsh-web-search-exa";
        };
      }) "capability: webSearchProviders non-empty + webSearch = null must throw (declared backends would never run)")
      # secretFile 冲突:同 env(X_KEY ← 文件名大写约定)不同文件 → throw
      (tryThrow (dshLib.secretEnv {
        cfg = {
          providers = {
            a.secretFile = "/run/secrets/x_key";
            b.secretFile = "/run/secrets/elsewhere/x_key";
          };
        };
      }) "secretEnv: same derived env from different files must throw")
      # fetch 缝负例:未知 id / 表非空×null / inBox 禁 tool-web
      (tryThrow (applyWith {
        webFetch = "zhipu";
      }) "fetch: webFetch = zhipu without a webFetchProviders.zhipu declaration must throw (no base-shipped fetch backend)")
      (tryThrow (applyWith {
        webFetch = null;
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      }) "fetch: webFetchProviders non-empty + webFetch = null must throw (declared backends would never run)")
      (tryThrow (applyWith {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
        inBoxPlugins."tool-web".enable = false;
      }) "fetch: webFetch set + inBoxPlugins disabling tool-web must throw")
    ]) "touch $out");

  # fetch 缝行组正例:选中 zhipu fetch 后端 → insert 行 + web 行
  # fetchProvider 重述 + tool-web {fetch:true, searchTimeoutMs:60000};
  # 未选中后端**零行**(行从未进树,禁行只会换 boot 警告);包源进
  # profile。负例(未知 id/表非空×null/inBox 禁 tool-web)进 clash
  dsh-fetch-rows =
    let
      sel = applyWith {
        webFetch = "zhipu";
        webFetchProviders.zhipu = {
          row = {
            name = "@fww/dsh-web-fetch-zhipu";
            secretFile = "/run/secrets/zhipu_api_key";
          };
        };
      };
      # 备案:两个后端声明,选中其一 → 另一零行(A7 幽灵禁行回归)
      both = applyWith {
        webFetch = "zhipu";
        webFetchProviders = {
          zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
          other.row.name = "@example/dsh-web-fetch-other";
        };
      };
      rows = sel.llmRows ++ sel.webSeamRows;
      rowOf = id: builtins.head (pkgs.lib.filter (r: r.id == id) rows);
      bothRows = both.llmRows ++ both.webSeamRows;
      anyOtherRows = pkgs.lib.filter (r: r.id == "web-fetch-other" || r ? disabled && r.id == "web") bothRows;
      st = dshLib.renderSettings {
        settings = { };
        telemetry = { mode = null; };
        webSearch = null;
        webSearchProviders = { };
        llmDeepseek = null;
        webFetch = "zhipu";
        webFetchProviders.zhipu = {
          row.name = "@fww/dsh-web-fetch-zhipu";
          settings.returnFormat = "text";
        };
        providers = { };
        defaultModel = null;
      };
    in
    pkgs.runCommand "dsh-fetch-rows-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg ((map (r: r.id) rows) == [ "llm-deepseek" "web-search-deepseek" "web-fetch-zhipu" "web" "tool-web" ])
        "fetch: selecting zhipu (fetch-only) must emit backend insert + full web/tool-web restatements; web-search-deepseek stays disabled (search off)")
      (pkgs.lib.assertMsg ((rowOf "web-fetch-zhipu").config.apiKeyEnv == "ZHIPU_API_KEY")
        "fetch: row.secretFile must derive apiKeyEnv (uppercase filename convention)")
      (pkgs.lib.assertMsg ((rowOf "web").config == { searchProvider = "deepseek-official"; fetchProvider = "zhipu"; })
        "fetch: web row must restate fetchProvider and keep the base searchProvider")
      (pkgs.lib.assertMsg ((rowOf "tool-web").config == { fetch = true; searchTimeoutMs = 60000; })
        "fetch: tool-web row must restate fetch: true WITH the base searchTimeoutMs (base SSRF fuse + timeout key)")
      (pkgs.lib.assertMsg (anyOtherRows == [ ])
        "fetch: unselected declared backend must emit NO row (never in tree — a disable row is a boot-time ghost warning)")
      (pkgs.lib.assertMsg (builtins.length sel.perProfile.default.extraPlugins == 1)
        "fetch: selecting zhipu must add the package source to every profile")
      (pkgs.lib.assertMsg (st ? "web-fetch-zhipu" && st."web-fetch-zhipu".returnFormat == "text")
        "fetch: selected backend attrs must render into settings.\"web-fetch-zhipu\"")
    ]) "touch $out");

  # secretFile 桥:声明 → 行 config 派生 apiKeyEnv(行自描述)+ wrapper
  # 恰好一个 export(跨声明去重)。真模块 eval(mkDsh)+ 真 wrapper 文本
  dsh-secret-env-bridge =
    let
      # 行侧:webSearch 选中后端 row 只给 secretFile(无 apiKeyEnv)
      applied = applyWith {
        webSearch = "exa";
        webSearchProviders.exa = {
          row = {
            name = "@tonydua/dsh-web-search-exa";
            secretFile = "/run/secrets/exa_api_key";
          };
        };
      };
      exaRow = builtins.head
        (pkgs.lib.filter (r: r.id == "web-search-exa") applied.webSeamRows);
      # providers 侧:显式 apiKeyEnv + secretFile(经典配对)
      st = dshLib.renderSettings {
        settings = { };
        telemetry = { mode = null; };
        webSearch = null;
        webSearchProviders = { };
        llmDeepseek = null;
        providers."zhipu-coding-plan" = {
          apiKeyEnv = "ZHIPU_API_KEY";
          secretFile = "/run/secrets/zhipu_api_key";
          api = "anthropic-messages";
          baseURL = "https://example.invalid";
          models = [ { id = "glm-4.7"; contextWindow = 200000; maxTokens = 128000; } ];
        };
        defaultModel = null;
      };
      # 收集器:exa row(派生 EXA_API_KEY)+ zhipu 路由(显式)→ 两键
      table = dshLib.secretEnv {
        cfg = {
          webSearch = "exa";
          webSearchProviders.exa = {
            row = {
              name = "@tonydua/dsh-web-search-exa";
              secretFile = "/run/secrets/exa_api_key";
            };
          };
          providers."zhipu-coding-plan" = {
            apiKeyEnv = "ZHIPU_API_KEY";
            secretFile = "/run/secrets/zhipu_api_key";
          };
        };
      };
      # 去重:ws zhipu row(派生)+ providers 路由(显式)同 env 同文件 → 单键
      tableDedup = dshLib.secretEnv {
        cfg = {
          webSearch = "zhipu";
          webSearchProviders.zhipu.row = {
            name = "@fww/dsh-web-search-zhipu";
            secretFile = "/run/secrets/zhipu_api_key";
          };
          providers."zhipu-coding-plan" = {
            apiKeyEnv = "ZHIPU_API_KEY";
            secretFile = "/run/secrets/zhipu_api_key";
          };
        };
      };
      # 真 wrapper(mkDsh 全模块 eval):文本断言 export 恰好一次
      wrapperText = let
        inst = dshLib.mkDsh {
          inherit pkgs;
          modules = [{
            programs.dsh.webFetch = "zhipu";
            programs.dsh.webFetchProviders.zhipu.row = {
              name = "@fww/dsh-web-fetch-zhipu";
              secretFile = "/run/secrets/zhipu_api_key";
            };
            programs.dsh.webSearch = "exa";
            programs.dsh.webSearchProviders.exa.row = {
              name = "@tonydua/dsh-web-search-exa";
              secretFile = "/run/secrets/exa_api_key";
            };
            programs.dsh.providers."zhipu-coding-plan" = {
              apiKeyEnv = "ZHIPU_API_KEY";
              secretFile = "/run/secrets/zhipu_api_key";
            };
          }];
        };
      in builtins.readFile "${toString inst.wrapper}/bin/dsh";
      exportCount = builtins.length (pkgs.lib.filter (l: builtins.match ''.*export (EXA_API_KEY|ZHIPU_API_KEY)=".*'' l != null)
        (pkgs.lib.splitString "\n" wrapperText));
    in
    pkgs.runCommand "dsh-secret-env-bridge-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg (exaRow.config.apiKeyEnv == "EXA_API_KEY")
        "secretEnv: row.secretFile must derive apiKeyEnv into row config (self-describing)")
      (pkgs.lib.assertMsg (st ? "llm-pi-ai"
        && st."llm-pi-ai".providers."zhipu-coding-plan".apiKeyEnv == "ZHIPU_API_KEY")
        "secretEnv: provider secretFile pairing must keep explicit apiKeyEnv in settings")
      (pkgs.lib.assertMsg (table ? EXA_API_KEY && table ? ZHIPU_API_KEY
        && table.EXA_API_KEY == "/run/secrets/exa_api_key"
        && table.ZHIPU_API_KEY == "/run/secrets/zhipu_api_key")
        "secretEnv: collector must return both env→file entries")
      (pkgs.lib.assertMsg (builtins.attrNames tableDedup == [ "ZHIPU_API_KEY" ])
        "secretEnv: same env+file across declarations must dedup to one export")
      (pkgs.lib.assertMsg (exportCount == 2)
        "secretEnv: wrapper must export exactly 2 env vars (EXA + ZHIPU), got ${toString exportCount}")
    ]) "touch $out");

  # exa 后端端到端:选中 exa 的 profile bundle 真 boot,web-search-exa 条目
  # 须进组合树(insert 生效而非 warn-skip)且全 log 零 "not found" 警告
  # (幽灵禁行回归)。registry 真包构建(peers 链接齐)→ 全链验证
  dsh-exa-in-tree = inTreeCheck {
    checkName = "dsh-exa-in-tree-check";
    profileName = "exa-tree";
    entryId = "web-search-exa";
    cfg = {
      webSearch = "exa";
      webSearchProviders.exa.row = {
        name = "@tonydua/dsh-web-search-exa";
        config.apiKeyEnv = "EXA_API_KEY";
      };
    };
    extraGreps = [
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # zhipu 后端端到端(同 exa 同构):选中 zhipu 的 profile 真 boot,
  # web-search-zhipu 条目进树 + web 行 searchProvider 重述生效
  dsh-zhipu-in-tree = inTreeCheck {
    checkName = "dsh-zhipu-in-tree-check";
    profileName = "zhipu-tree";
    entryId = "web-search-zhipu";
    cfg = {
      webSearch = "zhipu";
      webSearchProviders.zhipu.row = {
        name = "@fww/dsh-web-search-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'zhipu' "$TMPDIR/dump.log" && grep -q 'searchProvider' "$TMPDIR/dump.log"''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # fetch 真 boot:web-fetch-zhipu 进树 + fetchProvider 重述 + fetch: true
  dsh-fetch-in-tree = inTreeCheck {
    checkName = "dsh-fetch-in-tree-check";
    profileName = "fetch-tree";
    entryId = "web-fetch-zhipu";
    cfg = {
      webFetch = "zhipu";
      webFetchProviders.zhipu.row = {
        name = "@fww/dsh-web-fetch-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'fetchProvider: zhipu' "$TMPDIR/dump.log"''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # 双缝组合真 boot(A1 端到端):exa 搜索 + zhipu 抓取同设 → dump 里
  # 两个 provider 都在 web 行上,tool-web fetch: true 且 searchTimeoutMs
  # 保留(A2),零幽灵警告
  dsh-both-seams-in-tree = inTreeCheck {
    checkName = "dsh-both-seams-in-tree-check";
    profileName = "both-tree";
    entryId = "web-search-exa";
    cfg = {
      webSearch = "exa";
      webSearchProviders.exa.row = {
        name = "@tonydua/dsh-web-search-exa";
        config.apiKeyEnv = "EXA_API_KEY";
      };
      webFetch = "zhipu";
      webFetchProviders.zhipu.row = {
        name = "@fww/dsh-web-fetch-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'searchProvider: exa' "$TMPDIR/dump.log" && grep -q 'fetchProvider: zhipu' "$TMPDIR/dump.log"''
      ''grep -A4 'id: tool-web' "$TMPDIR/dump.log" | grep -q 'searchTimeoutMs: 60000' ''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # roster 接管(两行舞):资格 face 树得到 disable+insert 行(default 进
  # 新行 config,roots 指向 farm)+ headless/手写树零行 + settings 恒无
  # agent-presets 段 + 负例(非 face 设值 / 无资格 face 设值 / freeform
  # 冲突 / 未知 id)
  dsh-default-preset =
    let
      mk = cfg: applyWith cfg;
      # 全局 custom-standard = shipped standard 的换名 fork(声明接管)—— id 枚举
      # 校验的正例通道:declared 集命中
      customStandardFork = { presets.custom-standard.source = dshLib.shippedPreset pkgs "standard"; };
      both = mk (customStandardFork // {
        defaultPreset = "custom-standard";
        plugins = {
          "dsh-tui" = {
            enable = true; face = null; source = null; profiles = [ ];
            settings = { }; patches = [ ]; patchId = null;
            defaultPreset = "liangshen"; # discovered 命中(dsh-tui 托管)
          };
          "web-app" = {
            enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
            profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          };
          # headless:face 但 base 无 agent-presets 行(in-box roster=false)
          # → 无舞行(A7 回归),设 defaultPreset → throw
          "headless" = {
            enable = true; face = null; source = null; profiles = [ ];
            settings = { }; patches = [ ]; patchId = null;
          };
        };
      });
      tuiRows = both.perProfile.tui.extraPatches;
      webRows = both.perProfile.web.extraPatches;
      headlessRows = both.perProfile.headless.extraPatches;
      insertRowOf = rows:
        builtins.head (pkgs.lib.concatMap (r: if r ? insert then r.insert else [ ]) rows);
      disableRowOf = rows: id:
        pkgs.lib.filter (r: r.id or null == id && r.disabled or false) rows;
      # 未设任何 → 行仍在(default 回落 standard,与 base 行原值同)
      none = mk { plugins = { }; };
      # 负例:逐域 seq 强制(各域断言 seq 在域结果头部,WHNF 即达;
      # deepSeq 会连 derivation 内部深强制 → 栈溢出,不采用)
      forceDomains = a:
        builtins.seq (a.facePlugins or null)
        (builtins.seq (a.webSeamRows or null)
        (builtins.seq (a.llmRows or null)
        (builtins.seq (a.mcpPatches or null)
        (builtins.seq (a.mcpSecretRefs or null)
        (builtins.seq (a.presetFarm or null)
        (builtins.seq (a.inBoxPatches or null)
        (builtins.seq (a.perProfile or null) null)))))));
      tryThrow = applied': msg:
        let res = builtins.tryEval (forceDomains applied');
        in pkgs.lib.assertMsg (!res.success) msg;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-default-preset-check" { } (builtins.deepSeq ([
      # tui 树(registry roster=true):两行舞(default=per-face 值;roots=farm)
      (assert' (builtins.length (disableRowOf tuiRows "agent-presets") == 1)
        "roster: base agent-presets row must be disabled on roster-eligible face trees")
      (assert' ((insertRowOf tuiRows).id == "agent-presets-nix")
        "roster: replacement instance must insert under a distinct id")
      (assert' ((insertRowOf tuiRows).config.default == "liangshen")
        "roster: per-plugin defaultPreset must ride the insert row")
      (assert' ((insertRowOf tuiRows).config.roots == [
        { path = both.presetFarm; trust = "system"; }
      ]) "roster: roots must point at the farm with system trust")
      # web 树(in-box roster=true):未设 per-face → 回落全局 custom-standard
      (assert' ((insertRowOf webRows).config.default == "custom-standard")
        "roster: unset face must fall back to the global defaultPreset")
      # headless 树(in-box roster=false):零舞行 —— 无 base 行的树出舞
      # = 幽灵禁行警告 + 注入 preset 服务(A7 回归)
      (assert' (disableRowOf headlessRows "agent-presets" == [ ]
        && pkgs.lib.filter (r: r ? insert && (builtins.head r.insert).id or null == "agent-presets-nix") headlessRows == [ ])
        "roster: headless (no base agent-presets row) must not receive the dance")
      # 未设任何:舞行仍在,default 回落 standard(base 行原值同)
      (let webNone = (mk { plugins."web-app" = {
              enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
              profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
            }; }).perProfile.web.extraPatches; in
        assert' ((insertRowOf webNone).config.default == "standard")
          "roster: nothing configured must default to standard (base parity)")
      # settings 恒无 agent-presets 段(roster 接管后无 settings 面)
      (assert' (!(dshLib.renderSettings {
        settings = { }; telemetry = { mode = null; }; providers = { };
        defaultModel = null;
      } ? "agent-presets"))
        "roster: renderSettings must never emit agent-presets")
      (tryThrow (mk {
        profiles."my-web".plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
      }) "roster: hand-written profile embedding a face bundle must throw (plugin channel exclusivity)")
      (tryThrow (mk {
        plugins.rotator = {
          enable = true; face = false; source = "./fixture-rotator";
          profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          defaultPreset = "x";
        };
      }) "roster: defaultPreset on a non-face plugin must throw")
      (tryThrow (mk {
        plugins.headless = {
          enable = true; face = null; source = null; profiles = [ ];
          settings = { }; patches = [ ]; patchId = null;
          defaultPreset = "standard";
        };
      }) "roster: defaultPreset on a roster-ineligible face (headless) must throw (no anchor)")
      (tryThrow (mk {
        defaultPreset = "standard"; # 已知 id:throw 只可能来自 freeform 冲突
        settings."agent-presets".default = "manual";
      }) "roster: freeform settings.\"agent-presets\" + typed defaultPreset must throw")
      # id 枚举校验负例:未声明的 id(拼写错/手写运行时 preset)→ throw;
      # 同款全局与 per-face 两面
      (tryThrow (mk {
        defaultPreset = "standerd"; # typo of standard
      }) "roster: unknown global defaultPreset must throw (enum check)")
      (tryThrow (mk {
        plugins."dsh-tui" = {
          enable = true; face = null; source = null; profiles = [ ];
          settings = { }; patches = [ ]; patchId = null;
          defaultPreset = "standerd";
        };
      }) "roster: unknown per-face defaultPreset must throw (enum check)")
      # 黑名单 id 锚定默认 = 矛盾声明 → throw(被踢出 discovered)
      (tryThrow (mk {
        plugins."dsh-tui" = {
          enable = true; face = null; source = null; profiles = [ ];
          settings = { }; patches = [ ]; patchId = null;
          excludedPresets = [ "liangshen" ];
          defaultPreset = "liangshen";
        };
      }) "roster: blacklisted preset as defaultPreset must throw (contradiction)")
    ]) "touch $out");

  # roster 接管 boot 级端到端:真 web 树(base+web-app)+ 舞行 →
  # dump-config:agent-presets 禁 / agent-presets-nix 进树带 farm roots;
  # farm 内容:shipped standard 已重放(webFetch 选中 → fetch: true +
  # searchTimeoutMs 60000 进 shipped —— 手选逃逸关闭 + 超时键保留的
  # 铁证),minimal 原样(no-op 重放);全 log 零 "not found"(A7)
  dsh-roster-boot =
    let
      cfg' = {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row = {
          name = "@fww/dsh-web-fetch-zhipu";
          config.apiKeyEnv = "ZHIPU_API_KEY";
        };
        presets.custom-standard.source = dshLib.shippedPreset pkgs "standard";
        defaultPreset = "custom-standard";
        plugins."web-app" = {
          enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
          profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
        };
      };
      applied' = applyWith cfg';
      inc = applied'.perProfile.web;
      bundle = dshLib.buildProfile {
        inherit pkgs;
        profile = dshLib.mkProfile {
          name = "web";
          plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ] ++ inc.extraPlugins;
          userPatchesFile = null;
          userPatches = inc.extraPatches;
        };
      };
      farm = applied'.presetFarm;
    in
    pkgs.runCommand "dsh-roster-boot-check" { } ''
      ${fx.materialize "web" bundle}
      ${pkgs.dsh}/bin/dsh --profile web --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      grep -q 'id: agent-presets-nix' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; echo "roster row missing" >&2; exit 1; }
      # dump 按字母序渲染键:config(含 roots)在 id 行之前
      grep -B8 'id: agent-presets-nix' "$TMPDIR/dump.log" | grep -q "${farm}" || { cat "$TMPDIR/dump.log" >&2; echo "farm roots missing" >&2; exit 1; }
      ! grep -q 'entry "agent-presets-nix" not found' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      ! grep -q 'not found' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; echo "ghost disable rows leaked warnings" >&2; exit 1; }
      # farm 实然:shipped standard 的 fetch 已重放为 true 且超时键保留;
      # minimal 无 tool-web 行 → no-op(yq 不炸,原样)
      grep -q 'fetch: true' "${farm}/standard/agent.cordis.yml" || { echo "farm standard not replayed" >&2; exit 1; }
      grep -q 'searchTimeoutMs: 60000' "${farm}/standard/agent.cordis.yml" || { echo "farm standard lost searchTimeoutMs" >&2; exit 1; }
      test -f "${farm}/minimal/agent.cordis.yml" || { echo "farm minimal missing" >&2; exit 1; }
      touch $out
    '';

  # permission boot 级端到端:三模式遍历(read-only 表接管进 permission
  # 行 config;workspace-write/danger-full-access 恒带整表 —— A4 回归:
  # 运行期切 read-only 显示 custom 而非 named preset)→ dump-config
  # 不炸构造期 resolve,dump 里 presets 表三键在场
  dsh-permission-boot =
    let
      mkBoot = mode:
        let
          applied' = applyWith {
            permissionMode = mode;
            plugins."web-app" = {
              enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
              profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
            };
          };
          inc = applied'.perProfile.web;
          bundle = dshLib.buildProfile {
            inherit pkgs;
            profile = dshLib.mkProfile {
              name = "web";
              plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ] ++ inc.extraPlugins;
              userPatchesFile = null;
              userPatches = inc.extraPatches;
            };
          };
        in
        ''
          ${fx.materialize "web" bundle}
          ${pkgs.dsh}/bin/dsh --profile web --dump-config > "$TMPDIR/dump-${mode}.log" 2>&1 \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; exit 1; }
          ! grep -q 'unknown preset' "$TMPDIR/dump-${mode}.log" \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; echo "permission table takeover failed (${mode})" >&2; exit 1; }
          # 整表接管:read-only 在场(A4:此前非 read-only 分支丢表 →
          # 运行期切 read-only 显示 custom)
          grep -q 'read-only' "$TMPDIR/dump-${mode}.log" \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; echo "read-only preset missing from dump (${mode})" >&2; exit 1; }
        '';
    in
    pkgs.runCommand "dsh-permission-boot-check" { } ''
      ${mkBoot "read-only"}
      ${mkBoot "workspace-write"}
      ${mkBoot "danger-full-access"}
      touch $out
    '';

  # 权限模式:三行同步渲染 + per-face 胜全局(later-wins)+ 整表恒带
  # (A4 回归)+ workspaceRoot raw 重述(A3 回归)+ 负例
  dsh-permission-mode =
    let
      mk = cfg: applyWith cfg;
      tuiPlug = mode: {
        enable = true; face = null; source = null; profiles = [ ];
        settings = { }; patches = [ ]; patchId = null;
      } // (if mode == null then { } else { permissionMode = mode; });
      both = mk {
        permissionMode = "workspace-write";
        plugins = {
          "dsh-tui" = tuiPlug "read-only";
          "web-app" = {
            enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
            profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          };
        };
      };
      tuiRows = both.perProfile.tui.extraPatches;
      webRows = both.perProfile.web.extraPatches;
      rowsOf = rows: id: pkgs.lib.filter (r: (r.id or null) == id) rows;
      lastOf = rows: id: builtins.head (pkgs.lib.reverseList (rowsOf rows id));
      # 未设任何 → 零行(维持 base 现状)
      none = mk { plugins = { }; };
      # 负例:非 face 插件设值
      forceDomains = a:
        builtins.seq (a.facePlugins or null)
        (builtins.seq (a.webSeamRows or null)
        (builtins.seq (a.llmRows or null)
        (builtins.seq (a.mcpPatches or null)
        (builtins.seq (a.presetFarm or null)
        (builtins.seq (a.perProfile or null) null)))));
      tryThrow = applied: msg:
        let res = builtins.tryEval (forceDomains applied);
        in pkgs.lib.assertMsg (!res.success) msg;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-permission-mode-check" { } (builtins.deepSeq ([
      # tui 树:per-face read-only 三行(later-wins 胜全局)
      (assert' ((lastOf tuiRows "sandbox-policy").config.mode == "read-only")
        "permission-mode: per-face mode must win on its tree")
      (assert' ((lastOf tuiRows "sandbox-policy").config.workspaceRoot.__rawYaml == "!!js process.cwd()")
        "permission-mode: sandbox-policy restatement must carry the base workspaceRoot raw value (whole-row discipline)")
      (assert' ((lastOf tuiRows "approval").config.policy == "ask")
        "permission-mode: read-only approval policy must stay ask")
      (assert' ((lastOf tuiRows "permission").config.defaultPreset == "read-only")
        "permission-mode: permission.defaultPreset must stay in sync")
      # 整表恒带:三键镜像(base 同形,仅负载键;A4 + 去镜像文案键)
      (let perm = (lastOf tuiRows "permission").config; in
        assert' (perm ? presets
          && builtins.attrNames perm.presets == [ "danger-full-access" "read-only" "workspace-write" ]
          && perm.presets.read-only.sandbox == "read-only"
          && perm.presets.read-only.approval == "ask"
          && perm.presets."workspace-write".approval == "ask"
          && perm.presets."danger-full-access".approval == "never"
          && !(perm.presets.read-only ? name))
          "permission-mode: the permission row must always restate the full presets table (base parity, load-bearing keys only)")
      # web 树:回落全局 workspace-write —— 同样恒带表(修前非 read-only
      # 分支丢表 → 运行期切 read-only 显示 custom)
      (assert' ((lastOf webRows "sandbox-policy").config.mode == "workspace-write")
        "permission-mode: unset face must fall back to the global value")
      (assert' ((lastOf webRows "approval").config.policy == "ask"
          && (lastOf webRows "permission").config.defaultPreset == "workspace-write"
          && ((lastOf webRows "permission").config ? presets))
        "permission-mode: web tree rows must stay in sync AND restate the full table (uniform)")
      # danger-full-access → approval never(与上游 env 公式同构)
      (let danger = mk {
              permissionMode = "danger-full-access";
              plugins."web-app" = {
                enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
                profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
              };
            };
           webDanger = danger.perProfile.web.extraPatches; in
        assert' ((lastOf webDanger "approval").config.policy == "never")
          "permission-mode: danger-full-access must map approval to never")
      # 未设 → 无任何权限行
      (assert' (rowsOf none.perProfile.default.extraPatches "sandbox-policy" == [ ]
        && rowsOf none.perProfile.default.extraPatches "approval" == [ ]
        && rowsOf none.perProfile.default.extraPatches "permission" == [ ])
        "permission-mode: unset must not emit any rows (base defaults stand)")
      (tryThrow (mk {
        plugins.rotator = {
          enable = true; face = false; source = "./fixture-rotator";
          profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          permissionMode = "read-only";
        };
      }) "permission-mode: permissionMode on a non-face plugin must throw")
    ]) "touch $out");

  # subagent 实例:insert 行形状(空字段省略)+ 全局分发(普通树与 face
  # 树都有)+ 未声明零行 + 负例(工具名重复/撞控制工具/行 id 撞 base)
  dsh-subagents =
    let
      mk = cfg: applyWith cfg;
      inherit (pkgs.lib) concatMap filter;
      both = mk {
        subagents = {
          researcher = {
            enable = true;
            backgroundMode = "continuable";
            agentOptions = {
              provider = "zai-coding-cn"; model = "glm-5.3"; maxTokens = null;
            };
            toolFilter.deny = [ "web_fetch" ];
          };
          quick = {
            enable = true;
            provider = "fork";
            maxDepth = 0;
          };
        };
        plugins = {
          "web-app" = {
            enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
            profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          };
        };
      };
      # insert 行抽取:profile 行列表里 id 匹配的 insert 包内行
      rowsIn = rows: concatMap (r: if r ? insert then r.insert else [ ]) rows;
      rowIn = tree: id:
        let rows = rowsIn both.perProfile.${tree}.extraPatches; in
        builtins.head (filter (r: r.id == id) rows);
      countIn = tree: id:
        let rows = rowsIn both.perProfile.${tree}.extraPatches; in
        builtins.length (filter (r: r.id == id) rows);
      # enable=false 不出行;未声明零行
      disabled = mk { subagents.sleeper = { enable = false; }; };
      none = mk { };
      # 负例三连(fixture 无 module system,enable 显式给)
      forceDomains = a:
        builtins.seq (a.facePlugins or null)
        (builtins.seq (a.webSeamRows or null)
        (builtins.seq (a.llmRows or null)
        (builtins.seq (a.mcpPatches or null)
        (builtins.seq (a.presetFarm or null)
        (builtins.seq (a.perProfile or null) null)))));
      tryThrow = applied: msg:
        let res = builtins.tryEval (forceDomains applied);
        in pkgs.lib.assertMsg (!res.success) msg;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-subagents-check" { } (builtins.deepSeq ([
      # 形状:toolName 派生 / provider 默认 spawn / 空字段省略
      (assert' ((rowIn "default" "tool-subagent-researcher").config == {
        provider = "spawn";
        toolName = "subagent_researcher";
        backgroundMode = "continuable";
        agentOptions.provider = "zai-coding-cn";
        agentOptions.model = "glm-5.3";
        toolFilter.deny = [ "web_fetch" ];
      }) "subagents: full instance row must render derived toolName and omit null fields")
      # fork 实例:显式 provider + maxDepth 0,无 backgroundMode 键
      (assert' ((rowIn "default" "tool-subagent-quick").config == {
        provider = "fork";
        toolName = "subagent_quick";
        maxDepth = 0;
      }) "subagents: fork instance must render explicit provider and maxDepth, omitting unset keys")
      # 全局分发:普通树(default)与 face 树(web)各恰一行
      (assert' (countIn "default" "tool-subagent-researcher" == 1
        && countIn "default" "tool-subagent-quick" == 1
        && countIn "web" "tool-subagent-researcher" == 1
        && countIn "web" "tool-subagent-quick" == 1)
        "subagents: rows must land on every tree exactly once (host composition global layer)")
      # 行名 = 上游包名(insert 包裹)
      (assert' ((rowIn "web" "tool-subagent-researcher").name == "@deepseek-ai/dsh-tool-subagent")
        "subagents: inserted row must name the in-box package")
      # enable=false / 未声明 → 零行
      (assert' (rowsIn disabled.perProfile.default.extraPatches == [ ]
        && rowsIn none.perProfile.default.extraPatches == [ ])
        "subagents: disabled or undeclared instances must emit nothing")
      (tryThrow (mk {
        subagents = {
          a = { enable = true; toolName = "same_name"; };
          b = { enable = true; toolName = "same_name"; };
        };
      }) "subagents: duplicate toolName across instances must throw")
      (tryThrow (mk {
        subagents.a = { enable = true; toolName = "send_message"; };
      }) "subagents: toolName colliding with global control tools must throw")
      (tryThrow (mk {
        subagents.fork = { enable = true; };
      }) "subagents: attr name generating a row id clashing with base rows must throw")
    ]) "touch $out");
}
