# profile 域(构建期):bundle 工件形状、正例 boot、缺 base 负例 boot、
# wrapper 行为(stderr 过滤/dispatch 块渲染)。
# 纯求值断言(face 四态/inbox 行/patch YAML/补全)在 tests/profile.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith mkFakeCfg;
  # wrapper 渲染的 applied 单算助手(求值单次原则;fake cfg 各键
  # or-守卫,applyPlugins 无 MCP 声明时零副作用)
  wrapperApplied = cfg: dshLib.applyPlugins { inherit cfg pkgs; };
in
{
  dsh-profile-structure =
    pkgs.runCommand "dsh-profile-structure-check" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
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

  # wrapper dispatch 块渲染(build 期 grep):分发子命令进 wrapper 脚本、
  # tui 在/web 排除(上游原生 web 子命令已等价 boot profiles.web)、
  # 空 faces 无块。词表渲染在 tests/profile.nix(金样)
  dsh-wrapper-dispatch =
    let
      dispatchWrapper = dshLib.renderWrapper {
        cfg = mkFakeCfg { };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { });
        subcommands = [
          "tui"
          "web"
        ];
      };
      plainWrapper = dshLib.renderWrapper {
        cfg = mkFakeCfg { };
        inherit pkgs;
        applied = wrapperApplied (mkFakeCfg { });
      };
    in
    pkgs.runCommand "dsh-wrapper-dispatch-check" { } ''
      grep -q 'tui)' ${dispatchWrapper}/bin/dsh
      grep -qF -- '--profile "$_dsh_face"' ${dispatchWrapper}/bin/dsh
      ! grep -qF 'tui|web' ${dispatchWrapper}/bin/dsh
      ! grep -q '_dsh_face' ${plainWrapper}/bin/dsh
      touch $out
    '';

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
        applied = wrapperApplied (mkFakeCfg {
          package = fakeDsh;
        });
      };
    in
    pkgs.runCommand "dsh-wrapper-drift-filter-check" { } ''
      ${wrapper}/bin/dsh > "$TMPDIR/out.log" 2> "$TMPDIR/err.log" || true
      grep -q "stdout ok" "$TMPDIR/out.log" || { echo "stdout lost" >&2; exit 1; }
      grep -q "real stderr line" "$TMPDIR/err.log" \
        || { echo "non-drift stderr must pass through" >&2; exit 1; }
      ! grep -q "upstream drift" "$TMPDIR/err.log" \
        || { echo "drift warnings must be filtered" >&2; exit 1; }
      touch "$out"
    '';

  # secret export 行为级:真模块 eval(mkDsh 全链)→ wrapper 文本恰好
  # 两个 export(EXA 行派生 + ZHIPU providers 显式;跨声明同 env 同文件
  # 去重)。表/收集器/去重的纯求值面在 tests/seam.nix
  dsh-wrapper-exports =
    let
      inst = dshLib.mkDsh {
        inherit pkgs;
        modules = [
          {
            programs.dsh.webFetch = "zhipu";
            programs.dsh.webFetchProviders.zhipu.row = {
              name = "@fww/dsh-web-fetch-zhipu";
              secretFile = "/run/secrets/zhipu_api_key";
            };
            programs.dsh.webSearch = "exa";
            programs.dsh.webSearchProviders.exa.row = {
              name = "@tonydua/dsh-web-search-exa";
              secretFile = "/run/secrets/exa_api_key";
            };
            programs.dsh.providers."zhipu-coding-plan" = {
              apiKeyEnv = "ZHIPU_API_KEY";
              secretFile = "/run/secrets/zhipu_api_key";
            };
          }
        ];
      };
    in
    pkgs.runCommand "dsh-wrapper-exports-check" { } ''
      n=$(grep -cE '^[[:space:]]*export (EXA_API_KEY|ZHIPU_API_KEY)=' ${inst.wrapper}/bin/dsh)
      test "$n" -eq 2 || {
        echo "wrapper must export exactly 2 env vars (EXA + ZHIPU), got $n" >&2
        exit 1
      }
      touch $out
    '';
}
