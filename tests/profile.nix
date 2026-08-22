# profile 域(nix-unit):face 四态推导、inBoxPlugins 三态行、
# patch 行 YAML emitter(金样)、bash 补全(金样)、wrapper 保留名负例。
# 行为级(stderr 过滤/dispatch 块渲染/真 boot)在 checks/profile.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith mkFakeCfg;

  # ── face 四态场景(共享一次 applyPlugins 求值)──
  facePlugin =
    { face, source }:
    {
      enable = true;
      inherit face source;
      profiles = [ ];
      settings = { };
      patches = [ ];
      patchId = null;
    };
  r = applyWith {
    profiles = { };
    plugins = {
      "web-app" = facePlugin {
        face = null;
        source = "@deepseek-ai/dsh-web-app";
      }; # ← in-box 表推导 "web"
      "my-desktop" = facePlugin {
        face = true;
        source = "@deepseek-ai/dsh-headless";
      }; # ← 键名派生
      "rotator" = facePlugin {
        face = false;
        source = "./fixture-rotator";
      }; # ← 压制为功能插件
      "dsh-tui" = facePlugin {
        face = null;
        source = null;
      }; # ← registry 尾名反查 + passthru.dshFace
      "dsh-desktop" = facePlugin {
        face = true;
        source = "@deepseek-ai/dsh-headless";
      }; # ← 剥 dsh- 前缀派生
    };
  };

  # ── inBoxPlugins 三态场景 ──
  inboxRows =
    (applyWith {
      inBoxPlugins = {
        "llm-deepseek".enable = false;
        hmr.enable = true;
        "web-search-deepseek".enable = null; # 不表态 → 无行
        timer.config.timeoutMs = 30000;
      };
    }).inBoxPatches;

  # wrapper applied 单算(求值单次原则;fake cfg 各键 or-守卫,
  # applyPlugins 无 MCP 声明时零副作用)
  wrapperApplied = cfg: dshLib.applyPlugins { inherit cfg pkgs; };
in
{
  face = {
    # 四态推导全集(null→in-box 表 / 零 source→registry 反查 + passthru.dshFace /
    # true→键名派生且剥 dsh- 前缀 / false→压制为功能插件不入 face 表)
    test-faces-derived = {
      expr = builtins.attrNames r.facePlugins;
      expected = [
        "desktop"
        "my-desktop"
        "tui"
        "web"
      ];
    };
    # perProfile 覆盖全部自动 face;被压制(false)的 rotator 作为功能插件
    # 分发进每个 face 树(各恰 1 个 extraPlugin)
    test-distribution = {
      expr = builtins.mapAttrs (_: p: builtins.length p.extraPlugins) r.perProfile;
      expected = {
        desktop = 1;
        my-desktop = 1;
        tui = 1;
        web = 1;
      };
    };
    # 保留名负例:profile/face 名撞上游子命令(plugin 语义 ≠ profile boot)
    # → renderWrapper 求值期 throw
    test-reserved-subcommand-rejected = {
      expr = dshLib.renderWrapper {
        cfg = mkFakeCfg { };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { });
        subcommands = [ "plugin" ];
      };
      expectedError.type = "ThrownError";
    };
  };

  inbox = {
    # 三态行全集金样:enable=false → disabled=true / enable=true → disabled=false /
    # enable=null(不表态)→ 不出行 / config → 渲染
    test-rows = {
      expr = inboxRows;
      expected = [
        {
          id = "hmr";
          disabled = false;
        }
        {
          id = "llm-deepseek";
          disabled = true;
        }
        {
          id = "timer";
          config.timeoutMs = 30000;
        }
      ];
    };
  };

  patch-yaml = {
    # emitter 全域金样:bool 显式(Nix toString true = "1" 的 shell 强转不可漏)、
    # int 不加引号、嵌套/内联空集合、怪键引号、rawYaml 标签原样落盘
    # (!!js 与上游 patch 文件同构)、顶层 disable 行。
    # yq 独立解析器交叉验证在 checks/sources.nix
    test-emitter = {
      expr = dshLib.patchesToYaml [
        {
          id = "sandbox-policy";
          config = {
            mode = "workspace-write";
            workspaceRoot = dshLib.rawYaml "!!js process.cwd()";
          };
        }
        {
          id = "tool-web";
          config = {
            fetch = true;
            disabled-flag = false;
            searchTimeoutMs = 60000;
          };
        }
        {
          id = "empty-collections";
          config = {
            list = [ ];
            attrs = { };
            nested.deep = [
              1
              "two"
            ];
          };
        }
        {
          id = "quoted";
          config."odd key: v" = "has: colon and more";
        }
        {
          id = "plain-disable";
          disabled = true;
        }
      ];
      expected = builtins.readFile ./fixtures/patch-yaml-expected.yml;
    };
  };

  completion = {
    # bash 补全金样:$1 词表 = 分发名单 + 上游命令(--profile 值词表含 web)
    test-word-lists = {
      expr = dshLib.renderCompletion {
        subcommands = [
          "tui"
          "headless"
        ];
        profiles = [
          "web"
          "tui"
          "headless"
        ];
        upstream = [
          "web"
          "plugin"
        ];
      };
      expected = builtins.readFile ./fixtures/completion-expected.bash;
    };
  };
}
