# preset 物化管线(build 期改写)与 roster 接管:
#   buildPreset { pkgs; source; rows } → derivation(重放引擎)
#   buildPresetFarm { pkgs; declared; discovered; rows } → 单一 store 根
#
# ⚠ 机制注记(上游闭门,本地永久):上游 preset 是终态组合("a preset IS
# a composition"),能力行(tool-web 的 fetch 保险丝等)散在每个 preset
# 文件里,宿主层 patch 被 preset 层遮蔽(resolution: agent → preset →
# global)。本地终局 = **roster 接管**:禁 base 的 agent-presets 行、以
# 异 id 重插同包实例带自定义 roots(profile-boot 的 clobber 只打 id
# "agent-presets",异 id 不受击 —— 实证 profile-boot-*.js:180),roster
# = [farm(system), user]。farm 内**全部 preset 均为重放产物**(含
# shipped id —— 手选逃逸随之关闭);includeUserRoot 缺省保留,手写
# preset 照旧热发现。trust: system → tui 视同 shipped,marker 舞与
# 物化 activation 整体退役(store 只读,零运行时状态)。
# 若上游将来开放并修缝(mountPreset overlay),本层可退役 —— 注记
# 保留此可能,不依赖它。
#
# 机制(与 profile 的 base+userPatches 同构):
#   - rows = 能力选项渲染的行组(applyPlugins 单一事实源;当前 =
#     wfRows 的 fetch:true 保险丝行等)。yq 按 id 匹配改写 config 键
#     (幂等;行不在 preset 里 → 无操作 —— minimal 无 tool-web 行是
#     身份语义,不 insert)
#   - 剥 .dsh-tui-managed.json:tui 的 ensurePackagedPresets 以 marker
#     认领用户目录(有 marker → staged 替换,改写丢失;无 marker →
#     conflict 永不碰)。剥掉后所有权彻底归声明方,升级 = source 路径
#     变 = stamp 变 = 重物化重放
#   - 改写增/删/改 → 产物 store 路径变 → activation 重物化:删除自动
#     清理是 derivation 物化的属性,不是扫描修正
{ lib }:

let
  # pnpm deploy 布局:shipped preset 根(shippedPreset/shippedPresetNames/
  # presetOrigins 共用)
  shippedRoot = pkgs: "${pkgs.dsh}/lib/node_modules/@deepseek-ai/dsh/config/agent-presets";
  inherit (lib)
    attrNames
    baseNameOf
    concatStringsSep
    escapeShellArg
    filter
    genAttrs
    hasPrefix
    length
    mapAttrs
    mapAttrsToList
    optionalString
    ;
