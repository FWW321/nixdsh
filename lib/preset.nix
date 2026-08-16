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
  inherit (lib)
    concatStringsSep
    escapeShellArg
    filter
    length
    optionalString
    ;
in
{
  # ── shipped preset 助手(消 config 侧布局硬编码)────────────────────
  # pnpm deploy 布局知识收在 nixdsh 一处;上游布局变化由
  # dsh-preset-discover check 拦(fail-loud 而非 config 侧静默断路径)
  shippedPreset = pkgs: name:
    let root = "${pkgs.dsh}/lib/node_modules/@deepseek-ai/dsh/config/agent-presets"; in
    if builtins.pathExists "${root}/${name}/agent.cordis.yml" then "${root}/${name}"
    else throw "nixdsh: shipped preset '${name}' not found under ${root} (upstream layout change? update shippedPreset in lib/preset.nix)";
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
