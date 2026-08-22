# 能力缝域(构建期):三家后端 + 双缝组合的真 boot 进树端到端、
# roster/permission boot 级验证。
# 纯求值断言(行组金样/负例/secret 表)在 tests/seam.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith inTreeCheck;
in
{
  # exa 后端端到端:选中 exa 的 profile bundle 真 boot,web-search-exa 条目
  # 须进组合树(insert 生效而非 warn-skip)且全 log 零 "not found" 警告
  # (幽灵禁行回归)。registry 真包构建(peers 链接齐)→ 全链验证
  dsh-exa-in-tree = inTreeCheck {
    checkName = "dsh-exa-in-tree-check";
    profileName = "exa-tree";
    entryId = "web-search-exa";
    cfg = {
      webSearch = "exa";
      webSearchProviders.exa.row = {
        name = "@tonydua/dsh-web-search-exa";
        config.apiKeyEnv = "EXA_API_KEY";
      };
    };
    extraGreps = [
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # zhipu 后端端到端(同 exa 同构):选中 zhipu 的 profile 真 boot,
  # web-search-zhipu 条目进树 + web 行 searchProvider 重述生效
  dsh-zhipu-in-tree = inTreeCheck {
    checkName = "dsh-zhipu-in-tree-check";
    profileName = "zhipu-tree";
    entryId = "web-search-zhipu";
    cfg = {
      webSearch = "zhipu";
      webSearchProviders.zhipu.row = {
        name = "@fww/dsh-web-search-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'zhipu' "$TMPDIR/dump.log" && grep -q 'searchProvider' "$TMPDIR/dump.log"''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # fetch 真 boot:web-fetch-zhipu 进树 + fetchProvider 重述 + fetch: true
  dsh-fetch-in-tree = inTreeCheck {
    checkName = "dsh-fetch-in-tree-check";
    profileName = "fetch-tree";
    entryId = "web-fetch-zhipu";
    cfg = {
      webFetch = "zhipu";
      webFetchProviders.zhipu.row = {
        name = "@fww/dsh-web-fetch-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'fetchProvider: zhipu' "$TMPDIR/dump.log"''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # 双缝组合真 boot(A1 端到端):exa 搜索 + zhipu 抓取同设 → dump 里
  # 两个 provider 都在 web 行上,tool-web fetch: true 且 searchTimeoutMs
  # 保留(A2),零幽灵警告
  dsh-both-seams-in-tree = inTreeCheck {
    checkName = "dsh-both-seams-in-tree-check";
    profileName = "both-tree";
    entryId = "web-search-exa";
    cfg = {
      webSearch = "exa";
      webSearchProviders.exa.row = {
        name = "@tonydua/dsh-web-search-exa";
        config.apiKeyEnv = "EXA_API_KEY";
      };
      webFetch = "zhipu";
      webFetchProviders.zhipu.row = {
        name = "@fww/dsh-web-fetch-zhipu";
        config.apiKeyEnv = "ZHIPU_API_KEY";
      };
    };
    extraGreps = [
      ''grep -q 'searchProvider: exa' "$TMPDIR/dump.log" && grep -q 'fetchProvider: zhipu' "$TMPDIR/dump.log"''
      ''grep -A4 'id: tool-web' "$TMPDIR/dump.log" | grep -q 'searchTimeoutMs: 60000' ''
      ''! grep -q 'not found' "$TMPDIR/dump.log"''
    ];
  };

  # roster 接管 boot 级端到端:真 web 树(base+web-app)+ 舞行 →
  # dump-config:agent-presets 禁 / agent-presets-nix 进树带 farm roots;
  # farm 内容:shipped standard 已重放(webFetch 选中 → fetch: true +
  # searchTimeoutMs 60000 进 shipped —— 手选逃逸关闭 + 超时键保留的
  # 铁证),minimal 原样(no-op 重放);全 log 零 "not found"(A7)
  dsh-roster-boot =
    let
      cfg' = {
        webFetch = "zhipu";
        webFetchProviders.zhipu.row = {
          name = "@fww/dsh-web-fetch-zhipu";
          config.apiKeyEnv = "ZHIPU_API_KEY";
        };
        presets.custom-standard.source = dshLib.shippedPreset pkgs "standard";
        defaultPreset = "custom-standard";
        plugins."web-app" = {
          enable = true;
          face = null;
          source = "@deepseek-ai/dsh-web-app";
          profiles = [ ];
          settings = { };
          patches = [ ];
          patchId = null;
        };
      };
      applied' = applyWith cfg';
      inc = applied'.perProfile.web;
      bundle = dshLib.buildProfile {
        inherit pkgs;
        profile = dshLib.mkProfile {
          name = "web";
          plugins = [
            "@deepseek-ai/dsh-base"
            "@deepseek-ai/dsh-web-app"
          ]
          ++ inc.extraPlugins;
          userPatchesFile = null;
          userPatches = inc.extraPatches;
        };
      };
      farm = applied'.presetFarm;
    in
    pkgs.runCommand "dsh-roster-boot-check" { } ''
      ${fx.materialize "web" bundle}
      ${pkgs.dsh}/bin/dsh --profile web --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      grep -q 'id: agent-presets-nix' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; echo "roster row missing" >&2; exit 1; }
      # dump 按字母序渲染键:config(含 roots)在 id 行之前
      grep -B8 'id: agent-presets-nix' "$TMPDIR/dump.log" | grep -q "${farm}" || { cat "$TMPDIR/dump.log" >&2; echo "farm roots missing" >&2; exit 1; }
      ! grep -q 'entry "agent-presets-nix" not found' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      ! grep -q 'not found' "$TMPDIR/dump.log" || { cat "$TMPDIR/dump.log" >&2; echo "ghost disable rows leaked warnings" >&2; exit 1; }
      # farm 实然:shipped standard 的 fetch 已重放为 true 且超时键保留;
      # minimal 无 tool-web 行 → no-op(yq 不炸,原样)
      grep -q 'fetch: true' "${farm}/standard/agent.cordis.yml" || { echo "farm standard not replayed" >&2; exit 1; }
      grep -q 'searchTimeoutMs: 60000' "${farm}/standard/agent.cordis.yml" || { echo "farm standard lost searchTimeoutMs" >&2; exit 1; }
      test -f "${farm}/minimal/agent.cordis.yml" || { echo "farm minimal missing" >&2; exit 1; }
      touch $out
    '';

  # permission boot 级端到端:三模式遍历(read-only 表接管进 permission
  # 行 config;workspace-write/danger-full-access 恒带整表 —— A4 回归:
  # 运行期切 read-only 显示 custom 而非 named preset)→ dump-config
  # 不炸构造期 resolve,dump 里 presets 表三键在场
  dsh-permission-boot =
    let
      mkBoot =
        mode:
        let
          applied' = applyWith {
            permissionMode = mode;
            plugins."web-app" = {
              enable = true;
              face = null;
              source = "@deepseek-ai/dsh-web-app";
              profiles = [ ];
              settings = { };
              patches = [ ];
              patchId = null;
            };
          };
          inc = applied'.perProfile.web;
          bundle = dshLib.buildProfile {
            inherit pkgs;
            profile = dshLib.mkProfile {
              name = "web";
              plugins = [
                "@deepseek-ai/dsh-base"
                "@deepseek-ai/dsh-web-app"
              ]
              ++ inc.extraPlugins;
              userPatchesFile = null;
              userPatches = inc.extraPatches;
            };
          };
        in
        ''
          ${fx.materialize "web" bundle}
          ${pkgs.dsh}/bin/dsh --profile web --dump-config > "$TMPDIR/dump-${mode}.log" 2>&1 \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; exit 1; }
          ! grep -q 'unknown preset' "$TMPDIR/dump-${mode}.log" \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; echo "permission table takeover failed (${mode})" >&2; exit 1; }
          # 整表接管:read-only 在场(A4:此前非 read-only 分支丢表 →
          # 运行期切 read-only 显示 custom)
          grep -q 'read-only' "$TMPDIR/dump-${mode}.log" \
            || { cat "$TMPDIR/dump-${mode}.log" >&2; echo "read-only preset missing from dump (${mode})" >&2; exit 1; }
        '';
    in
    pkgs.runCommand "dsh-permission-boot-check" { } ''
      ${mkBoot "read-only"}
      ${mkBoot "workspace-write"}
      ${mkBoot "danger-full-access"}
      touch $out
    '';
}
