# 能力缝域(webSearch/webFetch 选择器):行组正例/负例冲突/fetch 行组/
# secretFile env 桥/三家后端 in-tree 端到端
{ pkgs, dshLib, fx }:

let
  inherit (fx) applyWith inTreeCheck;
in
{
  # webSearch 选择器形态 + 三态:默认全禁/选中 deepseek 零行/选中 exa 出
  # provider+selector 行+包源/未选中后端禁行/settings 段按选中者渲染。
  # 一个 check 遍历全部正例(测试指南:同类场景合并)
  dsh-capability-rows =
    let
      # 默认(webSearch null,providers 缺省 {})→ 骨架+base 后端禁,llm-deepseek 禁
      defaults = (applyWith { }).capabilityPatches;
      # providers 显式 null → 追加 llm-pi-ai 行
      piAiOff = (applyWith { providers = null; }).capabilityPatches;
      # 选中 deepseek-official → 仅 llm-deepseek...不,deepseek 后端行启用,
      # 剩 llm-deepseek(独立选项,未设)禁
      selDeepseek = (applyWith { webSearch = "deepseek-official"; }).capabilityPatches;
      # 选中 exa(声明表有,完整声明带 row.name)→ deepseek 后端禁 +
      # provider/selector 行 + 包源
      selExa = applyWith {
        webSearch = "exa";
        webSearchProviders.exa = {
          row = {
            name = "@tonydua/dsh-web-search-exa";
            config.apiKeyEnv = "EXA_API_KEY";
          };
          settings.numResults = 5;
        };
      };
      selExaRows = selExa.capabilityPatches ++ selExa.wsProviderRows ++ selExa.wsSelectorRow;
      capIds = rows: map (r: r.id) rows;
      rowOf = rows: id: builtins.head (pkgs.lib.filter (r: r.id == id) rows);
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
      (pkgs.lib.assertMsg (capIds defaults == [ "web" "tool-web" "web-search-deepseek" "llm-deepseek" ])
        "capability: defaults must emit skeleton+base-backend disable + llm-deepseek (providers default {} stays enabled)")
      (pkgs.lib.assertMsg (capIds piAiOff == [ "web" "tool-web" "web-search-deepseek" "llm-deepseek" "llm-pi-ai" ])
        "capability: providers = null must add the llm-pi-ai disable row")
      (pkgs.lib.assertMsg (builtins.all (r: r.disabled == true) piAiOff)
        "capability: emitted rows must all carry disabled=true")
      (pkgs.lib.assertMsg (capIds selDeepseek == [ "llm-deepseek" ])
        "capability: selecting deepseek-official must emit only the independent llm-deepseek row (tree rows stand)")
      (pkgs.lib.assertMsg (capIds selExaRows == [ "web-search-deepseek" "llm-deepseek" "web-search-exa" "web" ])
        "capability: selecting exa must disable deepseek backend + insert exa row + restate web selector")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web-search-exa").name == "@tonydua/dsh-web-search-exa")
        "capability: exa row must reference the community package")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web-search-exa").config.apiKeyEnv == "EXA_API_KEY")
        "capability: exa row config must carry declared provider attrs")
      (pkgs.lib.assertMsg ((rowOf selExaRows "web").config.searchProvider == "exa")
        "capability: web row must restate searchProvider = selected id")
      (pkgs.lib.assertMsg (builtins.length selExa.perProfile.default.extraPlugins == 1)
        "capability: selecting exa must add the package source to every profile")
      (pkgs.lib.assertMsg (st ? "web-search-deepseek" && st."web-search-deepseek".maxUses == 3)
        "capability: selected deepseek-official attrs must render into settings.\"web-search-deepseek\"")
      (pkgs.lib.assertMsg (st ? "llm-deepseek" && st."llm-deepseek".thinking == "enabled")
        "capability: llmDeepseek attrs must render into settings.\"llm-deepseek\"")
      (pkgs.lib.assertMsg (stExa ? "web-search-exa" && stExa."web-search-exa".numResults == 5 && !(stExa ? "web-search-deepseek"))
        "capability: selected exa attrs must render into settings.\"web-search-exa\" only")
    ]) "touch $out");

  # 三态负例:typed 选项 × inBoxPlugins 显式冲突 / providers=null × settings
  # 声明 / llmDeepseek=null × defaultModel 指向 deepseek-official /
  # webSearch 未知 id / 能力禁 × 声明表非空 → eval throw。
  # tryEval 只到 WHNF,throw 在 applyPlugins 内部 → deepSeq 强制(实测先例)
  dsh-capability-clash =
    let
      tryThrow = f: msg:
        let res = builtins.tryEval (builtins.deepSeq (f { }) null);
        in pkgs.lib.assertMsg (!res.success) msg;
    in
    pkgs.runCommand "dsh-capability-clash-check" { } (builtins.seq ([
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
      (tryThrow (applyWith {
        webSearch = null;
        webSearchProviders.exa = {
          row.name = "@tonydua/dsh-web-search-exa";
        };
      }) "capability: webSearchProviders non-empty + webSearch = null must throw (declared backends would never run)")
      # secretFile 冲突:两个 providers 声明派生同一 env 但文件不同 → throw
      (tryThrow (_: dshLib.secretEnv {
        cfg = {
          providers = {
            a.secretFile = "/run/secrets/x_key";
            b.secretFile = "/run/secrets/other_x_key";
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
  # fetchProvider 重述 + tool-web fetch:true 保险丝打开;未选中后端禁行;
  # 包源进 profile。负例(未知 id/表非空×null/inBox 禁 tool-web)进 clash
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
      # 备案:两个后端声明,选中其一 → 另一禁行
      both = applyWith {
        webFetch = "zhipu";
        webFetchProviders = {
          zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
          other.row.name = "@example/dsh-web-fetch-other";
        };
      };
      rows = sel.wfRows;
      rowOf = id: builtins.head (pkgs.lib.filter (r: r.id == id) rows);
      bothIds = map (r: r.id) both.wfRows;
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
      bothDisabled = map (r: r.id) (pkgs.lib.filter (r: r ? disabled) both.wfRows);
    in
    pkgs.runCommand "dsh-fetch-rows-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg ((map (r: r.id) rows) == [ "web-fetch-zhipu" "web" "tool-web" ])
        "fetch: selecting zhipu must emit insert row + web fetchProvider restatement + tool-web fetch:true fuse")
      (pkgs.lib.assertMsg ((rowOf "web-fetch-zhipu").config.apiKeyEnv == "ZHIPU_API_KEY")
        "fetch: row.secretFile must derive apiKeyEnv (uppercase filename convention)")
      (pkgs.lib.assertMsg ((rowOf "web").config.fetchProvider == "zhipu")
        "fetch: web row must restate fetchProvider = selected id")
      (pkgs.lib.assertMsg ((rowOf "tool-web").config.fetch == true)
        "fetch: tool-web row must restate fetch: true (base SSRF fuse, delegated provider)")
      (pkgs.lib.assertMsg (bothDisabled == [ "web-fetch-other" ])
        "fetch: unselected declared backend must get a disable row")
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
        (pkgs.lib.filter (r: r.id == "web-search-exa") applied.wsProviderRows);
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
  # 须进组合树(insert 生效而非 warn-skip)且 deepseek 后端行被禁。
  # registry 真包构建(peers 链接齐)→ 这是全链验证(构建级)
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
    ];
  };

  # roster 接管(两行舞):face 树得到 disable+insert 行(default 进新行
  # config,roots 指向 farm)+ headless/手写树零行 + settings 恒无
  # agent-presets 段 + 负例(非 face 设值 / freeform 冲突)
  dsh-default-preset =
    let
      mk = cfg: applyWith cfg;
      both = mk {
        defaultPreset = "fww";
        plugins = {
          "dsh-tui" = {
            enable = true; face = null; source = null; profiles = [ ];
            settings = { }; patches = [ ]; patchId = null;
            defaultPreset = "liangshen";
          };
          "web-app" = {
            enable = true; face = null; source = "@deepseek-ai/dsh-web-app";
            profiles = [ ]; settings = { }; patches = [ ]; patchId = null;
          };
        };
      };
      tuiRows = both.perProfile.tui.extraPatches;
      webRows = both.perProfile.web.extraPatches;
      headlessRows = both.perProfile.default.extraPatches;
      insertRowOf = rows:
        builtins.head (pkgs.lib.concatMap (r: if r ? insert then r.insert else [ ]) rows);
      disableRowOf = rows: id:
        pkgs.lib.filter (r: r.id or null == id && r.disabled or false) rows;
      # 未设任何 → 行仍在(default 回落 standard,与 base 行原值同)
      none = mk { plugins = { }; };
      # 负例
      tryThrow = f: msg:
        let res = builtins.tryEval (builtins.deepSeq (f { }) null);
        in pkgs.lib.assertMsg (!res.success) msg;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-default-preset-check" { } (builtins.deepSeq ([
      # tui 树:两行舞(default=per-face 值;roots=farm,trust system)
      (assert' (builtins.length (disableRowOf tuiRows "agent-presets") == 1)
        "roster: base agent-presets row must be disabled on face trees")
      (assert' ((insertRowOf tuiRows).id == "agent-presets-nix")
        "roster: replacement instance must insert under a distinct id")
      (assert' ((insertRowOf tuiRows).config.default == "liangshen")
        "roster: per-plugin defaultPreset must ride the insert row")
      (assert' ((insertRowOf tuiRows).config.roots == [
        { path = both.presetFarm; trust = "system"; }
      ]) "roster: roots must point at the farm with system trust")
      # web 树:未设 per-face → 回落全局 fww
      (assert' ((insertRowOf webRows).config.default == "fww")
        "roster: unset face must fall back to the global defaultPreset")
      # headless/手写树:零舞行(无 roster 语义,不引入服务)
      (assert' (disableRowOf headlessRows "agent-presets" == [ ]
        && pkgs.lib.filter (r: r ? insert && (builtins.head r.insert).id or null == "agent-presets-nix") headlessRows == [ ])
        "roster: non-face trees must not receive the dance")
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
        defaultPreset = "fww";
        settings."agent-presets".default = "manual";
      }) "roster: freeform settings.\"agent-presets\" + typed defaultPreset must throw")
    ]) "touch $out");

  # roster 接管 boot 级端到端:真 web 树(base+web-app)+ 舞行 →
  # dump-config:agent-presets 禁 / agent-presets-nix 进树带 farm roots;
  # farm 内容:shipped standard 已重放(webFetch 选中 → fetch: true 进
  # shipped —— 手选逃逸关闭的铁证),minimal 原样(no-op 重放)
  dsh-roster-boot =
    let
      cfg' = {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row = {
          name = "@fww/dsh-web-fetch-zhipu";
          config.apiKeyEnv = "ZHIPU_API_KEY";
        };
        defaultPreset = "fww";
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
      # farm 实然:shipped standard 的 fetch 已重放为 true;minimal 无
      # tool-web 行 → no-op(yq 不炸,原样)
      grep -q 'fetch: true' "${farm}/standard/agent.cordis.yml" || { echo "farm standard not replayed" >&2; exit 1; }
      test -f "${farm}/minimal/agent.cordis.yml" || { echo "farm minimal missing" >&2; exit 1; }
      touch $out
    '';

  # permission read-only boot 级端到端:真 web 树 + 全局 read-only 三行
  # (表接管进 permission 行 config)→ dump-config 不炸构造期 resolve
  # (修前:unknown preset "read-only" 于服务构造处 throw)
  dsh-permission-boot =
    let
      cfg' = {
        permissionMode = "read-only";
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
    in
    pkgs.runCommand "dsh-permission-boot-check" { } ''
      ${fx.materialize "web" bundle}
      ${pkgs.dsh}/bin/dsh --profile web --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      ! grep -q 'unknown preset' "$TMPDIR/dump.log" \
        || { cat "$TMPDIR/dump.log" >&2; echo "permission table takeover failed" >&2; exit 1; }
      # 表接管后 read-only 是命名 preset:defaultPreset 解析成功且入 dump
      grep -q 'read-only' "$TMPDIR/dump.log" \
        || { cat "$TMPDIR/dump.log" >&2; echo "read-only missing from dump" >&2; exit 1; }
      touch $out
    '';

  # 权限模式:三行同步渲染 + per-face 胜全局(later-wins)+ 负例
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
      tryThrow = f: msg:
        let res = builtins.tryEval (builtins.deepSeq (f { }) null);
        in pkgs.lib.assertMsg (!res.success) msg;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-permission-mode-check" { } (builtins.deepSeq ([
      # tui 树:per-face read-only 三行(later-wins 胜全局)
      (assert' ((lastOf tuiRows "sandbox-policy").config.mode == "read-only")
        "permission-mode: per-face mode must win on its tree")
      (assert' ((lastOf tuiRows "approval").config.policy == "ask")
        "permission-mode: read-only approval policy must be ask")
      (assert' ((lastOf tuiRows "permission").config.defaultPreset == "read-only")
        "permission-mode: permission.defaultPreset must stay in sync")
      # read-only 非上游 preset → 行 config 须整表接管(上游两条镜像 +
      # read-only 条目);负载键 sandbox/approval 与上游常量一致
      (let perm = (lastOf tuiRows "permission").config; in
        assert' (perm ? presets
          && builtins.attrNames perm.presets == [ "danger-full-access" "read-only" "workspace-write" ]
          && perm.presets.read-only.sandbox == "read-only"
          && perm.presets.read-only.approval == "ask"
          && perm.presets."workspace-write".approval == "ask"
          && perm.presets."danger-full-access".approval == "never")
          "permission-mode: read-only needs full-table takeover in the permission row")
      # web 树:回落全局 workspace-write
      (assert' ((lastOf webRows "sandbox-policy").config.mode == "workspace-write")
        "permission-mode: unset face must fall back to the global value")
      (assert' ((lastOf webRows "approval").config.policy == "ask"
          && (lastOf webRows "permission").config.defaultPreset == "workspace-write"
          && !((lastOf webRows "permission").config ? presets))
        "permission-mode: web tree rows must stay in sync (no table takeover for real presets)")
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
      tryThrow = f: msg:
        let res = builtins.tryEval (builtins.deepSeq (f { }) null);
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
