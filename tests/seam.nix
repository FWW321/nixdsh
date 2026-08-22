# 能力缝域(nix-unit):webSearch/webFetch 行组(金样)、负例冲突
# (expectedError)、secretFile env 桥、roster 舞行、权限三行同步、
# subagent 实例。
# 行为级(真 boot 进树/幽灵禁行回归)在 checks/seam.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith;
  lib = pkgs.lib;

  rowsOf = applied: applied.llmRows ++ applied.webSeamRows;
  exaDecl = {
    row = {
      name = "@tonydua/dsh-web-search-exa";
      config.apiKeyEnv = "EXA_API_KEY";
    };
    settings.numResults = 5;
  };
  zhipuFetch = {
    row.name = "@fww/dsh-web-fetch-zhipu";
  };

  selExa = applyWith {
    webSearch = "exa";
    webSearchProviders.exa = exaDecl;
  };
  # 双缝组合(A1 踩踏回归:两缝各出一行 id="web" 互相整行覆盖)
  bothSeams = applyWith {
    webSearch = "exa";
    webSearchProviders.exa = exaDecl;
    webFetch = "zhipu";
    webFetchProviders.zhipu = zhipuFetch;
  };
  # fetch-only:webSearch null + webFetch 选中(fetch 依赖 web 行)
  fetchOnly = applyWith {
    webFetch = "zhipu";
    webFetchProviders.zhipu = zhipuFetch;
  };
  # deepseek 搜索 + zhipu fetch:base 行的 searchProvider 也须保住
  dsAndFetch = applyWith {
    webSearch = "deepseek-official";
    webFetch = "zhipu";
    webFetchProviders.zhipu = zhipuFetch;
  };
  # fetch 缝选中声明(secretFile 派生 apiKeyEnv)
  fetchSel = applyWith {
    webFetch = "zhipu";
    webFetchProviders.zhipu = {
      row = {
        name = "@fww/dsh-web-fetch-zhipu";
        secretFile = "/run/secrets/zhipu_api_key";
      };
    };
  };
  # 备案两个后端,选中其一 → 另一零行(A7 幽灵禁行回归)
  fetchBoth = applyWith {
    webFetch = "zhipu";
    webFetchProviders = {
      zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      other.row.name = "@example/dsh-web-fetch-other";
    };
  };

  # settings 侧
  stDeepseek = dshLib.renderSettings {
    settings = { };
    telemetry = {
      mode = null;
    };
    webSearch = "deepseek-official";
    webSearchProviders."deepseek-official".maxUses = 3;
    llmDeepseek = {
      thinking = "enabled";
    };
    providers = { };
    defaultModel = null;
  };
  stExa = dshLib.renderSettings {
    settings = { };
    telemetry = {
      mode = null;
    };
    webSearch = "exa";
    webSearchProviders.exa = {
      row.name = "@tonydua/dsh-web-search-exa";
      settings.numResults = 5;
    };
    llmDeepseek = null;
    providers = { };
    defaultModel = null;
  };
  stFetch = dshLib.renderSettings {
    settings = { };
    telemetry = {
      mode = null;
    };
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

  # secretFile 桥
  exaRow = builtins.head (
    lib.filter (x: x.id == "web-search-exa")
      (applyWith {
        webSearch = "exa";
        webSearchProviders.exa.row = {
          name = "@tonydua/dsh-web-search-exa";
          secretFile = "/run/secrets/exa_api_key";
        };
      }).webSeamRows
  );
  secretTable = dshLib.secretEnv {
    cfg = {
      webSearch = "exa";
      webSearchProviders.exa.row = {
        name = "@tonydua/dsh-web-search-exa";
        secretFile = "/run/secrets/exa_api_key";
      };
      providers."zhipu-coding-plan" = {
        apiKeyEnv = "ZHIPU_API_KEY";
        secretFile = "/run/secrets/zhipu_api_key";
      };
    };
  };
  secretDedup = dshLib.secretEnv {
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
  stSecretPair = dshLib.renderSettings {
    settings = { };
    telemetry = {
      mode = null;
    };
    webSearch = null;
    webSearchProviders = { };
    llmDeepseek = null;
    providers."zhipu-coding-plan" = {
      apiKeyEnv = "ZHIPU_API_KEY";
      secretFile = "/run/secrets/zhipu_api_key";
      api = "anthropic-messages";
      baseURL = "https://example.invalid";
      models = [
        {
          id = "glm-4.7";
          contextWindow = 200000;
          maxTokens = 128000;
        }
      ];
    };
    defaultModel = null;
  };

  # ── roster 舞场景 ──
  customStandardFork = {
    presets.custom-standard.source = dshLib.shippedPreset pkgs "standard";
  };
  rosterBoth = applyWith (
    customStandardFork
    // {
      defaultPreset = "custom-standard";
      plugins = {
        "dsh-tui" = {
          enable = true;
          face = null;
          source = null;
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
          defaultPreset = "liangshen"; # discovered 命中(dsh-tui 托管)
        };
        "web-app" = {
          enable = true;
          face = null;
          source = "@deepseek-ai/dsh-web-app";
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
        };
        # headless:face 但 in-box roster=false → 无舞行(A7 回归)
        "headless" = {
          enable = true;
          face = null;
          source = null;
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
        };
      };
    }
  );
  danceRows =
    tree:
    builtins.filter (
      x:
      x.id or null == "agent-presets"
      || (x ? insert && (builtins.head x.insert).id or null == "agent-presets-nix")
    ) rosterBoth.perProfile.${tree}.extraPatches;
  # 未设任何:舞行仍在,default 回落 standard(base 行原值同)
  rosterNone = applyWith {
    plugins."web-app" = {
      enable = true;
      face = null;
      source = "@deepseek-ai/dsh-web-app";
      profiles = [ ];
      settings = { };
      patches = [ ];
      patchId = null;
    };
  };
  danceInNone = builtins.filter (
    x: x ? insert && (builtins.head x.insert).id or null == "agent-presets-nix"
  ) rosterNone.perProfile.web.extraPatches;

  # ── 权限模式场景 ──
  tuiPlug =
    mode:
    (
      {
        enable = true;
        face = null;
        source = null;
        profiles = [ ];
        settings = { };
        patches = [ ];
        patchId = null;
      }
      // (if mode == null then { } else { permissionMode = mode; })
    );
  permBoth = applyWith {
    permissionMode = "workspace-write";
    plugins = {
      "dsh-tui" = tuiPlug "read-only"; # per-face 胜全局
      "web-app" = {
        enable = true;
        face = null;
        source = "@deepseek-ai/dsh-web-app";
        profiles = [ ];
        settings = { };
        patches = [ ];
        patchId = null;
      };
    };
  };
  permIds = [
    "sandbox-policy"
    "approval"
    "permission"
  ];
  permRows =
    tree:
    builtins.filter (x: builtins.elem (x.id or null) permIds) permBoth.perProfile.${tree}.extraPatches;
  permNoneRows =
    builtins.filter (x: builtins.elem (x.id or null) permIds)
      (applyWith { plugins = { }; }).perProfile.default.extraPatches;
  permDangerRows =
    let
      danger = applyWith {
        permissionMode = "danger-full-access";
        plugins."web-app" = {
          enable = true;
          face = null;
          source = "@deepseek-ai/dsh-web-app";
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
        };
      };
    in
    builtins.filter (x: builtins.elem (x.id or null) permIds) danger.perProfile.web.extraPatches;
  # 整表恒带(A4 回归):presets 三键镜像,仅负载键
  permPresets = {
    "danger-full-access" = {
      approval = "never";
      sandbox = "danger-full-access";
    };
    "read-only" = {
      approval = "ask";
      sandbox = "read-only";
    };
    "workspace-write" = {
      approval = "ask";
      sandbox = "workspace-write";
    };
  };

  # ── subagents 场景 ──
  subBoth = applyWith {
    subagents = {
      researcher = {
        enable = true;
        backgroundMode = "continuable";
        agentOptions = {
          provider = "zai-coding-cn";
          model = "glm-5.3";
          maxTokens = null;
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
        enable = true;
        face = null;
        source = "@deepseek-ai/dsh-web-app";
        profiles = [ ];
        settings = { };
        patches = [ ];
        patchId = null;
      };
    };
  };
  subRowsIn =
    tree:
    builtins.concatMap (
      x: if x ? insert then x.insert else [ ]
    ) subBoth.perProfile.${tree}.extraPatches;
  subRowsOf =
    cfg:
    builtins.concatMap (x: if x ? insert then x.insert else [ ])
      (applyWith cfg).perProfile.default.extraPatches;
in
{
  capability = {
    # 默认(双缝 null):骨架禁行 + base 后端禁 + llm-deepseek 禁
    test-defaults = {
      expr = rowsOf (applyWith { });
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web";
          disabled = true;
        }
        {
          id = "tool-web";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
      ];
    };
    # providers null → 追加 llm-pi-ai 禁行,全部骨架行 disabled=true
    test-providers-null = {
      expr = rowsOf (applyWith {
        providers = null;
      });
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "llm-pi-ai";
          disabled = true;
        }
        {
          id = "web";
          disabled = true;
        }
        {
          id = "tool-web";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
      ];
    };
    # 选中 deepseek-official → 零 web 行(base 树行原样)
    test-select-deepseek = {
      expr = rowsOf (applyWith {
        webSearch = "deepseek-official";
      });
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
      ];
    };
    # 选中 exa → deepseek 后端禁 + insert 行 + web 单行重述
    test-select-exa = {
      expr = rowsOf selExa;
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
        {
          id = "web-search-exa";
          name = "@tonydua/dsh-web-search-exa";
          config.apiKeyEnv = "EXA_API_KEY";
        }
        {
          id = "web";
          config.searchProvider = "exa";
        }
      ];
    };
    # 双缝组合:web/tool-web 各恰一行(A1 踩踏回归),web 行双 provider,
    # tool-web 带超时键(A2)
    test-both-seams = {
      expr = rowsOf bothSeams;
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
        {
          id = "web-search-exa";
          name = "@tonydua/dsh-web-search-exa";
          config.apiKeyEnv = "EXA_API_KEY";
        }
        {
          id = "web-fetch-zhipu";
          name = "@fww/dsh-web-fetch-zhipu";
          config = { };
        }
        {
          id = "web";
          config = {
            searchProvider = "exa";
            fetchProvider = "zhipu";
          };
        }
        {
          id = "tool-web";
          config = {
            fetch = true;
            searchTimeoutMs = 60000;
          };
        }
      ];
    };
    # fetch-only:骨架不禁(fetch 需要行活着),base searchProvider 恒重述
    test-fetch-only = {
      expr = rowsOf fetchOnly;
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
        {
          id = "web-fetch-zhipu";
          name = "@fww/dsh-web-fetch-zhipu";
          config = { };
        }
        {
          id = "web";
          config = {
            searchProvider = "deepseek-official";
            fetchProvider = "zhipu";
          };
        }
        {
          id = "tool-web";
          config = {
            fetch = true;
            searchTimeoutMs = 60000;
          };
        }
      ];
    };
    # deepseek 搜索 + zhipu fetch:base 的 searchProvider 同样保住
    test-deepseek-and-fetch = {
      expr = rowsOf dsAndFetch;
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web-fetch-zhipu";
          name = "@fww/dsh-web-fetch-zhipu";
          config = { };
        }
        {
          id = "web";
          config = {
            searchProvider = "deepseek-official";
            fetchProvider = "zhipu";
          };
        }
        {
          id = "tool-web";
          config = {
            fetch = true;
            searchTimeoutMs = 60000;
          };
        }
      ];
    };
    # 选中 exa → 包源进每个 profile
    test-select-exa-distributes = {
      expr = builtins.mapAttrs (_: p: builtins.length p.extraPlugins) selExa.perProfile;
      expected = {
        default = 1;
      };
    };
    # settings 侧:选中后端 attrs 渲染进对应段,无声明不出段
    test-settings-deepseek = {
      expr = {
        ws = stDeepseek."web-search-deepseek";
        llm = stDeepseek."llm-deepseek";
      };
      expected = {
        ws = {
          maxUses = 3;
        };
        llm = {
          thinking = "enabled";
        };
      };
    };
    test-settings-exa-only = {
      expr = {
        keys = builtins.attrNames stExa;
        v = stExa."web-search-exa";
      };
      expected = {
        keys = [ "web-search-exa" ];
        v = {
          numResults = 5;
        };
      };
    };
    test-settings-fetch = {
      expr = stFetch."web-fetch-zhipu";
      expected = {
        returnFormat = "text";
      };
    };
  };

  # 三态负例:typed 选项 × 显式冲突 / 未知 id / 裸 attrs / 表非空×null → throw
  capability-clash = {
    test-websearch-vs-inbox-provider = {
      expr = applyWith {
        webSearch = "deepseek-official";
        inBoxPlugins."web-search-deepseek".enable = false;
      };
      expectedError.type = "ThrownError";
    };
    test-websearch-vs-inbox-tool = {
      expr = applyWith {
        webSearch = "deepseek-official";
        inBoxPlugins."tool-web".enable = false;
      };
      expectedError.type = "ThrownError";
    };
    test-llmdeepseek-vs-inbox = {
      expr = applyWith {
        llmDeepseek = { };
        inBoxPlugins."llm-deepseek".enable = false;
      };
      expectedError.type = "ThrownError";
    };
    test-providers-null-vs-settings = {
      expr = applyWith {
        providers = null;
        settings."llm-pi-ai".foo = 1;
      };
      expectedError.type = "ThrownError";
    };
    test-llmdeepseek-null-vs-default-model = {
      expr = applyWith {
        llmDeepseek = null;
        webSearch = null;
        providers = { };
        defaultModel = {
          provider = "deepseek-official";
          model = "deepseek-v4-pro";
        };
      };
      expectedError.type = "ThrownError";
    };
    test-websearch-unknown-id = {
      expr = applyWith { webSearch = "exa"; };
      expectedError.type = "ThrownError";
    };
    test-websearch-bare-attrs = {
      # 非 base id 用裸 attrs 声明:无 insert 行/无包源 → fail-loud
      expr = applyWith {
        webSearch = "exa";
        webSearchProviders.exa.maxUses = 3;
      };
      expectedError.type = "ThrownError";
    };
    test-websearch-table-without-selection = {
      expr = applyWith {
        webSearch = null;
        webSearchProviders.exa.row.name = "@tonydua/dsh-web-search-exa";
      };
      expectedError.type = "ThrownError";
    };
    test-secret-env-conflict = {
      # 同 env(X_KEY ← 文件名大写约定)不同文件 → throw
      expr = dshLib.secretEnv {
        cfg.providers = {
          a.secretFile = "/run/secrets/x_key";
          b.secretFile = "/run/secrets/elsewhere/x_key";
        };
      };
      expectedError.type = "ThrownError";
    };
    test-fetch-unknown-id = {
      expr = applyWith { webFetch = "zhipu"; };
      expectedError.type = "ThrownError";
    };
    test-fetch-table-without-selection = {
      expr = applyWith {
        webFetch = null;
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
      };
      expectedError.type = "ThrownError";
    };
    test-fetch-vs-inbox-tool = {
      expr = applyWith {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row.name = "@fww/dsh-web-fetch-zhipu";
        inBoxPlugins."tool-web".enable = false;
      };
      expectedError.type = "ThrownError";
    };
  };

  # fetch 缝行组正例:insert 行 + web 行 fetchProvider 重述 +
  # tool-web {fetch:true, searchTimeoutMs:60000};未选中后端零行
  fetch = {
    test-rows = {
      expr = rowsOf fetchSel;
      expected = [
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "web-search-deepseek";
          disabled = true;
        }
        {
          id = "web-fetch-zhipu";
          name = "@fww/dsh-web-fetch-zhipu";
          config.apiKeyEnv = "ZHIPU_API_KEY";
        }
        {
          id = "web";
          config = {
            searchProvider = "deepseek-official";
            fetchProvider = "zhipu";
          };
        }
        {
          id = "tool-web";
          config = {
            fetch = true;
            searchTimeoutMs = 60000;
          };
        }
      ];
    };
    # 备案另一后端不选中 → 零行(行从未进树,禁行只会换 boot 警告;A7 回归)
    test-unselected-backend-emits-nothing = {
      expr = builtins.length (rowsOf fetchBoth);
      expected = 5;
    };
    test-distributes = {
      expr = builtins.mapAttrs (_: p: builtins.length p.extraPlugins) fetchSel.perProfile;
      expected = {
        default = 1;
      };
    };
  };

  secret-env = {
    # row.secretFile 派生 apiKeyEnv(行自描述)
    test-row-derives-api-key-env = {
      expr = exaRow.config.apiKeyEnv;
      expected = "EXA_API_KEY";
    };
    # 收集器:exa row(派生)+ zhipu 路由(显式)→ 两键
    test-collector = {
      expr = secretTable;
      expected = {
        EXA_API_KEY = "/run/secrets/exa_api_key";
        ZHIPU_API_KEY = "/run/secrets/zhipu_api_key";
      };
    };
    # 去重:同 env 同文件跨声明 → 单键
    test-dedup = {
      expr = secretDedup;
      expected = {
        ZHIPU_API_KEY = "/run/secrets/zhipu_api_key";
      };
    };
    # provider secretFile 配对保留显式 apiKeyEnv(settings 面)
    test-settings-keeps-explicit = {
      expr = stSecretPair."llm-pi-ai".providers;
      expected = {
        "zhipu-coding-plan" = {
          apiKeyEnv = "ZHIPU_API_KEY";
          api = "anthropic-messages";
          baseURL = "https://example.invalid";
          models = [
            {
              id = "glm-4.7";
              contextWindow = 200000;
              maxTokens = 128000;
              name = "zhipu-coding-plan/glm-4.7";
            }
          ];
        };
      };
    };
  };

  roster = {
    # tui 树(registry roster=true):两行舞(default=per-face 值;roots=farm)
    test-tui-dance = {
      expr = danceRows "tui";
      expected = [
        {
          id = "agent-presets";
          disabled = true;
        }
        {
          insert = [
            {
              id = "agent-presets-nix";
              name = "@deepseek-ai/dsh-agent-presets";
              config = {
                default = "liangshen";
                roots = [
                  {
                    path = rosterBoth.presetFarm;
                    trust = "system";
                  }
                ];
              };
            }
          ];
        }
      ];
    };
    # web 树(in-box roster=true):未设 per-face → 回落全局 custom-standard
    test-web-dance = {
      expr = danceRows "web";
      expected = [
        {
          id = "agent-presets";
          disabled = true;
        }
        {
          insert = [
            {
              id = "agent-presets-nix";
              name = "@deepseek-ai/dsh-agent-presets";
              config = {
                default = "custom-standard";
                roots = [
                  {
                    path = rosterBoth.presetFarm;
                    trust = "system";
                  }
                ];
              };
            }
          ];
        }
      ];
    };
    # headless 树(in-box roster=false):零舞行(无 base 行的树出舞 =
    # 幽灵禁行警告 + 注入 preset 服务;A7 回归)
    test-headless-no-dance = {
      expr = danceRows "headless";
      expected = [ ];
    };
    # 未设任何:舞行仍在,default 回落 standard(base 行原值同)
    test-unconfigured-defaults-to-standard = {
      expr = danceInNone;
      expected = [
        {
          insert = [
            {
              id = "agent-presets-nix";
              name = "@deepseek-ai/dsh-agent-presets";
              config = {
                default = "standard";
                roots = [
                  {
                    path = rosterNone.presetFarm;
                    trust = "system";
                  }
                ];
              };
            }
          ];
        }
      ];
    };
    # settings 恒无 agent-presets 段(roster 接管后无 settings 面)
    test-settings-never-emits-presets = {
      expr =
        dshLib.renderSettings {
          settings = { };
          telemetry = {
            mode = null;
          };
          providers = { };
          defaultModel = null;
        } ? "agent-presets";
      expected = false;
    };
    # 负例:手写 profile 内嵌 face bundle(插件通道互斥)
    test-handwritten-profile-embeds-face = {
      expr = applyWith {
        profiles."my-web".plugins = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
        ];
      };
      expectedError.type = "ThrownError";
    };
    test-non-face-default-preset = {
      expr = applyWith {
        plugins.rotator = {
          enable = true;
          face = false;
          source = "./fixture-rotator";
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
          defaultPreset = "x";
        };
      };
      expectedError.type = "ThrownError";
    };
    test-ineligible-face-default-preset = {
      # headless:face 但 base 无 agent-presets 行(in-box roster=false)→ 无锚点
      expr = applyWith {
        plugins.headless = {
          enable = true;
          face = null;
          source = null;
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
          defaultPreset = "standard";
        };
      };
      expectedError.type = "ThrownError";
    };
    test-freeform-vs-typed = {
      # 已知 id:throw 只可能来自 freeform 冲突
      expr = applyWith {
        defaultPreset = "standard";
        settings."agent-presets".default = "manual";
      };
      expectedError.type = "ThrownError";
    };
    test-unknown-global-id = {
      expr = applyWith { defaultPreset = "standerd"; }; # typo of standard
      expectedError.type = "ThrownError";
    };
    test-unknown-per-face-id = {
      # expr 投影到 .presetFarm(roster 断言的可达点,字符串):
      # 深压整个 applied 结果会先钻进 facePlugins 的 registry derivation
      # (stdenv 内部属性环 → 无限递归),投影让断言先触发
      expr =
        (applyWith {
          plugins."dsh-tui" = {
            enable = true;
            face = null;
            source = null;
            profiles = [ ];
            settings = { };
            patches = [ ];
            patchId = null;
            defaultPreset = "standerd";
          };
        }).presetFarm;
      expectedError.type = "ThrownError";
    };
    test-blacklisted-id-as-default = {
      # 黑名单 id 锚定默认 = 矛盾声明(被踢出 discovered);投影同上
      expr =
        (applyWith {
          plugins."dsh-tui" = {
            enable = true;
            face = null;
            source = null;
            profiles = [ ];
            settings = { };
            patches = [ ];
            patchId = null;
            excludedPresets = [ "liangshen" ];
            defaultPreset = "liangshen";
          };
        }).presetFarm;
      expectedError.type = "ThrownError";
    };
  };

  permission = {
    # tui 树:全局层 + per-face 层各三行(later-wins:read-only 胜 workspace-write);
    # sandbox-policy 重述带 base workspaceRoot raw 值(整行纪律;A3 回归)
    test-tui-rows = {
      expr = permRows "tui";
      expected = [
        {
          id = "sandbox-policy";
          config = {
            mode = "read-only";
            workspaceRoot.__rawYaml = "!!js process.cwd()";
          };
        }
        {
          id = "approval";
          config.policy = "ask";
        }
        {
          id = "permission";
          config = {
            defaultPreset = "read-only";
            presets = permPresets;
          };
        }
        {
          id = "sandbox-policy";
          config = {
            mode = "read-only";
            workspaceRoot.__rawYaml = "!!js process.cwd()";
          };
        }
        {
          id = "approval";
          config.policy = "ask";
        }
        {
          id = "permission";
          config = {
            defaultPreset = "read-only";
            presets = permPresets;
          };
        }
      ];
    };
    # web 树:回落全局 workspace-write,同样恒带整表(A4 回归)
    test-web-rows = {
      expr = permRows "web";
      expected = [
        {
          id = "sandbox-policy";
          config = {
            mode = "workspace-write";
            workspaceRoot.__rawYaml = "!!js process.cwd()";
          };
        }
        {
          id = "approval";
          config.policy = "ask";
        }
        {
          id = "permission";
          config = {
            defaultPreset = "workspace-write";
            presets = permPresets;
          };
        }
      ];
    };
    # 未设 → 零行(维持 base 现状)
    test-none-rows = {
      expr = permNoneRows;
      expected = [ ];
    };
    # danger-full-access → approval never(与上游 env 公式同构),
    # sandbox-policy 三行同步
    test-danger-rows = {
      expr = permDangerRows;
      expected = [
        {
          id = "sandbox-policy";
          config = {
            mode = "danger-full-access";
            workspaceRoot.__rawYaml = "!!js process.cwd()";
          };
        }
        {
          id = "approval";
          config.policy = "never";
        }
        {
          id = "permission";
          config = {
            defaultPreset = "danger-full-access";
            presets = permPresets;
          };
        }
      ];
    };
    test-non-face-plugin = {
      expr = applyWith {
        plugins.rotator = {
          enable = true;
          face = false;
          source = "./fixture-rotator";
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
          permissionMode = "read-only";
        };
      };
      expectedError.type = "ThrownError";
    };
  };

  subagents = {
    # 形状:toolName 派生 / provider 默认 spawn / 空字段省略;
    # fork 实例:显式 provider + maxDepth 0,无 backgroundMode 键
    test-default-rows = {
      expr = subRowsIn "default";
      expected = [
        {
          id = "tool-subagent-quick";
          name = "@deepseek-ai/dsh-tool-subagent";
          config = {
            provider = "fork";
            toolName = "subagent_quick";
            maxDepth = 0;
          };
        }
        {
          id = "tool-subagent-researcher";
          name = "@deepseek-ai/dsh-tool-subagent";
          config = {
            provider = "spawn";
            toolName = "subagent_researcher";
            backgroundMode = "continuable";
            agentOptions.provider = "zai-coding-cn";
            agentOptions.model = "glm-5.3";
            toolFilter.deny = [ "web_fetch" ];
          };
        }
      ];
    };
    # 全局分发:face 树(web)同样各恰一行(与舞行共存)
    test-web-rows = {
      expr = subRowsIn "web";
      expected = [
        {
          id = "tool-subagent-quick";
          name = "@deepseek-ai/dsh-tool-subagent";
          config = {
            provider = "fork";
            toolName = "subagent_quick";
            maxDepth = 0;
          };
        }
        {
          id = "tool-subagent-researcher";
          name = "@deepseek-ai/dsh-tool-subagent";
          config = {
            provider = "spawn";
            toolName = "subagent_researcher";
            backgroundMode = "continuable";
            agentOptions.provider = "zai-coding-cn";
            agentOptions.model = "glm-5.3";
            toolFilter.deny = [ "web_fetch" ];
          };
        }
        {
          id = "agent-presets-nix";
          name = "@deepseek-ai/dsh-agent-presets";
          config = {
            default = "standard";
            roots = [
              {
                path = subBoth.presetFarm;
                trust = "system";
              }
            ];
          };
        }
      ];
    };
    # enable=false / 未声明 → 零行
    test-disabled-rows = {
      expr = subRowsOf {
        subagents.sleeper = {
          enable = false;
        };
      };
      expected = [ ];
    };
    test-none-rows = {
      expr = subRowsOf { };
      expected = [ ];
    };
    test-duplicate-toolname = {
      expr = applyWith {
        subagents = {
          a = {
            enable = true;
            toolName = "same_name";
          };
          b = {
            enable = true;
            toolName = "same_name";
          };
        };
      };
      expectedError.type = "ThrownError";
    };
    test-control-tool-clash = {
      expr = applyWith {
        subagents.a = {
          enable = true;
          toolName = "send_message";
        };
      };
      expectedError.type = "ThrownError";
    };
    test-base-row-id-clash = {
      expr = applyWith {
        subagents.fork = {
          enable = true;
        };
      };
      expectedError.type = "ThrownError";
    };
  };
}
