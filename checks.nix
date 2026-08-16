# filepath: ~/nixos-config/pkgs/dsh/checks.nix
# dsh profile 模型 flake checks(不阻塞日常 rebuild,nix flake check 时跑)
# 分层验证(共识 Q6/Q16):包内 installCheck 已覆盖 CLI 本身;此处覆盖 profile 组合:
#   dsh-profile-structure : bundle 工件形状(bundles 层序 + cordis 双文件)
#   dsh-profile-headless  : 正例 — headless profile 组合树可渲染(dsh --dump-config)
#   dsh-profile-nobase    : 负例 — 缺 @deepseek-ai/dsh-base 的组合 boot 必须 fail-loud
# 实测依据(rc.5):--dump-config 对坏组合只打印 "entry not found" 但 exit 0,
# 真正的 fail-loud(assertEntriesActivated: pending waiting for service)只在
# 实际 boot 时触发 → 负例用无参 boot 断言非零退出
{ pkgs }:

let
  dshLib = import ./lib.nix { inherit (pkgs) lib; };

  mkBundle = name: plugins:
    dshLib.buildProfile {
      inherit pkgs;
      profile = dshLib.mkProfile { inherit name plugins; };
    };

  goodProfile = mkBundle "web" [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
  ];

  headlessProfile = mkBundle "headless" [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-headless"
  ];

  # 负例:web-app 缺 base — dsh boot 的 assertEntriesActivated 必须拒绝
  nobaseProfile = mkBundle "web-nobase" [
    "@deepseek-ai/dsh-web-app"
  ];

  # face 四态语义:true=键名派生(module system 键唯一)/false=压制推导/
  # null=in-box 表推导;face 插件不参与分发,功能插件分发到含自动 face
  dsh-face-gen =
    let
      r = dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          profiles = { };
          plugins = {
            "web-app" = {
              enable = true;
              face = null; # ← in-box 表推导出 "web"
              source = "@deepseek-ai/dsh-web-app";
              profiles = [ ];
              settings = { };
              patches = [ ];
              patchId = null;
            };
            "my-desktop" = {
              enable = true;
              face = true; # ← 键名派生
              source = "@deepseek-ai/dsh-headless";
              profiles = [ ];
              settings = { };
              patches = [ ];
              patchId = null;
            };
            "rotator" = {
              enable = true;
              face = false; # ← 压制(若元数据标记过 face,当功能插件用)
              source = "./fixture-rotator";
              profiles = [ ];
              settings = { };
              patches = [ ];
              patchId = null;
            };
          };
          inBoxPlugins = { };
        };
      };
      assert' = cond: msg: pkgs.lib.assertMsg cond msg;
      # dsh <face> 子命令分发:主 wrapper 脚本内容(build 期 grep);
      # web 排除(上游原生 web 子命令已等价 boot profiles.web)
      fakeCfg = {
        settings = { };
        telemetry = { mode = null; };
        providers = { };
        defaultModel = null;
        environment = { };
        dshHome = "/tmp/fake-dsh-home";
        package = pkgs.hello;
        defaultProfile = "base";
        extraArgs = [ ];
      };
      dispatchWrapper = dshLib.renderWrapper {
        cfg = fakeCfg;
        inherit pkgs;
        faces = [ "tui" "web" ];
      };
      plainWrapper = dshLib.renderWrapper {
        cfg = fakeCfg;
        inherit pkgs;
      };
      # 保留名负例:face "plugin" 与上游 pnpm 子命令冲突 → 求值期 throw。
      # tryEval 须强制到 .facePlugins(attrset WHNF 不触发内部 seq 断言)
      badPlugin = builtins.tryEval
        (builtins.seq
          (dshLib.applyPlugins {
            inherit pkgs;
            cfg = {
              profiles = { };
              plugins."terminal" = {
                enable = true;
                face = "plugin";
                source = "@deepseek-ai/dsh-headless";
                profiles = [ ];
                settings = { };
                patches = [ ];
                patchId = null;
              };
              inBoxPlugins = { };
            };
          }).facePlugins
          null);
      assertions = toString [
        (assert' (r.facePlugins ? web) "dsh-face-gen: in-box table must derive 'web' from null face")
        (assert' (r.facePlugins ? my-desktop) "dsh-face-gen: face=true must derive attr key name")
        (assert' (!r.facePlugins ? rotator) "dsh-face-gen: face=false must suppress to function plugin")
        (assert' (r.perProfile ? web && r.perProfile ? my-desktop)
          "dsh-face-gen: perProfile must cover auto faces")
        (assert' (builtins.length r.perProfile.web.extraPlugins == 1)
          "dsh-face-gen: suppressed (false) plugin must distribute as function plugin")
        (assert' (!badPlugin.success) "dsh-face-gen: face 'plugin' must be rejected at eval time")
      ];
    in
    # seq 强制断言求值(任一失败 → 求值期 fail-loud);buildCommand grep
    # 验证分发块渲染:tui 在/web 排除/空 faces 无块
    pkgs.runCommand "dsh-face-gen-check" { } (builtins.seq assertions ''
      grep -q 'tui)' ${dispatchWrapper}/bin/dsh
      grep -qF -- '--profile "$_dsh_face"' ${dispatchWrapper}/bin/dsh
      ! grep -qF 'tui|web' ${dispatchWrapper}/bin/dsh
      ! grep -q '_dsh_face' ${plainWrapper}/bin/dsh
      touch $out
    '');

  # inBoxPlugins 双向渲染:disable/enable/config 三态行落进 bundle patch
  inBoxRows =
    let
      rows = (dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          plugins = { };
          profiles = { default = { }; };
          inBoxPlugins = {
            "llm-deepseek".enable = false;
            hmr.enable = true;
            "web-search-deepseek".enable = null; # 不表态 → 无行
            timer.config.timeoutMs = 30000;
          };
        };
      }).inBoxPatches;
      asSet = builtins.listToAttrs (map (r: { name = r.id; value = r; }) rows);
      has = id: builtins.elem id (builtins.attrNames asSet);
    in
    pkgs.runCommand "dsh-inbox-rows-check" { } (builtins.seq ([
      (pkgs.lib.assertMsg (!has "web-search-deepseek") "inBoxPlugins: null enable must emit no row")
      (pkgs.lib.assertMsg (asSet."llm-deepseek".disabled == true) "inBoxPlugins: enable=false must set disabled=true")
      (pkgs.lib.assertMsg (asSet.hmr.disabled == false) "inBoxPlugins: enable=true must set disabled=false")
      (pkgs.lib.assertMsg (asSet.timer.config.timeoutMs == 30000) "inBoxPlugins: config must render")
    ]) "touch $out");

  # 物化 bundle 到 scratch DSH_HOME(dsh boot 会改写 profile 根 cordis.yml,须可写副本)
  materialize = name: bundle: ''
    home="$TMPDIR/dsh-home"
    mkdir -p "$home/profiles"
    cp -a ${bundle} "$home/profiles/${name}"
    chmod -R u+w "$home/profiles/${name}"
    export DSH_HOME="$home"
  '';
in
{
  dsh-face-gen = dsh-face-gen;
  dsh-inbox-rows = inBoxRows;
  dsh-profile-structure = pkgs.runCommand "dsh-profile-structure-check"
    { nativeBuildInputs = [ pkgs.jq ]; } ''
      bundle=${goodProfile}
      expected='["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app"]'
      actual=$(jq -c '.dsh.profile.bundles' "$bundle/package.json")
      test "$actual" = "$expected" || {
        echo "bundles mismatch: $actual != $expected" >&2; exit 1;
      }
      test -f "$bundle/cordis.yml" || { echo "missing cordis.yml" >&2; exit 1; }
      test -f "$bundle/cordis.patch.yml" || { echo "missing cordis.patch.yml" >&2; exit 1; }
      touch "$out"
    '';

  dsh-profile-headless = pkgs.runCommand "dsh-profile-headless-check" { } ''
      ${materialize "headless" headlessProfile}
      ${pkgs.dsh}/bin/dsh --profile headless --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      # dsh-base 的条目必须在组合树里(证明层序叠加生效,而非空树碰巧 exit 0)
      grep -q "cordis-plugin-timer" "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "base layer entries missing from composed tree" >&2; exit 1;
      }
      touch "$out"
    '';

  # 负例:无参 boot 必须非零退出且 fail-loud 于 assertEntriesActivated
  dsh-profile-nobase = pkgs.runCommand "dsh-profile-nobase-check" { } ''
      ${materialize "web-nobase" nobaseProfile}
      if ${pkgs.dsh}/bin/dsh --profile web-nobase > "$TMPDIR/boot.log" 2>&1; then
        echo "profile without base unexpectedly booted" >&2
        exit 1
      fi
      grep -q "assertEntriesActivated" "$TMPDIR/boot.log" || {
        cat "$TMPDIR/boot.log" >&2
        echo "expected assertEntriesActivated fail-loud, different failure mode" >&2
        exit 1
      }
      touch "$out"
    '';

  # renderSettings 合并语义:typed providers 逐条覆盖 freeform 同名条目、
  # null/空字段省略、freeform 命名空间其他键与其他 provider 条目保留。
  # 断言在求值期生效:任一不成立 → check 求值失败(fail-loud 无需构建)
  dsh-providers-render =
    let
      rendered = dshLib.renderSettings {
        settings = {
          telemetry.mode = "on";
          "agent-default-model".reasoning = "low";
          "llm-pi-ai".providers = {
            deepseek.apiKeyEnv = "FREEFORM_KEY";
            other-gateway.apiKeyEnv = "OTHER_KEY";
          };
        };
        telemetry = { mode = "off"; };
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
              { id = "glm-4.7"; contextWindow = 200000; }
              { id = "glm-5.3"; name = "GLM 5.3"; }
            ];
          };
        };
      };
      provs = rendered."llm-pi-ai".providers;
      assert' = cond: msg: pkgs.lib.assertMsg cond msg;
      # 接进 buildCommand 才脱离懒求值(Nix check 求值 drv 属性时强制)
      assertions = toString [
        (assert' (provs.deepseek.apiKeyEnv == "DEEPSEEK_API_KEY") "dsh-providers-render: typed must win per-provider")
        (assert' (!provs.deepseek ? displayName) "dsh-providers-render: null fields must be omitted")
        (assert' (!provs.deepseek ? retryPolicy) "dsh-providers-render: empty attrs must be omitted")
        (assert' (provs ? "zhipu-coding-plan") "dsh-providers-render: hand-declared route must render")
        (assert' ((builtins.elemAt provs.deepseek.models 0).name == "deepseek/deepseek-chat") "dsh-providers-render: model name must default to route key/id when displayName is null")
        (assert' ((builtins.elemAt provs."zhipu-coding-plan".models 0).name == "Zhipu Coding/glm-4.7") "dsh-providers-render: model name must default to displayName/id")
        (assert' ((builtins.elemAt provs."zhipu-coding-plan".models 1).name == "GLM 5.3") "dsh-providers-render: explicit model name must win")
        (assert' (provs ? other-gateway) "dsh-providers-render: freeform sibling providers must survive")
        (assert' (rendered.telemetry.mode == "off") "dsh-providers-render: telemetry merge must still hold")
        (assert' (rendered."agent-default-model".provider == "zhipu-coding-plan") "dsh-providers-render: typed defaultModel must render")
        (assert' (rendered."agent-default-model".reasoning == "low") "dsh-providers-render: freeform defaultModel sibling keys must survive")
        (assert' (!rendered."agent-default-model" ? reasoningEffort) "dsh-providers-render: null reasoningEffort must be omitted")
      ];
    in
    # seq 强制断言求值(任一失败 → 求值期 fail-loud),buildCommand 本身无操作
    pkgs.runCommand "dsh-providers-render-check"
      { } (builtins.seq assertions "touch $out");
}
