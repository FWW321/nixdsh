# 源域(构建期):yq 独立解析器交叉验证(patch YAML/preset 重放)、
# preset 剥离物理性、farm 实然、preset-origins 命令行为级。
# 纯求值断言(providers 合并/skills 校验/发现面/路径分离)在 tests/sources.nix
#
# IFD 纪律:比较全部在 build 脚本内做(yq/test/grep),不用
# builtins.readFile(runCommand 产物)—— 旧版曾依赖求值期 IFD,
# --no-allow-import-from-derivation 环境直接红
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith;
in
{
  # patch YAML emitter 交叉验证:独立解析器(yq,Go 实现)确认产物是
  # 合法 YAML 且语义值正确 —— 与 tests/profile.nix 的文本金样互补
  # (第三实现对 emitter 覆盖:形状靠金样,合法性靠 yq)
  dsh-patch-yaml-validity =
    let
      yml = dshLib.patchesToYaml [
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
      file = pkgs.writeText "patch-yaml.yml" yml;
    in
    pkgs.runCommand "dsh-patch-yaml-validity-check"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        # 整文件解析不炸 + 5 行;抽两个语义值(bool 不成 "1"/int 不加引号)
        n=$(yq 'length' ${file})
        test "$n" = "5" || { echo "document must parse to 5 rows, got $n"; exit 1; }
        v=$(yq '.[1].config.fetch' ${file})
        test "$v" = "true" || { echo "booleans must render as YAML true"; exit 1; }
        v=$(yq '.[1].config.searchTimeoutMs' ${file})
        test "$v" = "60000" || { echo "integers must render unquoted"; exit 1; }
        touch $out
      '';

  # preset 物化管线(行为级):能力行重放(yq 按 id 改写 config 键,
  # 行不在 preset 里无操作)、tui marker 剥离、其余文件原样
  dsh-preset-replay =
    let
      # 夹具:仿 preset 目录(agent.cordis.yml 含 tool-web fetch:false)+
      # tui 所有权 marker
      srcBase = pkgs.runCommand "preset-replay-src" { } ''
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
          {
            id = "tool-web";
            config = {
              fetch = true;
            };
          }
          {
            id = "nonexistent";
            config = {
              x = 1;
            };
          } # 行不在 preset → 无操作
        ];
      };
    in
    pkgs.runCommand "dsh-preset-replay-check"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        v=$(yq '.[] | select(.id == "tool-web") | .config.fetch' ${replayed}/agent.cordis.yml)
        test "$v" = "true" || { echo "capability row must rewrite tool-web config.fetch to true, got $v"; exit 1; }
        test ! -e "${replayed}/.dsh-tui-managed.json" \
          || { echo "tui ownership marker must be stripped (ensurePackagedPresets would otherwise staged-replace the materialized copy)"; exit 1; }
        test -f "${replayed}/agent.cordis.yml" || { echo "other preset files must survive verbatim"; exit 1; }
        touch $out
      '';

  # preset 重放 drift 拦截:真实 shipped standard + 真实能力行组过
  # buildPreset,断言 tool-web fetch 保险丝 + 超时键真的写进去了。
  # 上游 preset 行改名/挪键/删行 → 重放静默变 no-op → 此 check 炸
  # (fail-loud),而非运行时静默失效
  dsh-preset-replay-drift =
    let
      # 与生产同构的能力行组:选中 fetch 后端 → webSeamRows 含
      # {fetch:true, searchTimeoutMs:60000} 的 tool-web 重述行
      applied = applyWith {
        webFetch = "probe";
        webFetchProviders.probe.row.name = "@example/dsh-web-fetch-probe";
      };
      replayed = dshLib.buildPreset {
        inherit pkgs;
        source = dshLib.shippedPreset pkgs "standard";
        rows = applied.webSeamRows;
      };
    in
    pkgs.runCommand "dsh-preset-replay-drift-check"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        v=$(yq '.[] | select(.id == "tool-web") | .config.fetch' ${replayed}/agent.cordis.yml)
        test "$v" = "true" \
          || { echo "shipped standard no longer takes the tool-web fetch rewrite (upstream row shape changed — update the replay row ids in lib/webseam.nix)"; exit 1; }
        v=$(yq '.[] | select(.id == "tool-web") | .config.searchTimeoutMs' ${replayed}/agent.cordis.yml)
        test "$v" = "60000" \
          || { echo "the replayed tool-web row must carry searchTimeoutMs: 60000 (A2 — the whole-row restatement feeds the farm replay)"; exit 1; }
        touch $out
      '';

  # preset 发现剥离物理性:排除目录在剥离副本里物理不存在
  # (发现面/枚举语义在 tests/sources.nix)
  dsh-preset-strip =
    let
      pathSrc = ../fixtures/preset-path-src;
      foundExcl =
        (applyWith {
          plugins.d = {
            enable = true;
            source = pathSrc;
            excludedPresets = [ "second-one" ];
          };
        }).discoveredPresets;
      strippedPresets = builtins.dirOf foundExcl.handmade;
    in
    pkgs.runCommand "dsh-preset-strip-check" { } ''
      test -d ${strippedPresets}/handmade \
        || { echo "kept preset dir missing in stripped copy" >&2; exit 1; }
      test ! -e ${strippedPresets}/second-one \
        || { echo "excluded preset dir must be physically stripped" >&2; exit 1; }
      touch $out
    '';

  # preset 出处总账(行为级):farm 实然(shipped 全量在场)+ 命令真跑
  # (默认表 + --live 树比对 + --tree 单树诊断 + 未知旗标 fail-loud)。
  # 表三态/fork 标注的纯求值面在 tests/sources.nix
  dsh-preset-origins =
    let
      origins = dshLib.presetOrigins {
        inherit pkgs;
        declared = {
          custom-standard = dshLib.shippedPreset pkgs "standard"; # fork(shipped 路径)
        };
        discoveredOrigins = {
          liangshen = "dsh-tui";
        };
      };
      farm = dshLib.buildPresetFarm {
        inherit pkgs;
        declared = {
          custom-standard = dshLib.shippedPreset pkgs "standard";
        };
        discovered = { };
        rows = [ ];
      };
      cmd = dshLib.mkPresetOriginsCmd {
        inherit pkgs origins farm;
        dshHome = "/tmp/dsh-origins-check";
      };
      # --live/--tree 的树夹具:web 树 in-sync(roots=farm)、tui 树旧 farm
      trees = pkgs.runCommand "origins-trees" { } ''
        mkdir -p $out/profiles/web $out/profiles/tui $out/profiles/headless
        printf '%s' '[{"insert":[{"id":"agent-presets-nix","name":"@deepseek-ai/dsh-agent-presets","config":{"default":"custom-standard","roots":[{"path":"${farm}","trust":"system"}]}}]}]' > $out/profiles/web/cordis.patch.yml
        printf '%s' '[{"insert":[{"id":"agent-presets-nix","name":"@deepseek-ai/dsh-agent-presets","config":{"default":"liangshen","roots":[{"path":"/nix/store/0000000000000000000000000000000-dsh-preset-farm-old","trust":"system"}]}}]}]' > $out/profiles/tui/cordis.patch.yml
        printf '[]' > $out/profiles/headless/cordis.patch.yml
      '';
    in
    pkgs.runCommand "dsh-preset-origins-check" { } ''
      # farm 实然:shipped 全量在场(重放接管,无 passthrough 缺员)
      for _id in ${toString (dshLib.shippedPresetNames pkgs)}; do
        [ -f "${farm}/$_id/agent.cordis.yml" ] || { echo "farm missing shipped preset: $_id" >&2; exit 1; }
      done
      # 默认表:三态齐 + fork 标注
      _tbl=$(${cmd}/bin/dsh-presets)
      echo "$_tbl" | grep -qE '^custom-standard\s+declared\s+presets.custom-standard' || { echo "$_tbl" >&2; exit 1; }
      echo "$_tbl" | grep -q 'shipped:standard' || { echo "forkOf annotation missing" >&2; exit 1; }
      echo "$_tbl" | grep -qE '^liangshen\s+discovered\s+plugins.dsh-tui' || { echo "$_tbl" >&2; exit 1; }
      echo "$_tbl" | grep -qE '^standard\s+replayed\s+dsh$' || { echo "$_tbl" >&2; exit 1; }
      # --live:web 树 sync / tui 树 pending / headless 无行静默
      live=$(DSH_HOME=${trees} ${cmd}/bin/dsh-presets --live)
      echo "$live" | grep -q '✓ web: roster in sync' || { echo "$live" >&2; exit 1; }
      echo "$live" | grep -q '✗ tui: pending switch' || { echo "$live" >&2; exit 1; }
      echo "$live" | grep -q headless && { echo "$live" >&2; exit 1; }
      # --tree:单树诊断(default/roots/sync)
      t=$(DSH_HOME=${trees} ${cmd}/bin/dsh-presets --tree web)
      echo "$t" | grep -q 'default: custom-standard' || { echo "$t" >&2; exit 1; }
      echo "$t" | grep -q '✓ in sync' || { echo "$t" >&2; exit 1; }
      t=$(DSH_HOME=${trees} ${cmd}/bin/dsh-presets --tree headless)
      echo "$t" | grep -q 'no roster row' || { echo "$t" >&2; exit 1; }
      # 未知旗标 fail-loud
      if ${cmd}/bin/dsh-presets --bogus 2>/dev/null; then echo "bogus flag must fail" >&2; exit 1; fi
      touch $out
    '';
}
