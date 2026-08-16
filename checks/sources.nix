# 源校验与 settings 域:providers 合并语义、presets/skills 源校验 +
# 依赖冲突负例
{ pkgs, lib, dshLib, fx }:

let
  inherit (fx) applyWith;
in
{
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

  # agent 预设:eval 期校验(缺 agent.cordis.yml → throw;正例 =
  # fixtures/preset-ok 目录);物化脚本在 hm-module activation
  # (与 profile 同 stamp 模式,不重复验证)
  dsh-presets =
    let
      bad = builtins.tryEval
        (builtins.deepSeq
          (dshLib.validatePresets { "no-composition".source = ./sources.nix; })
          null);
      good = dshLib.validatePresets {
        ok.source = ../fixtures/preset-ok;
      };
    in
    pkgs.runCommand "dsh-presets-check" { }
      (builtins.seq (pkgs.lib.assertMsg (!bad.success)
        "dsh-presets: source without agent.cordis.yml must be rejected at eval time")
        (builtins.seq (pkgs.lib.assertMsg (good ? ok)
          "dsh-presets: valid preset directory must pass")
          "touch $out"));

  # preset 物化管线:能力行重放(yq 按 id 改写 config 键,行不在 preset
  # 里无操作)、tui marker 剥离、其余文件原样、行组变更 → 产物路径变
  # (删除自动清理的 derivation 语义)
  dsh-preset-replay =
    let
      # 夹具:仿 preset 目录(agent.cordis.yml 含 tool-web fetch:false)+
      # tui 所有权 marker
      srcBase = pkgs.runCommand "preset-replay-src" { }
        ''
          mkdir -p $out
          cat > $out/agent.cordis.yml <<'EOF'
          - id: tool-bash
          - id: tool-web
            name: '@deepseek-ai/dsh-tool-web'
            config:
              fetch: false
              searchTimeoutMs: 60000
          EOF
          cat > $out/.dsh-tui-managed.json <<'EOF'
          {"owner":"@deepseek-harness-tui/dsh-tui","preset":"x","revision":"v3"}
          EOF
        '';
      replayed = dshLib.buildPreset {
        inherit pkgs;
        source = srcBase;
        rows = [
          { id = "tool-web"; config = { fetch = true; }; }
          { id = "nonexistent"; config = { x = 1; }; } # 行不在 preset → 无操作
        ];
      };
      plain = dshLib.buildPreset {
        inherit pkgs;
        source = srcBase;
        rows = [ ];
      };
      fetchVal = builtins.readFile (pkgs.runCommand "preset-fetch-probe" { } ''
        ${pkgs.yq-go}/bin/yq '.[] | select(.id == "tool-web") | .config.fetch' ${replayed}/agent.cordis.yml > $out
      '');
      # 行组不同 → 产物路径必不同(store 内容寻址);空行组 = 纯拷贝变体
      pathsDiffer = toString replayed != toString plain;
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-preset-replay-check" { } (builtins.deepSeq ([
      (assert' (lib.removeSuffix "\n" fetchVal == "true")
        "preset-replay: capability row must rewrite tool-web config.fetch to true")
      (assert' (!builtins.pathExists "${replayed}/.dsh-tui-managed.json")
        "preset-replay: tui ownership marker must be stripped (ensurePackagedPresets would otherwise staged-replace the materialized copy)")
      (assert' (builtins.pathExists "${replayed}/agent.cordis.yml")
        "preset-replay: other preset files must survive verbatim")
      (assert' pathsDiffer
        "preset-replay: differing rows must yield differing store paths (stamp re-materialization / deletion cleanup depends on it)")
    ]) "touch $out");

  # skills 源校验:平铺 .md / 目录束(SKILL.md)双形态 + 双负例 +
  # 依赖冲突负例(声明 skills 而 disable 发现插件 → eval throw)
  dsh-skills =
    let
      ok = dshLib.validateSkills {
        flat.source = ../fixtures/skill-flat.md;
        bundle.source = ../fixtures/skill-bundle;
      };
      badDir = builtins.tryEval (builtins.deepSeq
        (dshLib.validateSkills { x.source = ../fixtures; }) null);
      badExt = builtins.tryEval (builtins.deepSeq
        (dshLib.validateSkills { x.source = ./sources.nix; }) null);
      skillClash = builtins.tryEval (builtins.deepSeq
        (applyWith {
          skills.flat.source = ../fixtures/skill-flat.md;
          inBoxPlugins."skill-filesystem".enable = false;
        }).facePlugins null);
      presetClash = builtins.tryEval (builtins.deepSeq
        (applyWith {
          presets.mine.source = ../fixtures/preset-ok;
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

  # preset 自动发现:经 applyPlugins(与生产同构,零 source 插件走
  # sourceOf 解析)+ path 源直扫 + 显式声明胜 + shipped 助手 fail-loud
  dsh-preset-discover =
    let
      # path 源夹具:真 Nix path(flake=false input 形态),含
      # presets/<id>/agent.cordis.yml 目录束 + 一个无组合文件的干扰目录
      pathSrc = ../fixtures/preset-path-src;
      # derivation 源夹具:passthru.dshPresets(仿 update.py 物化)
      derivSrc = pkgs.runCommand "preset-deriv-src"
        {
          passthru.dshPresets = [ "shipped-one" ];
        } ''
        mkdir -p $out/presets/shipped-one
        echo "- id: tool-web" > $out/presets/shipped-one/agent.cordis.yml
      '';
      noPresetSrc = pkgs.hello;
      # 生产路径:applyPlugins(sourceOf 解析链)
      applyDiscover = plugins: (applyWith { inherit plugins; }).discoveredPresets;
      found = applyDiscover {
        a = { enable = true; source = pathSrc; };
        b = { enable = false; source = derivSrc; };  # disabled → 不发现
        c = { enable = true; source = noPresetSrc; }; # 无 preset → 空贡献
      };
      # passthru 源单独验(上面 b disabled)
      foundDeriv = applyDiscover { b = { enable = true; source = derivSrc; }; };
      # 黑名单:排除 second-one → 只发现 handmade;typo → eval throw
      foundExcl = applyDiscover {
        d = { enable = true; source = pathSrc; excludedPresets = [ "second-one" ]; };
      };
      typoExcl = builtins.tryEval (builtins.deepSeq
        (applyDiscover {
          e = { enable = true; source = pathSrc; excludedPresets = [ "no-such-preset" ]; };
        }).handmade null);
      # 显式声明胜:同名发现源被显式 presets 覆盖(hm-module 合流序)
      merged = found // { handmade = "/explicit/wins"; };
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-preset-discover-check" { } (builtins.deepSeq ([
      (assert' (found ? handmade && found ? second-one)
        "preset-discover: path source with presets/<id>/agent.cordis.yml must be discovered (composition-less dirs skipped)")
      (assert' (!found ? shipped-one)
        "preset-discover: disabled plugin's presets must not be discovered")
      (assert' (foundDeriv ? shipped-one)
        "preset-discover: derivation source passthru.dshPresets must be discovered")
      (assert' (foundExcl ? handmade && !foundExcl ? second-one)
        "preset-discover: excludedPresets must suppress takeover of the listed preset only")
      (assert' (!typoExcl.success)
        "preset-discover: excludedPresets with an id the plugin does not ship must throw at eval time")
      (assert' (merged.handmade == "/explicit/wins")
        "preset-discover: explicit preset declaration must win over discovered")
      (assert' (lib.match ".*/config/agent-presets/standard" (dshLib.shippedPreset pkgs "standard") != null)
        "preset-discover: shippedPreset helper must resolve the standard preset path")
      (assert' (!(builtins.tryEval (builtins.deepSeq (dshLib.shippedPreset pkgs "no-such-preset") null)).success)
        "preset-discover: shippedPreset must throw on unknown preset (upstream layout drift fail-loud)")
    ]) "touch $out");

  # preset 重放 drift 拦截:真实 shipped standard + 真实能力行组过
  # buildPreset,断言 tool-web fetch 保险丝真的写进去了。上游 preset
  # 行改名/挪键/删行 → 重放静默变 no-op → 此 check 炸(fail-loud),
  # 而非运行时静默失效
  dsh-preset-replay-drift =
    let
      # 与生产同构的能力行组:选中 fetch 后端 → wfRows 含 fetch:true 行
      applied = applyWith {
        webFetch = "probe";
        webFetchProviders.probe.row.name = "@example/dsh-web-fetch-probe";
      };
      replayed = dshLib.buildPreset {
        inherit pkgs;
        source = dshLib.shippedPreset pkgs "standard";
        rows = applied.wfRows;
      };
      fetchVal = builtins.readFile (pkgs.runCommand "preset-drift-probe" { } ''
        ${pkgs.yq-go}/bin/yq '.[] | select(.id == "tool-web") | .config.fetch' ${replayed}/agent.cordis.yml > $out
      '');
    in
    pkgs.runCommand "dsh-preset-replay-drift-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg (lib.removeSuffix "\n" fetchVal == "true")
        "preset-replay-drift: shipped standard no longer takes the tool-web fetch rewrite (upstream row shape changed — update the replay row ids in lib/apply.nix)")
    ]) "touch $out");
}
