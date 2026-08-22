# 源校验与 settings 域(nix-unit):providers 合并语义(裸 attrs 直调 +
# modelEntry 真模块路径)、preset/skill 源校验、preset 自动发现、
# preset 重放路径分离(store 内容寻址)。
# 行为级(yq 独立解析器交叉验证/物理剥离/farm 实然)在 checks/sources.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith;

  # ── renderSettings 合并语义(typed 覆盖 freeform / null 省略 / 兄弟保留)──
  rendered = dshLib.renderSettings {
    settings = {
      telemetry.mode = "on";
      "agent-default-model".reasoning = "low";
      "llm-pi-ai".providers = {
        deepseek.apiKeyEnv = "FREEFORM_KEY";
        other-gateway.apiKeyEnv = "OTHER_KEY";
      };
    };
    telemetry = {
      mode = "off";
    };
    defaultModel = {
      provider = "zhipu-coding-plan";
      model = "glm-5.3";
      reasoningEffort = null;
    };
    providers = {
      deepseek = {
        apiKeyEnv = "DEEPSEEK_API_KEY";
        displayName = null;
        retryPolicy = { };
        models = [ { id = "deepseek-chat"; } ];
      };
      zhipu-coding-plan = {
        apiKeyEnv = "ZHIPU_API_KEY";
        displayName = "Zhipu Coding";
        api = "anthropic-messages";
        baseURL = "https://open.bigmodel.cn/api/anthropic";
        models = [
          {
            id = "glm-4.7";
            contextWindow = 200000;
          }
          {
            id = "glm-5.3";
            name = "GLM 5.3";
          }
        ];
      };
    };
  };

  # ── modelEntry 真模块路径(mkDsh 全模块 eval,与裸 attrs 互补)──
  modInst = dshLib.mkDsh {
    inherit pkgs;
    modules = [
      {
        programs.dsh.providers.zhipu.models = [
          {
            id = "glm-5.3";
            contextWindow = 1000000;
          }
          {
            id = "glm-5v-turbo";
            input = [
              "text"
              "image"
            ];
          }
          {
            id = "glm-5.2";
            reasoningEfforts = {
              off = null;
              high = "high";
            };
          }
          {
            id = "raw-model";
            someFutureField = "passthrough";
          }
        ];
        programs.dsh.providers.zhipu.modelOverrides."glm-4.7".contextWindow = 204800;
      }
    ];
  };
  modCfg = modInst.config.programs.dsh.providers.zhipu;
  # typo 与未来新字段 eval 期不可区分 → freeform 尾巴透传(设计),
  # 上游严格 z.object 在 settings 载入期拒未知键(fail-loud 点名)
  typoModels =
    (dshLib.mkDsh {
      inherit pkgs;
      modules = [
        {
          programs.dsh.providers.zhipu.models = [
            {
              id = "bad";
              contextwindow = 1000000;
            }
          ];
        }
      ];
    }).config.programs.dsh.providers.zhipu.models;
  # submodule default null 键不得流进 settings(上游 z.number() 拒 null 值键)
  renderedNoNull = dshLib.renderSettings {
    settings = { };
    telemetry = {
      mode = null;
    };
    providers.zhipu = {
      apiKeyEnv = "ZHIPU_API_KEY";
      inherit (modCfg) models modelOverrides;
    };
    defaultModel = null;
  };

  # ── preset 自动发现 ──
  # path 源夹具:真 Nix path(flake=false input 形态),含 presets/<id>/
  # agent.cordis.yml 目录束 + 一个无组合文件的干扰目录
  pathSrc = ../fixtures/preset-path-src;
  # derivation 源夹具:passthru.dshPresets(仿 update.py 物化)
  derivSrc =
    pkgs.runCommand "preset-deriv-src"
      {
        passthru.dshPresets = [ "shipped-one" ];
      }
      ''
        mkdir -p $out/presets/shipped-one
        echo "- id: tool-web" > $out/presets/shipped-one/agent.cordis.yml
      '';
  applyDiscover = plugins: (applyWith { inherit plugins; }).discoveredPresets;
  discoverFound = applyDiscover {
    a = {
      enable = true;
      source = pathSrc;
    };
    b = {
      enable = false;
      source = derivSrc;
    }; # disabled → 不发现
    c = {
      enable = true;
      source = pkgs.hello;
    }; # 无 preset → 空贡献
  };
  foundDeriv = applyDiscover {
    b = {
      enable = true;
      source = derivSrc;
    };
  };
  foundExcl = applyDiscover {
    d = {
      enable = true;
      source = pathSrc;
      excludedPresets = [ "second-one" ];
    };
  };
  foundTuiExcl = applyDiscover {
    "dsh-tui" = {
      enable = true;
      face = null;
      source = null;
      profiles = [ ];
      settings = { };
      patches = [ ];
      patchId = null;
      excludedPresets = [ "liangshen" ];
    };
  };
  foundAllOff = applyDiscover {
    f = {
      enable = true;
      source = pathSrc;
      presets = false;
    };
  };
