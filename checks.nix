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
            # 零 source + 零 face:registry 尾名反查(键名 dsh-tui →
            # @deepseek-harness-tui/dsh-tui)+ passthru.dshFace → face "tui"
            "dsh-tui" = {
              enable = true;
              face = null;
              source = null;
              profiles = [ ];
              settings = { };
              patches = [ ];
              patchId = null;
            };
            # face=true + dsh- 前缀键名:剥前缀派生(免 dsh dsh-desktop 冗余)
            "dsh-desktop" = {
              enable = true;
              face = true;
              source = "@deepseek-ai/dsh-headless";
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
      # dsh <profile> 子命令分发:主 wrapper 脚本内容(build 期 grep);
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
        subcommands = [ "tui" "web" ];
      };
      plainWrapper = dshLib.renderWrapper {
        cfg = fakeCfg;
        inherit pkgs;
      };
      # bash 补全:分发名单 + 上游命令都在 $1 词表,--profile 值含 web
      completionText = dshLib.renderCompletion {
        subcommands = [ "tui" "headless" ];
        profiles = [ "web" "tui" "headless" ];
        upstream = [ "web" "plugin" ];
      };
      # 保留名负例:profile/face 名撞上游子命令(plugin 语义 ≠ profile
      # boot)→ renderWrapper 求值期 throw。fake package 无 bin.js →
      # upstreamSubcommands 回落内置名单 {web,plugin};tryEval 须强制
      # 求值到脚本内容(writeShellScriptBin derivation)
      badCmd = builtins.tryEval
        (builtins.deepSeq
          (dshLib.renderWrapper {
            cfg = fakeCfg;
            inherit pkgs;
            subcommands = [ "plugin" ];
          })
          null);
      assertions = toString [
        (assert' (r.facePlugins ? web) "dsh-face-gen: in-box table must derive 'web' from null face")
        (assert' (r.facePlugins ? my-desktop) "dsh-face-gen: face=true must derive attr key name")
        (assert' (!r.facePlugins ? rotator) "dsh-face-gen: face=false must suppress to function plugin")
        (assert' (r.facePlugins ? tui) "dsh-face-gen: zero-source registry lookup must derive face 'tui' from passthru.dshFace")
        (assert' (r.facePlugins ? desktop) "dsh-face-gen: face=true must strip dsh- prefix from attr key")
        (assert' (!r.facePlugins ? "dsh-desktop") "dsh-face-gen: stripped face must replace the prefixed key name")
        (assert' (r.perProfile ? web && r.perProfile ? my-desktop)
          "dsh-face-gen: perProfile must cover auto faces")
        (assert' (builtins.length r.perProfile.web.extraPlugins == 1)
          "dsh-face-gen: suppressed (false) plugin must distribute as function plugin")
        (assert' (!badCmd.success) "dsh-face-gen: name clashing upstream subcommand must be rejected at eval time")
      ];
    in
    # seq 强制断言求值(任一失败 → 求值期 fail-loud);buildCommand grep
    # 验证分发块渲染:tui 在/web 排除/空 faces 无块
    pkgs.runCommand "dsh-face-gen-check" { } (builtins.seq assertions ''
      grep -q 'tui)' ${dispatchWrapper}/bin/dsh
      grep -qF -- '--profile "$_dsh_face"' ${dispatchWrapper}/bin/dsh
      ! grep -qF 'tui|web' ${dispatchWrapper}/bin/dsh
      ! grep -q '_dsh_face' ${plainWrapper}/bin/dsh
      # 补全词表:子命令含 tui/headless/plugin,profile 词含 web
      echo ${pkgs.lib.escapeShellArg completionText} > "$TMPDIR/dsh-completion"
      grep -qF 'compgen -W "tui headless web plugin"' "$TMPDIR/dsh-completion"
      grep -qF 'compgen -W "web tui headless plugin"' "$TMPDIR/dsh-completion"
      grep -qF 'complete -F _dsh dsh' "$TMPDIR/dsh-completion"
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

  # agent 预设:eval 期校验(缺 agent.cordis.yml → throw;正例 =
  # fixtures/preset-ok 目录);物化脚本在 hm-module activation
  # (与 profile 同 stamp 模式,不重复验证)
  dsh-presets =
    let
      bad = builtins.tryEval
        (builtins.deepSeq
          (dshLib.validatePresets { "no-composition".source = ./checks.nix; })
          null);
      good = dshLib.validatePresets {
        ok.source = ./fixtures/preset-ok;
      };
    in
    pkgs.runCommand "dsh-presets-check" { }
      (builtins.seq (pkgs.lib.assertMsg (!bad.success)
        "dsh-presets: source without agent.cordis.yml must be rejected at eval time")
        (builtins.seq (pkgs.lib.assertMsg (good ? ok)
          "dsh-presets: valid preset directory must pass")
          "touch $out"));

  # MCP 服务器行渲染:判别联合(stdio/streamable-http)、null 省略、
  # settings 逃生口并入、serverName = attr 名
  dsh-mcp-render =
    let
      rows = (dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          profiles = { default = { }; };
          plugins = { };
          inBoxPlugins = { };
          mcpServers = {
            filesystem = {
              transport = "stdio";
              command = "/run/current-system/sw/bin/npx";
              args = [ "-y" "@modelcontextprotocol/server-filesystem" "/home" ];
              env = { };
              cwd = null;
              url = null;
              headers = { };
              toolCallTimeoutMs = null;
              failOnStartupError = false;
              settings = { reconnect.maxAttempts = 5; };
            };
            remote = {
              transport = "streamable-http";
              url = "https://mcp.example.com/mcp";
              headers = {
                Authorization.secretFile = "/run/secrets/fake-token";
                Authorization.prefix = "Bearer ";
                X-Plain = "literal";
              };
              command = null;
              args = [ ];
              env = { };
              cwd = null;
              toolCallTimeoutMs = 30000;
              failOnStartupError = false;
              settings = { };
            };
            gh = {
              transport = "stdio";
              command = "gh";
              env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh";
              args = [ ];
              cwd = null;
              url = null;
              headers = { };
              toolCallTimeoutMs = null;
              failOnStartupError = false;
              settings = { };
            };
          };
        };
      }).mcpPatches;
      byId = builtins.listToAttrs (map
        (r: { name = r.id; value = r; })
        (pkgs.lib.flatten (map (r: r.insert or [ ]) rows)));
      fs = byId."mcp-filesystem".config;
      rm = byId."mcp-remote".config;
      gh = byId."mcp-gh".config;
      allInsertShaped = builtins.all (r: r ? insert && builtins.length r.insert == 1) rows;
      refs = (dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          profiles = { default = { }; };
          plugins = { };
          inBoxPlugins = { };
          mcpServers = { gh.env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh"; };
        };
      }).mcpSecretRefs;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-mcp-render-check" { } (builtins.seq ([
      (assert' allInsertShaped "dsh-mcp-render: rows must be insert-wrapped (patch rows for unknown ids are warn-skipped by the loader)")
      (assert' (byId ? "mcp-filesystem" && byId ? "mcp-remote" && byId ? "mcp-gh") "dsh-mcp-render: one entry per server must render")
      (assert' (fs.serverName == "filesystem" && fs.command != null) "dsh-mcp-render: stdio server must carry serverName+command")
      (assert' (!fs ? cwd && !fs ? toolCallTimeoutMs) "dsh-mcp-render: null fields must be omitted")
      (assert' (fs.reconnect.maxAttempts == 5) "dsh-mcp-render: settings escape hatch must merge into config")
      (assert' (rm ? url && rm ? headers && rm.toolCallTimeoutMs == 30000) "dsh-mcp-render: streamable-http must carry url/headers")
      (assert' (!rm ? command && !rm ? args) "dsh-mcp-render: http server must not carry stdio fields")
      (assert' (rm.headers.Authorization == "Bearer @dsh-secret:/run/secrets/fake-token@") "dsh-mcp-render: secretFile header must render prefix+placeholder")
      (assert' (rm.headers.X-Plain == "literal") "dsh-mcp-render: literal header must stay literal")
      (assert' (gh.env.GITHUB_PERSONAL_ACCESS_TOKEN == "@dsh-secret:/run/secrets/fake-gh@") "dsh-mcp-render: secretFile env must render bare placeholder")
      (assert' (builtins.length refs == 1 && builtins.head refs == "/run/secrets/fake-gh") "dsh-mcp-render: mcpSecretRefs must dedupe and collect")
    ]) "touch $out");

  # skills 源校验:平铺 .md / 目录束(SKILL.md)双形态 + 双负例 +
  # 依赖冲突负例(声明 skills 而 disable 发现插件 → eval throw)
  dsh-skills =
    let
      ok = dshLib.validateSkills {
        flat.source = ./fixtures/skill-flat.md;
        bundle.source = ./fixtures/skill-bundle;
      };
      badDir = builtins.tryEval (builtins.deepSeq
        (dshLib.validateSkills { x.source = ./fixtures; }) null);
      badExt = builtins.tryEval (builtins.deepSeq
        (dshLib.validateSkills { x.source = ./checks.nix; }) null);
      applyWith = extra: dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          profiles = { default = { }; };
          plugins = { };
          skills = { };
          presets = { };
          inBoxPlugins = { };
        } // extra;
      };
      skillClash = builtins.tryEval (builtins.deepSeq
        (applyWith {
          skills.flat.source = ./fixtures/skill-flat.md;
          inBoxPlugins."skill-filesystem".enable = false;
        }).facePlugins null);
      presetClash = builtins.tryEval (builtins.deepSeq
        (applyWith {
          presets.mine.source = ./fixtures/preset-ok;
          inBoxPlugins."agent-presets".enable = false;
        }).facePlugins null);
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-skills-check" { } (builtins.seq ([
      (assert' (ok.flat == "flat.md") "dsh-skills: flat .md must map to <name>.md")
      (assert' (ok.bundle == "bundle") "dsh-skills: directory must map to <name>/")
      (assert' (!badDir.success) "dsh-skills: directory without SKILL.md must throw")
      (assert' (!badExt.success) "dsh-skills: non-.md file must throw")
      (assert' (!skillClash.success) "dsh-skills: skills + skill-filesystem disabled must throw at eval time")
      (assert' (!presetClash.success) "dsh-skills: presets + agent-presets disabled must throw at eval time")
    ]) "touch $out");

  # secret 注入行为级验证:真跑 wrapper 启动块,对物化 patch 注入真值,
  # 验证 0600/占位符清零(build 沙箱 /tmp 可写,fixed home 固定路径)
  dsh-mcp-secret-inject =
    let
      home = "/tmp/dsh-inject-check-home";
      secretFile = "/tmp/dsh-inject-check-secret";
      fakeCfg = {
        settings = { };
        telemetry = { mode = null; };
        providers = { };
        defaultModel = null;
        environment = { };
        dshHome = home;
        package = pkgs.hello;
        defaultProfile = "default";
        extraArgs = [ ];
        mcpServers = {
          gh = {
            transport = "stdio";
            command = "true";
            env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = secretFile;
            args = [ ];
            cwd = null;
            url = null;
            headers = { };
            toolCallTimeoutMs = null;
            failOnStartupError = false;
            settings = { };
          };
        };
        profiles = { default = { plugins = [ ]; userPatches = [ ]; }; };
        plugins = { };
        inBoxPlugins = { };
      };
      wrapper = dshLib.renderWrapper { cfg = fakeCfg; inherit pkgs; };
      # 模拟 activation 产物:bundle patch 含占位符
      placeholderPatch = pkgs.writeText "cordis.patch.yml" ''
        - id: mcp-gh
          name: '@deepseek-ai/dsh-mcp-client'
          config:
            env:
              GITHUB_PERSONAL_ACCESS_TOKEN: '@dsh-secret:${secretFile}@'
      '';
    in
    pkgs.runCommand "dsh-mcp-secret-inject-check" { } ''
      install -D -m 0644 ${placeholderPatch} ${home}/profiles/default/cordis.patch.yml
      printf 'REALTOKEN123\n' > ${secretFile}
      ${wrapper}/bin/dsh >/dev/null 2>&1 || true
      pf=${home}/profiles/default/cordis.patch.yml
      grep -q REALTOKEN123 "$pf" || { echo "secret not injected"; cat "$pf"; exit 1; }
      ! grep -q '@dsh-secret:' "$pf" || { echo "placeholder survived"; exit 1; }
      [ "$(stat -c %a "$pf")" = "600" ] || { echo "mode not 0600: $(stat -c %a "$pf")"; exit 1; }
      touch $out
    '';

  # MCP 行必须真的进组合树:patch 形状(带 id 的顶层行)对树上不存在的
  # id 只 warn+skip(实测 cordis-plugin-include,7 行全丢 → /mcp 空屏),
  # 此 check 用 dump-config 端到端验证 insert 通道生效
  dsh-mcp-in-tree =
    let
      mcpRows = (dshLib.applyPlugins {
        inherit pkgs;
        cfg = {
          profiles = { default = { }; };
          plugins = { };
          inBoxPlugins = { };
          mcpServers.probe = {
            transport = "stdio";
            command = "true";
            args = [ ];
            env = { };
            cwd = null;
            url = null;
            headers = { };
            toolCallTimeoutMs = null;
            failOnStartupError = false;
            settings = { };
          };
        };
      }).mcpPatches;
      bundle = dshLib.buildProfile {
        inherit pkgs;
        profile = dshLib.mkProfile {
          name = "mcp-tree";
          plugins = [ "@deepseek-ai/dsh-base" ];
          userPatchesFile = null;
          userPatches = mcpRows;
        };
      };
    in
    pkgs.runCommand "dsh-mcp-in-tree-check" { } ''
      ${materialize "mcp-tree" bundle}
      ${pkgs.dsh}/bin/dsh --profile mcp-tree --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      grep -q 'mcp-probe' "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "mcp entry missing from composed tree" >&2; exit 1;
      }
      ! grep -q 'entry "mcp-probe" not found' "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "mcp row was warn-skipped (patch shape, not insert)" >&2; exit 1;
      }
      touch $out
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
