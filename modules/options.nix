# filepath: ~/nixos-config/pkgs/dsh/modules/options.nix
# programs.dsh 共享 options —— HM(hm-module.nix)与 NixOS(nixos-module.nix)
# 及 lib.nix 的 mkDsh 独立求值三方共用(TonyWu20 单 options 多消费面模式)
#
# typing 策略(nixvim 教训 × jcode 注释"逐键建模必腐化"):
#   typed core 只收 CLI 层确定项(defaultProfile/web 服务)与两源一致确认的
#   telemetry.mode;settings 整体 freeform(= 逃生口),model/models 等上游
#   rc 阶段键名未稳(hieutran 写 models、TonyWu20 写 model)不 typed 化
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

    # ── LLM 供应商路由(dsh-llm-pi-ai 用户层)──────────────────────────
    # 渲染进 settings.yaml `llm-pi-ai.providers` 命名空间段(cordis 树 base
    # 配置之上的用户层,上游按 provider 逐项深合并,免重启生效)。
    # 刻意不做 preset 库:catalog 元数据(models/baseURL/上下文窗口)由上游
    # pi-ai catalog 持有,catalog 路由只写凭证名即可;手声明路由(如
    # zhipu coding plan 的 anthropic 兼容端点)显式给全字段。
    providers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          apiKeyEnv = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ZHIPU_API_KEY";
            description = ''
              API key 环境变量名(凭证值经环境注入,wrapper 不碰密钥)。
              null 省略该键(本地无鉴权网关)。
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
              maxTokens/compat/reasoningEfforts 按需。空列表 = 沿用上游
              catalog(catalog 路由的默认行为)。
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
      });
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
