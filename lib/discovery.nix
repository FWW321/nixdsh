# preset 自动发现(插件托管 preset,liangshen 形态):
# enabled 插件经 sourceOf 解析后的源(source null 的零 source 插件
# 也在解析后拿到 registry derivation):passthru.dshPresets(registry,
# update.py 收录时探测物化)/ 直扫 presets/ 目录(path 源)。
# 发现即接管 —— 物化剥 tui marker 后 ensurePackagedPresets 视为
# conflict 永不碰;插件 disable → 孤儿清理随动。用户显式
# presets.<name> 声明与发现撞名 → 显式胜(声明即接管先例,
# 合流在消费侧:discovered // declared)。
# 单次扫描双轨:{ presets = 接管面(既有语义); origins = 插件归属
# (preset id → 插件名;dsh-presets 命令数据源,lib.presetOrigins 消费) }
{ lib, registry }:

let
  inherit (lib)
    attrNames
    concatStringsSep
    filter
    foldl'
    listToAttrs
    mapAttrs
    removeAttrs
    ;
in
{
  scan = { cfg, pkgs }:
    let
      scanSrc = src:
        if builtins.isPath src then
          (if builtins.pathExists "${toString src}/presets" then
            listToAttrs (map
              (id: { name = id; value = "${toString src}/presets/${id}"; })
              (filter
                (id: builtins.pathExists "${toString src}/presets/${id}/agent.cordis.yml"
                  && builtins.readFileType "${toString src}/presets/${id}" == "directory")
                (attrNames (builtins.readDir "${toString src}/presets"))))
          else { })
        else if lib.isDerivation src && (src.passthru or { }) ? dshPresets then
          listToAttrs (map
            (id: { name = id; value = "${toString src}/presets/${id}"; })
            src.passthru.dshPresets)
        else { };
      # 黑名单过滤 + typo/残留 fail-loud:排除 id 必须在探测集内
      # (拼错,或上游已删该 preset 而排除表未清 → 配置腐烂,报错清理)
      filterExcluded = name: p: scanned:
        let
          excluded = p.excludedPresets or [ ];
          unknown = filter (id: !scanned ? ${id}) excluded;
        in
        if unknown != [ ] then
          throw "programs.dsh.plugins.${name}: excludedPresets lists '${builtins.head unknown}' but the plugin ships no such preset (detected: ${concatStringsSep ", " (attrNames scanned)}) — typo, or stale after upstream drop?"
        else removeAttrs scanned excluded;
      scanOf = name: p:
        let r = builtins.tryEval (registry.sourceOf pkgs name p); in
        if r.success then filterExcluded name p (scanSrc r.value) else { };
    in
    # tryEval:sourceOf 对未知插件 throw(与插件分发同语义),发现面
    # 不放大 —— 单个插件源解析失败不影响其余(该错误在分发路径已
    # fail-loud,这里不必重复炸)。
    # presets = false 全禁(与 face=false 的"压制自动通道"同构);
    # 与 excludedPresets 非空同设 → 矛盾声明 throw
    foldl'
      (acc: name:
        let
          p = (cfg.plugins or { }).${name} or null;
          merge = scanned: {
            presets = acc.presets // scanned;
            origins = acc.origins // mapAttrs (_: _: name) scanned;
          };
        in
        if p == null || !p.enable then acc
        else if !(p.presets or true) then
          (if (p.excludedPresets or [ ]) != [ ] then
            throw "programs.dsh.plugins.${name}: presets = false (take over none) conflicts with a non-empty excludedPresets — pick one"
           else acc)
        else merge (scanOf name p))
      { presets = { }; origins = { }; }
      (attrNames (cfg.plugins or { }));
}