in
rec
{
  # ── shipped preset 助手(消 config 侧布局硬编码)────────────────────
  # pnpm deploy 布局知识收在 nixdsh 一处;上游布局变化由
  # dsh-preset-discover check 拦(fail-loud 而非 config 侧静默断路径)
  shippedPreset = pkgs: name:
    let root = shippedRoot pkgs; in
    if builtins.pathExists "${root}/${name}/agent.cordis.yml" then "${root}/${name}"
    else throw "nixdsh: shipped preset '${name}' not found under ${root} (upstream layout change? update shippedPreset in lib/preset.nix)";
  # shipped preset id 全集(readDir 枚举,须含 agent.cordis.yml 的目录)。
  # builtin 只读参考:dsh 升级集合自动跟随;与接管面(declared/discovered)
  # 无交集语义 —— fork(declared source 指向 shipped 路径)经 presetOrigins
  # 标注,不在此处理
  shippedPresetNames = pkgs:
    let root = shippedRoot pkgs; in
    filter (id: builtins.pathExists "${root}/${id}/agent.cordis.yml")
      (attrNames (builtins.readDir root));

  # ── preset 出处总账(dsh-presets 命令的数据源)────────────────────
  # 三态(farm 内实然;farm 之外不存在其他来源 —— user 根是用户的,不进账):
  #   replayed  = shipped id 的重放接管(随 dsh 升级,能力行已重放)
  #   declared  = 显式 presets.<name> 接管(source 落 shipped root 内 →
  #               forkOf 标注换名 fork)
  #   discovered= 插件源自动发现接管
  presetOrigins =
    { pkgs, declared ? { }, discoveredOrigins ? { } }:
    let
      root = shippedRoot pkgs;
      shippedIds = filter (id: builtins.pathExists "${root}/${id}/agent.cordis.yml")
        (attrNames (builtins.readDir root));
      declaredRow = name: src: {
        mode = "declared";
        origin = "presets.${name}";
      } // (let s = toString src; in
        if hasPrefix root s then { forkOf = baseNameOf s; } else { });
    in
    (genAttrs shippedIds (_: { mode = "replayed"; origin = "dsh"; }))
    // (mapAttrs (_: id: { mode = "discovered"; origin = "plugins.${id}"; }) discoveredOrigins)
    // (mapAttrs declaredRow declared);

  # roster 根:全部 preset 的重放产物单一 store 目录。shipped id 全量
  # 重放(能力行进 shipped —— 手选逃逸关闭);declared/discovered 覆盖
  # 同名(声明即接管先例)。rows 里的 insert 行被 buildPreset 自然滤掉
  # (无顶层 config 键),与旧物化语义一致
  buildPresetFarm =
    { pkgs, declared ? { }, discovered ? { }, rows ? [ ] }:
    let
      root = shippedRoot pkgs;
      shippedIds = shippedPresetNames pkgs;
      all =
        (genAttrs shippedIds (id: "${root}/${id}"))
        // discovered
        // declared;
    in
    pkgs.runCommand "dsh-preset-farm"
      {
        meta.description = "dsh preset roster root (replayed; ${toString (length (attrNames all))} presets, ${toString (length rows)} row groups)";
      }
      (concatStringsSep "\n"
        (mapAttrsToList
          (name: src: ''
            mkdir -p "$out"
            cp -a ${toString (buildPreset { inherit pkgs rows; source = src; })} "$out/${name}"
          '')
          all));

  # dsh-presets 命令(hm-module home.packages 挂载;checks 直测):
  # 构建期 JSON 快照(总账 + farm 路径)只读渲染。
  #   默认      总账表(farm 内全部 preset:replayed/declared/discovered)
  #   --live    对比各 face 树的 roster 行 roots 是否指向当前 farm
  #             (旧 farm/无行 = pending switch;无行的树静默跳过)
  #   --tree F  单树诊断:default/roots/同步态
  mkPresetOriginsCmd =
    { pkgs, origins, farm, dshHome }:
    let
      json = pkgs.writeText "dsh-preset-origins.json"
        (builtins.toJSON { inherit farm; presets = origins; });
    in
    pkgs.writeShellApplication {
      name = "dsh-presets";
      runtimeInputs = with pkgs; [ jq util-linux ];
      text = ''
        origins=${json}
        dsh_home="''${DSH_HOME:-${dshHome}}"

        tree_roster() {
            # 输出 <default> <roots-path>;无行/不可解析 → 空
            jq -r '
              [.[] | select(.insert?) | .insert[]
               | select(.id == "agent-presets-nix")] | .[0]
              | if . == null then empty else
                  "\(.config.default // "-")\t\(.config.roots[0].path // "-")"
                end
            ' "$1" 2>/dev/null || true
        }

        if [ "$#" -eq 0 ]; then
            jq -r '.presets | to_entries | sort_by(.value.mode, .key) | .[] |
                "\(.key)\t\(.value.mode)\t\(.value.origin)\(if .value.forkOf then " ← shipped:\(.value.forkOf)" else "" end)"
            ' "$origins" | column -t -s "$(printf '\t')"
            echo
            echo "(roster root: $(jq -r .farm "$origins"); --live 对比各树; --tree <face> 单树诊断)"
            exit 0
        fi

        case "$1" in
            --live)
                farm_now="$(jq -r .farm "$origins")"
                for patch in "$dsh_home"/profiles/*/cordis.patch.yml; do
                    [ -f "$patch" ] || continue
                    tree="$(basename "$(dirname "$patch")")"
                    row="$(tree_roster "$patch")"
                    [ -n "$row" ] || continue
                    roots="$(printf '%s' "$row" | cut -f2)"
                    if [ "$roots" = "$farm_now" ]; then
                        echo "✓ $tree: roster in sync"
                    else
                        echo "✗ $tree: pending switch (roots=$roots, current=$farm_now)"
                    fi
                done
                ;;
            --tree)
                if [ $# -lt 2 ]; then echo "usage: dsh-presets --tree <face>" >&2; exit 1; fi
                patch="$dsh_home/profiles/$2/cordis.patch.yml"
                if [ ! -f "$patch" ]; then
                    echo "no such tree: $2 (under $dsh_home/profiles/)" >&2; exit 1
                fi
                row="$(tree_roster "$patch")"
                if [ -z "$row" ]; then
                    echo "$2: no roster row (hand-written or headless tree)"
                    exit 0
                fi
                farm_now="$(jq -r .farm "$origins")"
                roots="$(printf '%s' "$row" | cut -f2)"
                echo "tree:    $2"
                echo "default: $(printf '%s' "$row" | cut -f1)"
                echo "roots:   $roots"
                [ "$roots" = "$farm_now" ] && echo "sync:    ✓ in sync" || echo "sync:    ✗ pending switch"
                ;;
            -h|--help)
                echo "usage: dsh-presets [--live | --tree <face>]"
                ;;
            *)
                echo "unknown flag: $1 (try --live / --tree <face>)" >&2
                exit 1
                ;;
        esac
      '';
    };

  # source: preset 目录(path/store 路径,须含 agent.cordis.yml —— 上游
  #   validatePresets 已拦)
  # rows: cordis patch 行组([{id, config = {...}}];disabled/insert 形态
  #   不进 preset —— 它们是全局树语义)
  buildPreset =
    { pkgs, source, rows ? [ ] }:
    let
      # 每行渲染为 yq 赋值链:行内 config 各键一个赋值(键值对序列;
      # select(.id == X) 无匹配 → 赋值无操作,yq 不炸)
      rowExpr = row:
        let
          kv = lib.mapAttrsToList
            (k: v: ''(.[] | select(.id == "${row.id}") | .config.${k}) = ${builtins.toJSON v}'')
            (row.config or { });
        in
        concatStringsSep " | " kv;
      expr =
        if rows == [ ] then null
        else concatStringsSep " | " (map rowExpr (filter (r: r ? config && r.config != { }) rows));
    in
    pkgs.runCommand "dsh-preset-${baseNameOf (toString source)}"
      {
        meta.description = "dsh preset '${baseNameOf (toString source)}' with capability rows replayed (${toString (length rows)} rows)";
      }
      ''
        cp -a ${escapeShellArg (toString source)} "$out"
        chmod -R u+w "$out"
        rm -f "$out/.dsh-tui-managed.json"
        ${lib.optionalString (expr != null) ''
          ${lib.getExe pkgs.yq-go} -i ${escapeShellArg expr} "$out/agent.cordis.yml"
        ''}
      '';
}
