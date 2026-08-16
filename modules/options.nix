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
          # 插件源:dshPlugins derivation / fetchFromGitHub / path。
          # 缺省取 pkgs.dshPlugins.<name>(registry 懒式集合,见 plugins/)
          source = lib.mkOption {
            type = lib.types.nullOr (lib.types.oneOf [ lib.types.path lib.types.package ]);
            default = null;
            description = ''
              插件源 derivation/path。缺省 pkgs.dshPlugins.\<name\>
              (names.txt 镜像;不在 registry 的插件显式给 fetchFromGitHub 或路径)。
            '';
          };
          patchId = lib.mkOption {
            type = lib.types.str;
            description = ''
              cordis patch 行 id。settings 渲染为
              { id = patchId; config = settings; }。
              dsh-base 以 insert 建行,第三方 bundle patch 若 insert 了
              同名行,其 id 即 packageName —— 此时缺省值可用。
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
