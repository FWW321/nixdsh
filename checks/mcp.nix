# MCP 域:行渲染(insert 包裹/判别联合/secret 占位符)、secret 注入
# 行为级(真跑 wrapper 启动块)、insert 通道端到端(真 boot 进树)
{ pkgs, dshLib, fx }:

let
  inherit (fx) applyWith mkFakeCfg;
in
{
  # MCP 服务器行渲染:判别联合(stdio/streamable-http)、null 省略、
  # settings 逃生口并入、serverName = attr 名
  dsh-mcp-render =
    let
      rows = (applyWith {
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
      }).mcpPatches;
      byId = builtins.listToAttrs (map
        (r: { name = r.id; value = r; })
        (pkgs.lib.flatten (map (r: r.insert or [ ]) rows)));
      fs = byId."mcp-filesystem".config;
      rm = byId."mcp-remote".config;
      gh = byId."mcp-gh".config;
      # opt-out:mcpStderrToLog = false → 原始 command/args 原样
      fsRaw = (builtins.listToAttrs (map
        (r: { name = r.id; value = r; })
        (pkgs.lib.flatten (map (r: r.insert or [ ]) (applyWith {
          mcpStderrToLog = false;
          mcpServers.filesystem = {
            transport = "stdio";
            command = "/run/current-system/sw/bin/npx";
            args = [ "-y" "@modelcontextprotocol/server-filesystem" "/home" ];
            env = { };
            cwd = null;
            url = null;
            headers = { };
            toolCallTimeoutMs = null;
            failOnStartupError = false;
            settings = { };
          };
        }).mcpPatches))))."mcp-filesystem".config;
      allInsertShaped = builtins.all (r: r ? insert && builtins.length r.insert == 1) rows;
      refs = (applyWith {
        mcpServers = { gh.env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh"; };
      }).mcpSecretRefs;
      # 同一 server 多 secret 的 refs 结构化收集(A5 回归:文本回扫时代
      # 贪婪正则每行只收一个)
      multiRefs = (applyWith {
        mcpServers.gh = {
          transport = "stdio";
          command = "gh";
          env = {
            GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh";
            OTHER_TOKEN.secretFile = "/run/secrets/fake-other";
          };
          args = [ ]; cwd = null; url = null; headers = { };
          toolCallTimeoutMs = null; failOnStartupError = false; settings = { };
        };
      }).mcpSecretRefs;
      # 名校验负例(B12:上游 SERVER_NAME_PATTERN 前移到 eval 期)
      badName = builtins.tryEval (builtins.deepSeq
        (applyWith {
          mcpServers."bad name!".command = "x";
        }).mcpPatches null);
      assert' = c: m: pkgs.lib.assertMsg c m;
    in
    pkgs.runCommand "dsh-mcp-render-check" { } (builtins.seq ([
      (assert' allInsertShaped "dsh-mcp-render: rows must be insert-wrapped (patch rows for unknown ids are warn-skipped by the loader)")
      (assert' (byId ? "mcp-filesystem" && byId ? "mcp-remote" && byId ? "mcp-gh") "dsh-mcp-render: one entry per server must render")
      (assert' (fs.serverName == "filesystem" && fs.command != null) "dsh-mcp-render: stdio server must carry serverName+command")
      (assert' (!fs ? cwd && !fs ? toolCallTimeoutMs) "dsh-mcp-render: null fields must be omitted")
      (assert' (fs.reconnect.maxAttempts == 5) "dsh-mcp-render: settings escape hatch must merge into config")
      # stderr 收纳默认开:command 包成 sh -c,script 落 <name>.log,
      # 原命令+参数原样跟随($@ 形状)
      (assert' (fs.command == "sh" && pkgs.lib.elemAt fs.args 0 == "-c"
        && pkgs.lib.elemAt fs.args 1 == "sh"
        && pkgs.lib.hasInfix "filesystem.log" (pkgs.lib.elemAt fs.args 2)
        && pkgs.lib.drop 3 fs.args == [ "/run/current-system/sw/bin/npx" "-y" "@modelcontextprotocol/server-filesystem" "/home" ])
        "dsh-mcp-render: stdio must be sh-wrapped with per-server stderr log by default")
      (assert' (fsRaw.command == "/run/current-system/sw/bin/npx" && fsRaw.args == [ "-y" "@modelcontextprotocol/server-filesystem" "/home" ])
        "dsh-mcp-render: mcpStderrToLog=false must restore the raw command shape")
      (assert' (rm ? url && rm ? headers && rm.toolCallTimeoutMs == 30000) "dsh-mcp-render: streamable-http must carry url/headers")
      (assert' (!rm ? command && !rm ? args) "dsh-mcp-render: http server must not carry stdio fields")
      (assert' (rm.headers.Authorization == "Bearer @dsh-secret:/run/secrets/fake-token@") "dsh-mcp-render: secretFile header must render prefix+placeholder")
      (assert' (rm.headers.X-Plain == "literal") "dsh-mcp-render: literal header must stay literal")
      (assert' (gh.env.GITHUB_PERSONAL_ACCESS_TOKEN == "@dsh-secret:/run/secrets/fake-gh@") "dsh-mcp-render: secretFile env must render bare placeholder")
      (assert' (builtins.length refs == 1 && builtins.head refs == "/run/secrets/fake-gh") "dsh-mcp-render: mcpSecretRefs must dedupe and collect")
      (assert' (builtins.length multiRefs == 2)
        "dsh-mcp-render: two secretFiles on one server must BOTH land in the structured refs list")
      (assert' (!badName.success)
        "dsh-mcp-render: server names violating ^[A-Za-z0-9_-]{1,32}$ must throw at eval time (upstream SERVER_NAME_PATTERN hoisted)")
    ]) "touch $out");

  # secret 注入行为级验证:真跑 wrapper 启动块,对物化 patch 注入真值,
  # 验证 0600/占位符清零(build 沙箱 /tmp 可写,fixed home 固定路径)。
  # 同一 server 两个 secret(A5 回归:文本回扫时代第二个占位符漏注,
  # 字面 @dsh-secret:… 进 MCP config)
  dsh-mcp-secret-inject =
    let
      home = "/tmp/dsh-inject-check-home";
      secretFile = "/tmp/dsh-inject-check-secret";
      secretFile2 = "/tmp/dsh-inject-check-secret2";
      fakeCfg = mkFakeCfg {
        dshHome = home;
        defaultProfile = "default";
        mcpServers = {
          gh = {
            transport = "stdio";
            command = "true";
            env = {
              GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = secretFile;
              SECOND_TOKEN.secretFile = secretFile2;
            };
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
      wrapper = dshLib.renderWrapper {
        cfg = fakeCfg;
        inherit pkgs;
        applied = dshLib.applyPlugins { cfg = fakeCfg; inherit pkgs; };
      };
      # 模拟 activation 产物:bundle patch 含两个占位符
      placeholderPatch = pkgs.writeText "cordis.patch.yml" ''
        - id: mcp-gh
          name: '@deepseek-ai/dsh-mcp-client'
          config:
            env:
              GITHUB_PERSONAL_ACCESS_TOKEN: '@dsh-secret:${secretFile}@'
              SECOND_TOKEN: '@dsh-secret:${secretFile2}@'
      '';
    in
    pkgs.runCommand "dsh-mcp-secret-inject-check" { } ''
      install -D -m 0644 ${placeholderPatch} ${home}/profiles/default/cordis.patch.yml
      printf 'REALTOKEN123\n' > ${secretFile}
      printf 'REALSECOND456\n' > ${secretFile2}
      ${wrapper}/bin/dsh >/dev/null 2>&1 || true
      pf=${home}/profiles/default/cordis.patch.yml
      grep -q REALTOKEN123 "$pf" || { echo "first secret not injected"; cat "$pf"; exit 1; }
      grep -q REALSECOND456 "$pf" || { echo "second secret not injected (A5: placeholder scan must be structural)"; cat "$pf"; exit 1; }
      ! grep -q '@dsh-secret:' "$pf" || { echo "placeholder survived"; exit 1; }
      [ "$(stat -c %a "$pf")" = "600" ] || { echo "mode not 0600: $(stat -c %a "$pf")"; exit 1; }
      touch $out
    '';

  # stderr 收纳行为级:按渲染产物原样启动(stdio 行默认 sh -c 包装),
  # 验证 stdout 正常/stderr 不漏终端/日志落 $XDG_STATE_HOME(参数含
  # 空格的传递也一并覆盖)
  dsh-mcp-stderr-log =
    let
      noisy = pkgs.writeShellScript "noisy-mcp" ''
        echo "BOOT-NOISE-STDERR" >&2
        echo "READY-STDOUT"
      '';
      fs = (builtins.listToAttrs (map
        (r: { name = r.id; value = r; })
        (pkgs.lib.flatten (map (r: r.insert or [ ]) (applyWith {
          mcpServers.noisy = {
            transport = "stdio";
            command = toString noisy;
            args = [ "--flag" "with space" ];
            env = { };
            cwd = null;
            url = null;
            headers = { };
            toolCallTimeoutMs = null;
            failOnStartupError = false;
            settings = { };
          };
        }).mcpPatches))))."mcp-noisy".config;
      run = pkgs.lib.concatStringsSep " "
        ([ fs.command ] ++ map pkgs.lib.escapeShellArg fs.args);
    in
    pkgs.runCommand "dsh-mcp-stderr-log-check" { } ''
      export XDG_STATE_HOME="$TMPDIR/state" HOME="$TMPDIR/home"
      ${run} > "$TMPDIR/out.log" 2> "$TMPDIR/err.log" \
        || { cat "$TMPDIR/err.log" >&2; exit 1; }
      grep -q READY-STDOUT "$TMPDIR/out.log" || { echo "stdout lost" >&2; exit 1; }
      ! grep -q BOOT-NOISE-STDERR "$TMPDIR/err.log" \
        || { echo "stderr leaked to terminal" >&2; exit 1; }
      grep -q BOOT-NOISE-STDERR "$TMPDIR/state/deepseek-harness/mcp/noisy.log" \
        || { echo "stderr log missing" >&2; exit 1; }
      touch $out
    '';

  # MCP 行必须真的进组合树:patch 形状(带 id 的顶层行)对树上不存在的
  # id 只 warn+skip(实测 cordis-plugin-include,7 行全丢 → /mcp 空屏),
  # 此 check 用 dump-config 端到端验证 insert 通道生效。
  # (bundle 手工构建:userPatches 只取 mcpRows,plugins 只 base —— 与
  # inTreeCheck 的 perProfile 全量通道不同,mcp 行不依赖 provider 源)
  dsh-mcp-in-tree =
    let
      mcpRows = (applyWith {
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
      ${fx.materialize "mcp-tree" bundle}
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
}
