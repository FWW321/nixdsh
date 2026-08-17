# preset 物化管线(build 期改写 + 剥所有权 marker):
#   buildPreset { pkgs; source; rows } → derivation
#
# ⚠ RETIRING 注记:本层是对上游架构缺陷的声明式补丁,不是长期机制 ——
# 上游 preset 是终态组合("a preset IS a composition"),能力行(tool-web
# 的 fetch 保险丝等)散在每个 preset 文件里,宿主层 patch 被 preset 层
# 遮蔽(resolution: agent → preset → global)。当上游把能力保险丝接进
# settings 热缝或宿主 web 行 config(已列上游 issue 批次),本层整体
# 退役,preset 物化回退为纯 cp。
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
    optionalString
    ;
in
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
  # 三态:builtin(runtime 自带,只读参考,不物化)/ declared(显式
  # presets.<name> 接管物化)/ discovered(插件源自动发现接管)。
  # fork 检测:declared source 路径落在 shipped root 内 → forkOf 标注
  # (shipped:standard 换名接管,first-root-wins 遮蔽先例)。
  # excludedPresets 不进账(排除了就是没有);要看出处再排错的入口是
  # 命令本身列插件面 —— 排除表语义已由 excludedPresets typo throw 兜住
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
    (mapAttrs (_: id: { mode = "discovered"; origin = "plugins.${id}"; }) discoveredOrigins)
    // (mapAttrs declaredRow declared)
    // (genAttrs shippedIds (_: { mode = "builtin"; origin = "dsh"; }));

  # dsh-presets 命令(hm-module home.packages 挂载;checks 直测):
  # 构建期 JSON 快照 + 只读渲染,--live 对比物化区(声明在而未物化 =
  # pending switch;物化在而声明无 = orphan/手写)。出处文件不进
  # ~/.dsh/.agent-presets(tui 扫描根,外来文件风险),只在命令 store 路径
  mkPresetOriginsCmd =
    { pkgs, origins, dshHome }:
    let
      json = pkgs.writeText "dsh-preset-origins.json" (builtins.toJSON origins);
    in
    pkgs.writeShellApplication {
      name = "dsh-presets";
      runtimeInputs = with pkgs; [ jq util-linux ];
      text = ''
        origins=${json}
        dsh_home=${dshHome}

        if [ "$#" -eq 0 ]; then
            jq -r 'to_entries | sort_by(.value.mode, .key) | .[] |
                "\(.key)\t\(.value.mode)\t\(.value.origin)\(if .value.forkOf then " ← shipped:\(.value.forkOf)" else "" end)"
            ' "$origins" | column -t -s "$(printf '\t')"
            echo
            echo "(builtin = runtime 自带只读参考;declared/discovered = Nix 接管物化;--live 对比 $dsh_home/.agent-presets)"
            exit 0
        fi

        case "$1" in
            --live)
                mapfile -t ids < <(jq -r 'to_entries | map(select(.value.mode != "builtin")) | .[].key' "$origins")
                for id in "''${ids[@]}"; do
                    if [ -d "$dsh_home/.agent-presets/$id" ]; then
                        echo "✓ $id: in sync"
                    else
                        echo "✗ $id: declared but not materialized (pending switch?)"
                    fi
                done
                for dir in "$dsh_home"/.agent-presets/*; do
                    [ -e "$dir" ] || continue
                    name="$(basename "$dir")"
                    case " ''${ids[*]} " in
                        *" $name "*) ;;
                        *) echo "? $name: in ~/.dsh but not in current generation (orphan or hand-written)" ;;
                    esac
                done
                ;;
            -h|--help)
                echo "usage: dsh-presets [--live]"
                ;;
            *)
                echo "unknown flag: $1 (try --live)" >&2
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