in
{
  providers = {
    # typed 逐条覆盖 freeform 同名条目、null/空字段省略、freeform 兄弟保留、
    # model name 缺省派生(displayName 或路由名)
    test-llm-pi-ai = {
      expr = rendered."llm-pi-ai".providers;
      expected = {
        deepseek = {
          apiKeyEnv = "DEEPSEEK_API_KEY";
          models = [
            {
              id = "deepseek-chat";
              name = "deepseek/deepseek-chat";
            }
          ];
        };
        other-gateway = {
          apiKeyEnv = "OTHER_KEY";
        };
        "zhipu-coding-plan" = {
          apiKeyEnv = "ZHIPU_API_KEY";
          displayName = "Zhipu Coding";
          api = "anthropic-messages";
          baseURL = "https://open.bigmodel.cn/api/anthropic";
          models = [
            {
              id = "glm-4.7";
              contextWindow = 200000;
              name = "Zhipu Coding/glm-4.7";
            }
            {
              id = "glm-5.3";
              name = "GLM 5.3";
            }
          ];
        };
      };
    };
    test-telemetry-merge = {
      expr = rendered.telemetry;
      expected = {
        mode = "off";
      };
    };
    # typed defaultModel 渲染 + freeform 兄弟键保留 + null reasoningEffort 省略
    test-agent-default-model = {
      expr = rendered."agent-default-model";
      expected = {
        provider = "zhipu-coding-plan";
        model = "glm-5.3";
        reasoning = "low";
      };
    };
    # 真模块路径:input 多模态透传 / reasoningEfforts 接受 null wire /
    # freeform 尾巴透传未知字段 / modelOverrides 共享 typed 形状
    test-module-models = {
      expr = {
        input = (builtins.elemAt modCfg.models 1).input;
        efforts = (builtins.elemAt modCfg.models 2).reasoningEfforts;
        tail = (builtins.elemAt modCfg.models 3).someFutureField or null;
        override = modCfg.modelOverrides."glm-4.7".contextWindow;
      };
      expected = {
        input = [
          "text"
          "image"
        ];
        efforts = {
          off = null;
          high = "high";
        };
        tail = "passthrough";
        override = 204800;
      };
    };
    # typo 键走 freeform 尾巴(不进 typed 槽位)
    test-module-typo-rides-tail = {
      expr = {
        hasTypo = (builtins.elemAt typoModels 0) ? contextwindow;
        typedNull = ((builtins.elemAt typoModels 0).contextWindow or "absent") == null;
      };
      expected = {
        hasTypo = true;
        typedNull = true;
      };
    };
    # 渲染后逐条目无 null/空值键,未设 typed 字段不渲染(上游严格 schema)
    test-rendered-models-no-null-keys = {
      expr = renderedNoNull."llm-pi-ai".providers.zhipu.models;
      expected = [
        {
          id = "glm-5.3";
          contextWindow = 1000000;
          name = "zhipu/glm-5.3";
        }
        {
          id = "glm-5v-turbo";
          input = [
            "text"
            "image"
          ];
          name = "zhipu/glm-5v-turbo";
        }
        {
          id = "glm-5.2";
          name = "zhipu/glm-5.2";
          reasoningEfforts = {
            off = null;
            high = "high";
          };
        }
        {
          id = "raw-model";
          name = "zhipu/raw-model";
          someFutureField = "passthrough";
        }
      ];
    };
  };

  presets = {
    # 缺 agent.cordis.yml 的源 → eval 期拒(正例 fixture 目录通过)
    test-missing-composition-rejected = {
      expr = dshLib.validatePresets { "no-composition".source = ../checks/sources.nix; };
      expectedError.type = "ThrownError";
    };
    test-valid-dir-passes = {
      expr = dshLib.validatePresets { ok.source = ../fixtures/preset-ok; } ? ok;
      expected = true;
    };
  };

  skills = {
    # 平铺 .md → <name>.md / 目录束(SKILL.md)→ <name>/
    test-flat-and-bundle = {
      expr = dshLib.validateSkills {
        flat.source = ../fixtures/skill-flat.md;
        bundle.source = ../fixtures/skill-bundle;
      };
      expected = {
        flat = "flat.md";
        bundle = "bundle";
      };
    };
    test-directory-without-skill-md = {
      expr = dshLib.validateSkills { x.source = ../fixtures; };
      expectedError.type = "ThrownError";
    };
    test-non-md-file = {
      expr = dshLib.validateSkills { x.source = ../checks/sources.nix; };
      expectedError.type = "ThrownError";
    };
    test-skills-vs-disabled-skill-plugin = {
      expr = applyWith {
        skills.flat.source = ../fixtures/skill-flat.md;
        inBoxPlugins."skill-filesystem".enable = false;
      };
      expectedError.type = "ThrownError";
    };
    test-presets-vs-disabled-presets-plugin = {
      expr = applyWith {
        presets.mine.source = ../fixtures/preset-ok;
        inBoxPlugins."agent-presets".enable = false;
      };
      expectedError.type = "ThrownError";
    };
  };

  preset-discover = {
    # path 源直扫(组合文件目录命中,无组合文件的干扰目录跳过);
    # disabled 插件不发现;无 preset 源空贡献
    test-path-source = {
      expr = builtins.attrNames discoverFound;
      expected = [
        "handmade"
        "second-one"
      ];
    };
    # derivation 源 passthru.dshPresets 发现
    test-derivation-passthru = {
      expr = builtins.attrNames foundDeriv;
      expected = [ "shipped-one" ];
    };
    # excludedPresets 抑制所列 preset 的接管(经剥离副本;无组合目录保留)
    test-excluded = {
      expr = builtins.attrNames foundExcl;
      expected = [
        "handmade"
        "no-composition"
      ];
    };
    # registry 真源(dsh-tui):排除 liangshen → 发现面无此 id
    test-registry-excluded = {
      expr = builtins.attrNames foundTuiExcl;
      expected = [ ];
    };
    # presets = false 全禁
    test-all-off = {
      expr = builtins.attrNames foundAllOff;
      expected = [ ];
    };
    test-excluded-typo = {
      expr = applyDiscover {
        e = {
          enable = true;
          source = pathSrc;
          excludedPresets = [ "no-such-preset" ];
        };
      };
      expectedError.type = "ThrownError";
    };
    test-off-conflicts-with-excluded = {
      expr = applyDiscover {
        g = {
          enable = true;
          source = pathSrc;
          presets = false;
          excludedPresets = [ "handmade" ];
        };
      };
      expectedError.type = "ThrownError";
    };
    # 显式声明胜发现(hm-module 合流序)
    test-explicit-wins = {
      expr = (discoverFound // { handmade = "/explicit/wins"; }).handmade;
      expected = "/explicit/wins";
    };
    # shipped 助手:标准 preset 解析进 config/agent-presets 段(路径形状
    # 绑构建,用属性断言而非全路径金样)
    test-shipped-helper-resolves = {
      expr =
        pkgs.lib.match ".*/config/agent-presets/standard" (toString (dshLib.shippedPreset pkgs "standard"))
        != null;
      expected = true;
    };
    # shipped 助手对未知 preset fail-loud(上游布局漂移)
    test-shipped-helper-unknown = {
      expr = dshLib.shippedPreset pkgs "no-such-preset";
      expectedError.type = "ThrownError";
    };
  };

  preset-origins = {
    # 三态总账 + fork 标注:declared(shipped 根内 → forkOf)/
    # discovered(→ 归属插件)/replayed(shipped 全量,含 code/cordis/minimal,
    # 此处投影四键;farm 实然与命令行为在 checks/sources.nix)
    table = {
      expr =
        let
          o = dshLib.presetOrigins {
            inherit pkgs;
            declared = {
              custom-standard = dshLib.shippedPreset pkgs "standard";
              mine = pkgs.hello.outPath;
            };
            discoveredOrigins = {
              liangshen = "dsh-tui";
            };
          };
        in
        {
          inherit (o)
            custom-standard
            mine
            liangshen
            standard
            ;
        };
      expected = {
        custom-standard = {
          mode = "declared";
          origin = "presets.custom-standard";
          forkOf = "standard";
        };
        mine = {
          mode = "declared";
          origin = "presets.mine";
        };
        liangshen = {
          mode = "discovered";
          origin = "plugins.dsh-tui";
        };
        standard = {
          mode = "replayed";
          origin = "dsh";
        };
      };
    };
  };

  preset-replay = {
    # 行组不同 → 产物路径必不同(store 内容寻址;stamp 重物化/删除清理
    # 依赖此性质)。重放值语义在 checks/sources.nix(yq 独立解析器)
    test-rows-change-output-path = {
      expr =
        toString (
          dshLib.buildPreset {
            inherit pkgs;
            source = pkgs.hello;
            rows = [
              {
                id = "tool-web";
                config = {
                  fetch = true;
                };
              }
            ];
          }
        ) != toString (
          dshLib.buildPreset {
            inherit pkgs;
            source = pkgs.hello;
            rows = [ ];
          }
        );
      expected = true;
    };
  };
}
