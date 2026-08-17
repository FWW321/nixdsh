# filepath: ~/nixos-config/pkgs/dsh/modules/options.nix
# programs.dsh 共享 options —— HM(hm-module.nix)与 NixOS(nixos-module.nix)
# 及 lib.nix 的 mkDsh 独立求值三方共用(TonyWu20 单 options 多消费面模式)
#
# typing 策略(nixvim 教训 × jcode 注释"逐键建模必腐化"):
#   typed core 只收 CLI 层确定项(defaultProfile/web 服务)与两源一致确认的
#   telemetry.mode;settings 整体 freeform(= 逃生口),model/models 等上游
#   rc 阶段键名未稳(hieutran 写 models、TonyWu20 写 model)不 typed 化
#
# 插件形态判别(配置承载/裸用)与三层通道选择纪律见 README
# 「插件形态与通道选择(设计准则)」—— typed 化决策依据:配置承载型
# 声明即启用/未声明即禁用,凭据也是配置(eval 期不猜运行时)
{ config, lib, pkgs, ... }:

let
  dshLib = import ../lib.nix { inherit lib; };
in
{
  options.programs.dsh = {
    enable = lib.mkEnableOption "dsh (DeepSeek Harness agent CLI)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dsh;
      defaultText = lib.literalExpression "pkgs.dsh";
      description = "dsh CLI 包(本目录 default.nix 提供,nixpkgs#552467 基座)";
    };

    # dsh-<name> wrapper 命名;多实例(HM 默认 dsh + profiles 各产 dsh-<name>)时区分
    binName = lib.mkOption {
      type = lib.types.str;
      default = "dsh";
      description = "wrapper 二进制名";
    };

    # $HOME 由 shell/service 环境展开:HM、NixOS、mkDsh 独立求值三场景一致
    dshHome = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.config/deepseek-harness";
      example = "\$HOME/.dsh";
      description = ''
        DSH_HOME:profiles/、settings.yaml、用户数据根目录。
        值在 shell/service 环境里展开(支持 $HOME 引用)。
      '';
    };

    defaultProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "headless";
      description = ''
        无显式 --profile 调用 dsh 时注入的 profile 名(dsh 要求非 web/plugin
        调用必须有 profile)。web/plugin 子命令拒绝父级 --profile,自动排除。
      '';
    };

    defaultPreset = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fww";
      description = ''
        全局默认 agent preset(未显式设置的 face 树用它兜底)。
        消费者是树上 agent-presets roster 行的 default 键 —— 但行
        config 是 settings 的 base,settings 用户层恒胜:任一
        plugins.\<name\>.defaultPreset 生效时全局不进 settings,
        下沉为各树行 patch 的兜底值(自动协调,免遮蔽)。与 freeform
        settings."agent-presets" 同设 → 求值期 throw。
      '';
    };

    permissionMode = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "read-only" "workspace-write" "danger-full-access" ]);
      default = null;
      example = "workspace-write";
      description = ''
        新会话默认权限模式(全局;未显式设置的 face 树用它兜底)。
        与 defaultPreset/webFetch 不同,权限活在宿主组合层(每树一份
        行,无全局共享物理),per-face 分化物理成立。渲染三行保持
        一致(sandbox-policy.mode / approval.policy /
        permission.defaultPreset),防止组合层推断出 "custom"
        (dsh-permission-presets :116 knobs 不匹配任何 preset 即
        throw)。caveat:UI 手选"新会话默认权限模式"写进 settings
        命名空间的运行时用户层,恒胜组合层 —— 设置后本选项被遮蔽
        (在 UI 里改回即恢复)。
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = lib.literalExpression ''
        {
          models = {              # 键名以 dsh --dump-default-config 实测为准
            provider = "deepseek";
            apiKey = "DEEPSEEK_API_KEY";   # 值为环境变量名,secret 走环境注入
          };
        }
      '';
      description = ''
        声明式 settings.yaml 内容(freeform,顶层键 = dsh 设置命名空间)。
        每次启动 yq merge:声明值覆盖同名键,本地其他键保留 —— dsh Web UI
        的运行时改动不被抹掉。空配置不写文件。
      '';
    };

    telemetry.mode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "off";
      description = "typed 便利键:渲染进 settings.telemetry.mode,覆盖 freeform 同名值";
    };

    # 默认模型选择(dsh-agent-default-model 命名空间段,schema 实测于 rc.5
    # 源码:provider/model 必填,reasoningEffort 可选)。typed 覆盖 freeform
    # settings."agent-default-model" 同名键
    defaultModel = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          provider = lib.mkOption {
            type = lib.types.str;
            example = "zhipu-coding-plan";
            description = ''
              供应商路由名。providers.<id> 的 id,或上游 catalog 路由名
              (如 deepseek,无需在本配置声明)。
            '';
          };
          model = lib.mkOption {
            type = lib.types.str;
            example = "glm-5.3";
            description = "模型 id(须在该 provider 的 models 清单内)";
          };
          reasoningEffort = lib.mkOption {
            # 值域 = 上游 THINKING_LEVELS(实测 rc.5 源码):上游 settings schema
            # 宽松(z.string()),但请求期 fail("does not support reasoning
            # effort");enum 把该错误前移到 eval 期。上游加档时此处会
            # hard-fail —— 那正是 bump 提示
            type = lib.types.nullOr (lib.types.enum [
              "off" "minimal" "low" "medium" "high" "xhigh" "max"
            ]);
            default = null;
            example = "high";
            description = "推理力度七档;null 省略(dsh 用模型默认映射)";
          };
        };
      });
      default = null;
      example = lib.literalExpression ''
        { provider = "zhipu-coding-plan"; model = "glm-5.3"; }
      '';
      description = ''
        typed 便利键:无会话级选择时 Agent 的默认模型
        (渲染进 settings."agent-default-model")。
      '';
    };

    # ── 配置承载型 typed 选项(三态:null 禁用/{} 显式启用/attrs 配置)──
    # 设计准则与可见性规则见 README「插件形态与通道选择」:禁用行进
    # 所有 profile 用户 patch 层;attrs 渲染进对应 settings 命名空间段
    # (yq merge,免重启)。默认值由空载荷代价选出。
    #
    # webSearch = 选择器形态(README:声明必有效,在场或被选择器解释):
    # 能力骨架行(web/tool-web)不设独立旋钮(假自由度:启 provider 必启、
    # 禁 provider 必禁);用户唯一的自由度是"provider 是谁"。
    webSearch = lib.mkOption {
      # null = 禁能力(骨架+在场后端行全禁);str = 启用并选中该 provider id
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "exa";
      description = ''
        网页搜索能力开关 + provider 选择器(二合一:这是唯一的自由度)。
        null(默认)= 禁用:web/web-search-deepseek/tool-web disable 行
        进所有 profile(base 树自带三行,故默认即禁,见 README 迁移注记)。
        str = 启用并选中该 provider id:
        - "deepseek-official"(base 自带):零声明即用,key 走 export
          DEEPSEEK_API_KEY 或 Web UI 运行时配;参数调 webSearchProviders
        - "exa":webSearchProviders 声明 exa 后端(非 base 自带,须声明)
        选中才启用:未选中后端出 disable 行(死卡清理)。前提:上游无
        运行时 provider 切换(dsh-web 实证,searchProvider 是行 Config
        非命名空间段,构造器定格;热切出现则改"声明即在",lib.nix 有
        同步标记)。选择器 id 不在声明表 ∪ {deepseek-official} → 求值期
        fail-loud。
        已知限制:web face 的 preset 自带 tool-web,patch 层不可达 ——
        null 时 web 会话的工具卡残留(README 已知限制节)。
      '';
    };

    # webFetch = fetch 缝的同款选择器形态(缝对称性,README「网页抓取」
    # 节):search/fetch 两套同构注册表,差异只在生态 —— fetch 缝 rc.6
    # 无 base 自带 provider(官方匿名 HTTP provider 因 SSRF 未发布,
    # base 的 tool-web fetch: false 保险丝),故选中必是声明后端,
    # 且须显式打开 tool-web.fetch(模块代劳)
    webFetch = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "zhipu";
      description = ''
        网页抓取能力开关 + fetch provider 选择器(fetch 缝,与
        webSearch 对称)。null(默认)= 禁用:维持 base 现状
        (tool-web fetch: false,fetch 注册表空)。str = 启用并选中
        该 provider id —— 必须在 webFetchProviders 声明表内(fetch
        缝无 base 自带后端);模块同时重述 tool-web 行 fetch: true
        (base 的 SSRF 保险丝,委托型 provider 无此面,显式打开)。
        选择器 id 未声明 → 求值期 fail-loud。SSRF 责任在上游规则里
        归 provider:委托型(远端 reader)平凡满足,本机抓取型须自证。
      '';
    };

    webFetchProviders = lib.mkOption {
      # 开放注册表,镜像 webSearchProviders;无 base 自带形态(裸 attrs
      # 无意义 —— 没有"官方后端参数"可调),一律完整声明
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          row = lib.mkOption {
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  example = "@fww/dsh-web-fetch-zhipu";
                  description = "cordis 包名(insert 行 name)";
                };
                id = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "行 id 覆盖;null 缺省 web-fetch-<包名尾段>";
                };
                config = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                  description = "行引导配置(如 apiKeyEnv)";
                };
                secretFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "/run/secrets/zhipu_api_key";
                  description = ''
                    凭据文件路径;声明后 wrapper 启动时读文件 export
                    环境变量(env 名 = row.config.apiKeyEnv 显式值 >
                    文件名大写约定),同 webSearchProviders.row.secretFile。
                  '';
                };
                settingsNamespace = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "settings 段名覆盖;null 缺省 web-fetch-<后端 id>";
                };
              };
            };
            description = "fetch 后端完整声明(缝无 base 自带,一律带 name)";
          };
          source = lib.mkOption {
            type = lib.types.nullOr (lib.types.oneOf [ lib.types.package lib.types.path ]);
            default = null;
            description = ''
              包源(pkgs.dshPlugins.<name> derivation 或 path);
              null 缺省 registry 尾名反查(row.id)。
            '';
          };
          settings = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "该后端 settings 命名空间段参数(热生效);仅选中时渲染";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          zhipu = {
            row = {
              name = "@fww/dsh-web-fetch-zhipu";
              secretFile = "/run/secrets/zhipu_api_key";
            };
            settings.returnFormat = "markdown";
          };
        }
      '';
      description = ''
        webFetch 后端声明表(开放注册表,镜像 webSearchProviders)。
        声明 ≠ 启用:仅被 webFetch 选中的后端在场(备案待命)。
        webFetch = null × 本表非空 → 求值期 fail-loud(同 webSearch)。
      '';
    };

    webSearchProviders = lib.mkOption {
      # 开放注册表(README:选择器指向的注册表是开放的):
      # - 裸 attrs = base 自带后端(deepseek-official)的纯参数
      # - 完整声明(带 row.name)= 任意新后端,零 nixdsh 改动:
      #   row.name = cordis 包名;row.id? 缺省 web-search-<尾名>;
      #   row.config? = 行引导配置;source? = 包源(缺省 registry
      #   尾名反查);settings = 该后端 settings 段参数;
      #   row.settingsNamespace? = 段名覆盖(缺省 web-search-<id>)
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.attrs
        (lib.types.submodule {
          options = {
            row = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  name = lib.mkOption {
                    type = lib.types.str;
                    example = "@tonydua/dsh-web-search-exa";
                    description = "cordis 包名(insert 行 name;给了 row 即视为非 base 自带后端)";
                  };
                  id = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "行 id 覆盖;null 缺省 web-search-<包名尾段>";
                  };
                  config = lib.mkOption {
                    type = lib.types.attrs;
                    default = { };
                    description = "行引导配置(如 apiKeyEnv;baseURL 等热改项走 settings 段)";
                  };
                  secretFile = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "/run/secrets/zhipu_api_key";
                    description = ''
                      凭据文件路径(sops 等物化)。声明后 wrapper 启动时读文件
                      export 环境变量 —— 所有交互面统一(CLI/TUI/headless/web
                      服务入口都是 wrapper),无需 bash initExtra/EnvironmentFile
                      两条外部桥。env 名 = row.config.apiKeyEnv 显式值 >
                      文件名大写约定(zhipu_api_key → ZHIPU_API_KEY);派生
                      同时渲染 apiKeyEnv 进行 config(行自描述)。同一 env
                      多声明同文件去重,不同文件 → 求值期 throw。
                    '';
                  };
                  settingsNamespace = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "settings 段名覆盖;null 缺省 web-search-<后端 id>";
                  };
                };
              });
              default = null;
              description = "null = base 自带后端(纯参数声明);带 name = 新后端完整声明";
            };
            source = lib.mkOption {
              type = lib.types.nullOr (lib.types.oneOf [ lib.types.package lib.types.path ]);
              default = null;
              description = ''
                包源(pkgs.dshPlugins.<name> derivation 或 path);
                null 缺省 registry 尾名反查(row.id)。
              '';
            };
            settings = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              description = "该后端 settings 命名空间段参数(热生效);仅选中时渲染";
            };
          };
        })
      ]);
      default = { };
      example = lib.literalExpression ''
        {
          # base 自带后端:裸 attrs 即参数
          "deepseek-official".maxUses = 3;
          # 新后端:完整声明(零 nixdsh 改动接入任意 provider)
          exa = {
            row = {
              name = "@tonydua/dsh-web-search-exa";
              config.apiKeyEnv = "EXA_API_KEY";
            };
            settings.numResults = 5;
          };
        }
      '';
      description = ''
        webSearch 后端声明表(开放注册表:选择器指向的注册表开放,
        新后端一条声明接入)。声明 ≠ 启用:仅被 webSearch 选中的后端
        在场(README:声明必有效,在场或被选择器解释 —— 备案待命,
        切换只改 webSearch 一个字符串)。渲染约定见各字段;裸 attrs
        形态 = base 自带后端的纯参数。webSearch = null × 本表非空 →
        求值期 fail-loud。
      '';
    };

    llmDeepseek = lib.mkOption {
      # attrs = settings."llm-deepseek" 段(键:apiKeyEnv/baseURL/thinking/
      # reasoningEffort/models/maxTokens/...,schema 实测 rc.6 源码)
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      example = lib.literalExpression ''
        {
          thinking = "enabled";
          reasoningEffort = "max";
        }
      '';
      description = ''
        DeepSeek 官方 LLM 路由(llm-deepseek adapter)。null(默认)= 禁用:
        DEFAULT_MODELS catalog(v4-flash/pro)无条件注册,无 key 即模型
        选择器死条目,故默认禁(空载荷代价,见 README)。{} = 显式启用
        零配置(key 走 export 或 Web UI 运行时配)。attrs = 启用并渲染进
        settings."llm-deepseek"。与 providers(llm-pi-ai)不互斥:多
        provider 注册表,路由由 defaultModel/settings 选择。
      '';
    };

    # ── LLM 供应商路由(dsh-llm-pi-ai 用户层)──────────────────────────
    # 渲染进 settings.yaml `llm-pi-ai.providers` 命名空间段(cordis 树 base
    # 配置之上的用户层,上游按 provider 逐项深合并,免重启生效)。
    # 刻意不做 preset 库:catalog 元数据(models/baseURL/上下文窗口)由上游
    # pi-ai catalog 持有,catalog 路由只写凭证名即可;手声明路由(如
    # zhipu coding plan 的 anthropic 兼容端点)显式给全字段。
    providers = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.submodule {
        options = {
          apiKeyEnv = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ZHIPU_API_KEY";
            description = ''
              API key 环境变量名(凭证值经环境注入,wrapper 不碰密钥)。
              null 省略该键(本地无鉴权网关);给了 secretFile 且此处
              null → 从文件名派生(大写约定)。
            '';
          };
          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/run/secrets/zhipu_api_key";
            description = ''
              凭据文件路径(sops 等物化)。声明后 wrapper 启动时读文件
              export 环境变量(所有交互面统一入口);env 名 = apiKeyEnv
              显式值 > 文件名大写约定,派生值同时渲染进本路由的
              apiKeyEnv。同 env 多声明去重,不同文件 → 求值期 throw。
            '';
          };
          displayName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "UI 显示名(手声明路由可读性;catalog 路由无需)";
          };
          api = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "openai-completions" "openai-responses" "anthropic-messages" ]);
            default = null;
            description = ''
              线协议。catalog 路由继承 catalog 默认无需给;手声明路由必给
              (缺省视为 openai-completions 仅在 model discovery 场景)。
            '';
          };
          baseURL = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "https://open.bigmodel.cn/api/anthropic";
            description = ''
              API 端点。catalog 路由继承;手声明路由必给
              (含兼容端点,如 zhipu anthropic 兼容层)。
            '';
          };
          models = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            example = [
              { id = "glm-4.7"; contextWindow = 200000; maxTokens = 128000; }
            ];
            description = ''
              模型清单(整表替换 catalog)。行内键:id 必给;name/contextWindow/
              maxTokens/compat/reasoningEfforts 按需。行缺 name 时自动补
              "<displayName 或路由名>/<id>"(/model 里的可读标识;显式 name 优先)。
              空列表 = 沿用上游 catalog(catalog 路由的默认行为)。
            '';
          };
          modelOverrides = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "对 catalog 既有模型条目的字段覆盖(键 = 模型 id;不能与 models 并用)";
          };
          retryPolicy = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            example = lib.literalExpression ''{ mode = "normal"; maxRetries = 2; }'';
            description = "重试策略(mode/maxRetries)";
          };
          defaultContextWindow = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "路由级缺省上下文窗口(models 行未给时兜底)";
          };
          defaultMaxTokens = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "路由级缺省 maxTokens(models 行未给时兜底)";
          };
          compat = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            example = lib.literalExpression ''{ thinkingFormat = "deepseek"; }'';
            description = "推理方言开关(thinkingFormat/supportsReasoningEffort;仅 openai-completions)";
          };
          settings = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = ''
              逃生口:未 typed 化的上游字段直接并进该 provider 段
              (rc 阶段 schema 未稳,同 settings freeform 哲学)。
            '';
          };
        };
      }));
      default = { };
      example = lib.literalExpression ''
        {
          # catalog 路由:只补凭证名,模型/端点全部上游持有
          deepseek.apiKeyEnv = "DEEPSEEK_API_KEY";
          # 手声明路由:zhipu coding plan(anthropic 兼容端点)
          zhipu-coding-plan = {
            apiKeyEnv = "ZHIPU_API_KEY";
            api = "anthropic-messages";
            baseURL = "https://open.bigmodel.cn/api/anthropic";
            models = [ { id = "glm-4.7"; contextWindow = 200000; maxTokens = 128000; } ];
          };
        }
      '';
      description = ''
        LLM 供应商路由声明,渲染进 settings.yaml llm-pi-ai 命名空间段
        (typed 覆盖 freeform settings.llm-pi-ai 同名 provider 条目)。
        与 freeform settings 的分工:这里管类型安全与缺省省略,
        settings.llm-pi-ai 仍可写本层未覆盖的任意键。

        nullOr 三态(README 设计准则):{} 默认 = 启用·惰性(空载荷
        零注册,无可观测面,禁用无收益);null = 禁用(llm-pi-ai 行
        disable 进所有 profile,彻底走 llm-deepseek/其他 adapter 时
        用);null × settings."llm-pi-ai" 有声明或 defaultModel 指向
        pi-ai 路由 → 求值期 fail-loud。
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ DEEPSEEK_API_KEY = "sk-..."; }'';
      description = "wrapper 启动前 export 的环境变量(CLI 场景;service 场景建议用 environmentFiles)";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--patch" "/path/to/overlay.yaml" ];
      description = "附加到每次 dsh 调用的原生 CLI 参数";
    };

    # ── nixvim 式 per-plugin typed 层 ──────────────────────────────────
    # plugins.<name>: enable + settings + patchId + profiles。
    # settings 渲染为 patch 行 { id = patchId; config = settings; } 自动
    # 追加到目标 profile 的 userPatches(即 dsh 官方优先级链的用户层),
    # 插件源自动进目标 profile 的 plugins 列表。
    # patchId 缺省 = 插件名(id 与第三方插件 packageName 一致时可省)。
    # per-plugin typed module(nixdsh/plugins-modules/*.nix)只是给这层
    # 再包一层带默认值的 options —— 底层管线同一个。
    plugins = lib.mkOption {
      # 注意:attrsOf submodule 不支持外部模块向具体键追加 options(module
      # system 限制,nixvim 因此没有全局 plugins option)。typed 便利层的
      # 正确姿势:插件 module 在 programs.dsh.<短名>.<选项> 声明 typed
      # options,在 config 块回填本层(见 plugins-modules/status-rotator.nix)
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "此 dsh 插件" // {
            default = false;
          };
          # 插件源:dshPlugins derivation / fetchFromGitHub / path / in-box 名。
          # 缺省取 pkgs.dshPlugins.<name>(registry 懒式集合,见 plugins/)
          source = lib.mkOption {
            type = lib.types.nullOr (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
            default = null;
            description = ''
              插件源 derivation/path;字符串 = in-box bundle 名
              (@deepseek-ai/dsh-base 等,运行时从 dsh 自身安装解析)。
              缺省 pkgs.dshPlugins.\<name\>(names.txt 镜像;不在 registry 的
              插件显式给 fetchFromGitHub 或路径)。
            '';
          };
          # 交互面声明:本插件是一个 UI 入口 bundle → 自动生成同名 profile
          # (plugins = [ base + 本插件源 ]),并产 dsh-<face> wrapper。
          # 四态:null(缺省)= 从插件元数据推导(registry face= 标记 /
          #   in-box 表),推不出 = 功能插件;true = face 名取本 attr 键
          #   (module system 键唯一 → 无碰撞);字符串 = 显式命名(覆盖
          #   推导;仅 web 等上游硬编码名或改 wrapper 名时需要);
          #   false = 压制推导(registry 标记为 face 的插件当功能插件用)。
          # face 插件不参与跨 profile 分发(交互面 bundle 互斥,混树即
          # duplicate entry / TTY 致死,均实测);功能插件照常分发到所有 face。
          # face 名约束 kebab-case(它成为 profiles/<face> 目录与
          #   dsh-<face> wrapper 名);移除 face 插件后孤儿 profile 目录
          #   由 activation 按 stamp 清理
          face = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.bool lib.types.str);
            default = null;
            example = true;
            description = ''
              交互面声明,通常无需设置:in-box 键名自动映射
              (web-app→web,headless→headless),registry 插件由收录时的
              face= 标记推导。
              true = face 名取本 attr 键;字符串 = 显式命名;false = 压制
              推导(当功能插件用)。生成
              profiles.\<face\>.plugins = [ "@deepseek-ai/dsh-base" source ],
              与显式 profiles.\<face\> 声明互斥。
            '';
          };
          excludedPresets = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "liangshen" ];
            description = ''
              本插件托管 preset 中**不接管**的 id(黑名单):不接管的
              preset 走上游自身通道(如 dsh-tui 的 ensurePackagedPresets
              播种原件),不做能力行重放。排除 id 不在插件探测集内
              (拼错/上游已删)→ 求值期 throw。与显式
              presets.\<id\>.source 声明是两条通道,后者恒胜。
              全禁用 presets = false 更直接,二者互斥(同设 → throw)。
            '';
          };
          presets = lib.mkOption {
            type = lib.types.bool;
            default = true;
            example = false;
            description = ''
              是否接管本插件托管的 preset(自动发现通道总开关)。
              false = 全禁:所有 preset 走上游自身通道(如 dsh-tui 的
              ensurePackagedPresets 播种原件),不做能力行重放 ——
              与 face = false 的"压制自动推导"同构。与
              excludedPresets 同设非空 → 求值期 throw(矛盾声明)。
            '';
          };
          defaultPreset = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "liangshen";
            description = ''
              本 face 树的默认 agent preset(渲染为树上 agent-presets
              行的 default 重述;face 改名自动跟随)。仅交互插件可设
              (非 face 插件无树 → throw)。未设的树回落全局
              programs.dsh.defaultPreset。preset id 存在性不校验:
              手写 preset 在 \$DSH_HOME 是运行时状态,eval 期不可见;
              运行时 roster 自有 UnknownPresetError。
            '';
          };
          permissionMode = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "read-only" "workspace-write" "danger-full-access" ]);
            default = null;
            example = "read-only";
            description = ''
              本 face 树的新会话默认权限模式(胜过全局
              programs.dsh.permissionMode;渲染三行同步一致,见全局项
              说明)。权限活在宿主组合层,per-face 分化物理成立 ——
              这与 preset 能力行(preset id 全局共享,只能均一或
              per-preset fork)是不同的物理。
            '';
          };
          patchId = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              cordis patch 行 id。settings 渲染为
              { id = patchId; config = settings; }。
              dsh-base 以 insert 建行,第三方 bundle patch 若 insert 了
              同名行,其 id 即 packageName —— 此时缺省值可用。
              settings 非空时必给。
            '';
          };
          settings = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = ''
              该插件的 config 行(patch 整行替换语义:覆盖 base/bundle 行时
              必须重述该行全部键,只改一个键也要带其余键 —— dsh 源码注释
              "A patch replaces the targeted row's whole config")。
            '';
          };
          patches = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            description = "额外原始 patch 行(settings 装不下时用,如 disabled/multi 行)";
          };
          profiles = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              生效的目标 profile 名列表;空 = 所有声明的 profile。
              插件源追加进目标 profile 的 plugins,patch 行追加进其 userPatches。
            '';
          };
        };
      });
      default = { };
      description = ''
        nixvim 式插件声明:programs.dsh.plugins.\<name\>.enable = true 即装,
        settings 自动渲染为 cordis patch 用户层。与 profiles.\<name\>.plugins
        (原始列表)可混用:typed 层产物按声明顺序追加在原始列表之后。
      '';
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          plugins = lib.mkOption {
            type = lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
            default = [ ];
            example = lib.literalExpression ''
              [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
            '';
            description = ''
              有序插件列表。字符串 = in-box bundle 名
              (@{lib.concatStringsSep ", " dshLib.inBoxNames});
              path/package = 第三方插件源(fetchFromGitHub derivation 或
              flake=false input 路径均可,需自带 package.json,
              可选 dsh.bundle.patch;见 plugins/README.nix)。
            '';
          };
          userPatchesFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "profile 级 cordis.patch.yml 文件(完整 YAML)";
          };
          userPatches = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            description = "内联 profile patch 列表(JSON 可序列化;!!js 等用 userPatchesFile)";
          };
        };
      });
      default = { };
      description = ''
        dsh profile 声明:各构建为不可变 store 工件,activation 物化到
        \$DSH_HOME/profiles/\<name\>,并产 dsh-\<name\> wrapper 二进制。
      '';
    };

    # agent 预设(rc.5 dsh-agent-presets 实测):目录 = 预设,id = 目录名,
    # agent.cordis.yml(组合树)+ preset.yml(显示元数据)+ 任意 .mjs 插件,
    # 纯文件零构建(宿主 loader 负责模块解析,无需 node_modules)。
    # 热发现:运行中新增免重启(每次调用 re-read roots,同 settings.yaml 档)
    presets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            # path(仓库内目录)/ string(store 路径或插值)/ derivation
            # (dshPlugins 产物)—— toString 归一后在 validatePresets/
            # buildPreset 统一消费
            type = lib.types.path // {
              check = v: builtins.isPath v || builtins.isString v || lib.isDerivation v;
              description = "path or string (store path / interpolated source)";
            };
            description = ''
              预设目录(path 到仓库内,或 store 路径字符串如
              ''${pkgs.dsh}/config/agent-presets/standard),须含 agent.cordis.yml
              (可选 preset.yml 元数据与 .mjs 插件文件)。
              推荐工作流:TUI 创造模式做原型 → cp 进本仓库 → 此处声明
              (声明即接管:activation 物化覆盖同名目录,含创造模式
              迭代版 —— 后续迭代走仓库或先删声明)。
              注意:勿导入插件 shipped 的预设(副本目录含
              .dsh-tui-managed.json 者)—— 那是插件管理的同步物,
              导入会冻结版本并遮蔽插件更新;shipped 预设无需声明。
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          liangshen.source = ./presets/liangshen;  # agent.cordis.yml + preset.yml + *.mjs
        }
      '';
      description = ''
        agent 预设声明:activation 物化到
        \$DSH_HOME/.agent-presets/\<name\>(stamp 同 profile 模式),
        免重启生效。与 shipped 预设同名会被上游 root 优先级遮蔽
        ——改名,勿与官方预设撞 id。roster 行(agent-presets)由
        tui/web 树自带,headless 树无此行(上游 per-face 语义);
        显式 inBoxPlugins.agent-presets.enable = false 与本选项
        冲突,求值期报错。
      '';
    };

    # in-box cordis 条目开关/覆盖(全局,进所有 profile 的用户 patch 层)。
    # 条目默认状态有三种(开/关/!!js 条件),且随 bundle 组合变化 —— 如
    # tool-bash 基础树启用、被 dsh-tui 的 patch 关掉;用户层是最后一层,
    # enable 双向生效(实测:disabled: false 可反向启用 bundle 关掉的条目)。
    #
    # 已知条目 id(rc.5 base 树,`dsh --dump-config` 可查全量;第三方 bundle
    # 的条目 id 同样可写):
    #   llm-deepseek / llm-pi-ai / web-search-deepseek / timer / hmr /
    #   fs-sandbox / bash-sandbox / pwsh-sandbox / approval / permission /
    #   shell-env / tool-bash / tool-pwsh / tool-jobs / storage ...
    # 刻意不做封闭 enum:条目集依赖 profile 组合(求值期不可知),封闭集
    # 会误伤第三方 bundle 条目 —— 免费键 + 文档枚举是诚实边界
    inBoxPlugins = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            example = false;
            description = ''
              null(缺省)= 不表态,沿用组合树默认;false = 追加
              disabled: true 行;true = 追加 disabled: false 行
              (反向启用默认关闭的条目)。
            '';
          };
          config = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = ''
              条目 config 覆盖(整行替换语义:覆盖时必须重述该行全部键,
              只改一个键也要带其余键)。与 enable 可并用。
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          llm-deepseek.enable = false;   # 只用自建 provider 时关掉官方路由
          hmr.enable = true;             # 反向启用默认关闭的条目
        }
      '';
      description = ''
        in-box cordis 条目(dsh-base 等内置树声明的插件)开关与 config
        覆盖。渲染为所有 profile 用户 patch 层的行级 patch(追加在 bundle
        patch 与 typed 插件层之后,同 id 后行胜出)。

        通道选择纪律中的**末选逃生口**(README「插件形态与通道选择」):
        引用的行 id 是树解剖词汇,上游重组/face 装卸后漂移。配置承载型
        优先层 1(typed 意图选项)或层 2(settings 命名空间);频繁落在
        这里 = 层 1 缺 typed 选项的信号。
      '';
    };

    # MCP 服务器(rc.5 dsh-mcp-client 实测):插件不在默认树,每 server
    # 一行 cordis 行(name @deepseek-ai/dsh-mcp-client),工具暴露为
    # mcp__<serverName>__<tool>。行渲染进所有 profile → 变化走 bundle
    # 指纹重启(web 服务自动跟进)。env/headers 值支持 secretFile 形态
    # (占位符 + wrapper 启动期注入,store 工件零密钥)
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          transport = lib.mkOption {
            type = lib.types.enum [ "stdio" "streamable-http" ];
            default = "stdio";
            description = "stdio(本地命令)或 streamable-http(远程端点)";
          };
          command = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "stdio:子进程命令(如 nix store 路径里的 mcp-server)";
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "stdio:子进程参数";
          };
          env = lib.mkOption {
            type = lib.types.attrsOf (lib.types.oneOf [
              lib.types.str
              (lib.types.submodule {
                options = {
                  secretFile = lib.mkOption {
                    type = lib.types.str;
                    description = "密钥文件路径(运行时读,如 /run/secrets/xxx)";
                  };
                  prefix = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "Bearer ";
                    description = "值前缀(如 Authorization 头)";
                  };
                };
              })
            ]);
            default = { };
            description = ''
              stdio:子进程环境变量。值 = 字面字符串,或
              { secretFile = "/run/secrets/x"; prefix? = "..."; }
              —— secret 形态渲染为占位符(store 工件零密钥),
              wrapper 每次启动注入真值到物化 patch(0600,轮换安全;
              上游实测:子进程环境密钥名被 scrub,显式 env 是官方
              唯一凭证通道)。
            '';
          };
          cwd = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "stdio:子进程工作目录";
          };
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "streamable-http:端点 URL";
          };
          headers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.oneOf [
              lib.types.str
              (lib.types.submodule {
                options = {
                  secretFile = lib.mkOption {
                    type = lib.types.str;
                    description = "密钥文件路径(运行时读,如 /run/secrets/xxx)";
                  };
                  prefix = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "Bearer ";
                    description = "头值前缀(如 \"Bearer \")";
                  };
                };
              })
            ]);
            default = { };
            description = ''
              streamable-http:请求头。值 = 字面字符串,或
              { secretFile; prefix? } secret 形态(同 env 的注入语义)。
            '';
          };
          toolCallTimeoutMs = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "工具调用超时;null 省略(用上游默认)";
          };
          failOnStartupError = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "启动连接失败时让整树失败(false = 跳过该 server 继续启动)";
          };
          settings = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "逃生口:未 typed 化字段(如 reconnect 策略)直接并进该行 config";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          filesystem = {
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-filesystem" "/home" ];
          };
        }
      '';
      description = ''
        MCP 服务器声明:每条渲染一个 insert 条目到所有 profile
        (id = mcp-\<name\>,serverName = attr 名)。插件
        @deepseek-ai/dsh-mcp-client 随行插入,不在默认树也无须
        inBoxPlugins 启用 —— 要卸载就删条目本身(经 inBoxPlugins
        disable 无效:id 不在树上)。schema 实测于 dsh-mcp-client
        (判别联合:stdio / streamable-http)。
      '';
    };

    # skills(dsh-skill-filesystem 实测):Markdown + YAML frontmatter,
    # 平铺 <名>.md 或目录束 <名>/SKILL.md。发现根含 $DSH_HOME/skills
    # 与跨 agent 标准目录 ~/.agents/skills;watch 热发现免重启。
    # 此处物化到 $DSH_HOME/skills(跨 agent 共享的技能由各工具自行管理
    # ~/.agents/skills,不属 dsh 模块管辖)
    skills = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = ''
              skill 文件:单文件 .md(path)或目录(path,须含 SKILL.md,
              可带辅助资源文件)。attr 名 = skill 名。
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          deploy-check.source = ./skills/deploy-check.md;
          pdf-inspector.source = ./skills/pdf-inspector;  # 目录束
        }
      '';
      description = ''
        skill 声明:activation 物化到 \$DSH_HOME/skills/\<名\>[.md]
        (stamp 语义同 presets),上游 watch 热发现免重启。
        依赖:发现插件 skill-filesystem 在 base 树默认启用;显式
        inBoxPlugins.skill-filesystem.enable = false 与本选项冲突,
        求值期报错(物化文件将无人发现,静默失效更糟)。
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''[ config.sops.secrets.dsh-env.path ]'';
      description = ''
        systemd user service 的 EnvironmentFile(如 sops 渲染的 env,
        含 API key)。仅 web 服务消费;CLI 走 environment 或会话环境。
      '';
    };

    web = {
      enable = lib.mkEnableOption "常驻 dsh web 服务(systemd user)";
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "开机自启(default.target);关掉则需手动 systemctl --user start";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Web UI 绑定地址(dsh 是能执行 shell 的 agent harness,默认仅回环)";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3080;
        description = "Web UI 端口";
      };
      trustedHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "/api browser-trust fence 额外接受的 authority";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "dsh web 附加参数";
      };
    };
  };
}
