# profile 模型域:bundle 工件形状/正例 boot/缺 base 负例/face 四态/
# inBoxPlugins 三态行
{ pkgs, dshLib, fx }:

let
  inherit (fx) applyWith mkFakeCfg;
  # wrapper 渲染的 applied 单算助手(求值单次原则;fake cfg 各键
  # or-守卫,applyPlugins 无 MCP 声明时零副作用)
  wrapperApplied = cfg: dshLib.applyPlugins { inherit cfg pkgs; };
in
{
  dsh-profile-structure = pkgs.runCommand "dsh-profile-structure-check"
    { nativeBuildInputs = [ pkgs.jq ]; } ''
      bundle=${fx.goodProfile}
      expected='["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app"]'
      actual=$(jq -c '.dsh.profile.bundles' "$bundle/package.json")
      test "$actual" = "$expected" || {
        echo "bundles mismatch: $actual != $expected" >&2; exit 1;
      }
      test -f "$bundle/cordis.yml" || { echo "missing cordis.yml" >&2; exit 1; }
      test -f "$bundle/cordis.patch.yml" || { echo "missing cordis.patch.yml" >&2; exit 1; }
      touch "$out"
    '';

  # 实测依据(rc.5):--dump-config 对坏组合只打印 "entry not found" 但 exit 0,
  # 真正的 fail-loud(assertEntriesActivated: pending waiting for service)只在
  # 实际 boot 时触发 → 负例用无参 boot 断言非零退出
  dsh-profile-headless = pkgs.runCommand "dsh-profile-headless-check" { } ''
      ${fx.materialize "headless" fx.headlessProfile}
      ${pkgs.dsh}/bin/dsh --profile headless --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      # dsh-base 的条目必须在组合树里(证明层序叠加生效,而非空树碰巧 exit 0)
      grep -q "cordis-plugin-timer" "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "base layer entries missing from composed tree" >&2; exit 1;
      }
      touch "$out"
    '';

  dsh-profile-nobase = pkgs.runCommand "dsh-profile-nobase-check" { } ''
      ${fx.materialize "web-nobase" fx.nobaseProfile}
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

  # face 四态语义:true=键名派生(module system 键唯一)/false=压制推导/
  # null=in-box 表推导;face 插件不参与分发,功能插件分发到含自动 face
  dsh-face-gen =
    let
      r = applyWith {
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
      };
      assert' = cond: msg: pkgs.lib.assertMsg cond msg;
      # dsh <profile> 子命令分发:主 wrapper 脚本内容(build 期 grep);
      # web 排除(上游原生 web 子命令已等价 boot profiles.web)。
      # applied 显式单算一次传给 renderWrapper(求值单次原则,与
      # hm-module/mkDsh 同构)
      dispatchWrapper = dshLib.renderWrapper {
        cfg = mkFakeCfg { };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { });
        subcommands = [ "tui" "web" ];
      };
      plainWrapper = dshLib.renderWrapper {
        cfg = mkFakeCfg { };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { });
      };
      # bash 补全:分发名单 + 上游命令都在 $1 词表,--profile 值含 web
      completionText = dshLib.renderCompletion {
        subcommands = [ "tui" "headless" ];
        profiles = [ "web" "tui" "headless" ];
        upstream = [ "web" "plugin" ];
      };
      # 保留名负例:profile/face 名撞上游子命令(plugin 语义 ≠ profile
      # boot)→ renderWrapper 求值期 throw。tryEval 须强制求值到脚本
      # 内容(writeShellScriptBin derivation)
      badCmd = builtins.tryEval
        (builtins.deepSeq
          (dshLib.renderWrapper {
            cfg = mkFakeCfg { };
            inherit pkgs;
            applied = wrapperApplied (mkFakeCfg { });
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

  # wrapper stderr 过滤行为级:dsh-tui 的 upstream drift 警告(无开关的
  # console.warn,当前 rc.5/rc.6 错位 → 每次 23 行)被滤掉,其余 stderr
  # 原样透传(逃生口 = 绕过 wrapper 直跑 dsh)
  dsh-wrapper-drift-filter =
    let
      fakeDsh = pkgs.writeShellScriptBin "dsh" ''
        echo "[dsh-tui] upstream drift: @deepseek-ai/dsh-agent installed=0.1.0-rc.5 validated=0.1.0-rc.6 — noise" >&2
        echo "real stderr line" >&2
        echo "stdout ok"
      '';
      wrapper = dshLib.renderWrapper {
        cfg = mkFakeCfg { package = fakeDsh; };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { package = fakeDsh; });
      };
    in
    pkgs.runCommand "dsh-wrapper-drift-filter-check" { } ''
      ${wrapper}/bin/dsh > "$TMPDIR/out.log" 2> "$TMPDIR/err.log" || true
      grep -q "stdout ok" "$TMPDIR/out.log" || { echo "stdout lost" >&2; exit 1; }
      grep -q "real stderr line" "$TMPDIR/err.log" \
        || { echo "non-drift stderr must pass through" >&2; exit 1; }
      ! grep -q "upstream drift" "$TMPDIR/err.log" \
        || { echo "drift warnings must be filtered" >&2; exit 1; }
      touch $out
    '';

  # inBoxPlugins 双向渲染:disable/enable/config 三态行落进 bundle patch
  dsh-inbox-rows =
    let
      rows = (applyWith {
        inBoxPlugins = {
          "llm-deepseek".enable = false;
          hmr.enable = true;
          "web-search-deepseek".enable = null; # 不表态 → 无行
          timer.config.timeoutMs = 30000;
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

  # patch 行 YAML 渲染层(lib/patch.nix):块式 emitter 的标量域
  # (bool 显式 —— Nix toString true = "1" 的 shell 强转不可漏)、
  # 嵌套/内联空集合、怪键引号、rawYaml 标签原样落盘(!!js 与上游
  # patch 文件同构;yq 走选择路径会把自定义标签归一掉 → raw 断言
  # 用文本 grep,yq 只测普通值)
  dsh-patch-yaml =
    let
      yml = dshLib.patchesToYaml [
        { id = "sandbox-policy"; config = { mode = "workspace-write"; workspaceRoot = dshLib.rawYaml "!!js process.cwd()"; }; }
        { id = "tool-web"; config = { fetch = true; disabled-flag = false; searchTimeoutMs = 60000; }; }
        { id = "empty-collections"; config = { list = [ ]; attrs = { }; nested.deep = [ 1 "two" ]; }; }
        { id = "quoted"; config."odd key: v" = "has: colon and more"; }
        { id = "plain-disable"; disabled = true; }
      ];
      file = pkgs.writeText "patch-yaml.yml" yml;
      probe = expr: pkgs.runCommand "patch-yaml-probe" { } ''
        ${pkgs.yq-go}/bin/yq '${expr}' ${file} > $out
      '';
      readProbe = expr:
        pkgs.lib.removeSuffix "\n" (builtins.readFile (probe expr));
    in
    pkgs.runCommand "dsh-patch-yaml-check" { } (builtins.deepSeq ([
      (pkgs.lib.assertMsg (readProbe ''.[1].config.fetch'' == "true")
        "patch-yaml: booleans must render as YAML true (Nix toString would emit 1)")
      (pkgs.lib.assertMsg (readProbe ''.[1].config."disabled-flag"'' == "false")
        "patch-yaml: false must render as false (Nix toString would emit the empty string)")
      (pkgs.lib.assertMsg (readProbe ''.[1].config.searchTimeoutMs'' == "60000")
        "patch-yaml: integers must render unquoted")
      (pkgs.lib.assertMsg (readProbe ''.[2].config.list'' == "[]")
        "patch-yaml: empty lists must inline as []")
      (pkgs.lib.assertMsg (readProbe ''.[2].config.attrs'' == "{}")
        "patch-yaml: empty attrs must inline as {}")
      (pkgs.lib.assertMsg (readProbe ''.[2].config.nested.deep[1]'' == "two")
        "patch-yaml: nested block sequences must round-trip")
      (pkgs.lib.assertMsg (readProbe ''.[3].config["odd key: v"]'' == "has: colon and more")
        "patch-yaml: keys/values with YAML special characters must be quoted and survive")
      (pkgs.lib.assertMsg (builtins.match ".*(workspaceRoot: !!js process\.cwd\(\)).*" yml != null)
        "patch-yaml: rawYaml values must land verbatim in the file (the !!js tag rides the same YAML schema the upstream patch files use)")
      (pkgs.lib.assertMsg (readProbe ''.[4].disabled'' == "true")
        "patch-yaml: top-level disable rows must survive")
    ]) ''
      # yq 整文件解析不炸(健康性:emitter 产物是合法 YAML)
      ${pkgs.yq-go}/bin/yq 'length' ${file} > "$TMPDIR/len.txt"
      test "$(cat "$TMPDIR/len.txt")" = "5" || { echo "document must parse to 5 rows"; exit 1; }
      touch $out
    '');
}
