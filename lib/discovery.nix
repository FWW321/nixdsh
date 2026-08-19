# preset 自动发现(插件托管 preset,liangshen 形态):
# enabled 插件经 sourceOf 解析后的源(source null 的零 source 插件
# 也在解析后拿到 registry derivation):passthru.dshPresets(registry,
# update.py 收录时探测物化;excludedPresets 剥离后已过滤)/ 直扫
# presets/ 目录(path 源)。发现即接管 —— 物化剥 tui marker 后
# ensurePackagedPresets 视为 conflict 永不碰;插件 disable → 孤儿
# 清理随动。用户显式 presets.<name> 声明与发现撞名 → 显式胜(声明
# 即接管先例,合流在消费侧:discovered // declared)。
#
# excludedPresets 在源解析层已物理剥离(registry.withPresetsExcluded:
# preset 目录从插件源移除),此处与 farm 无从看见 —— 无需再滤。
# 语义对比:presets = false 只是"不接管"(上游播种照旧);
# excludedPresets 是"不存在"(播种器也无从种出)。
#
# 单次扫描双轨:{ presets = 接管面(既有语义); origins = 插件归属
# (preset id → 插件名;dsh-presets 命令数据源,lib.presetOrigins 消费) }
{ lib, registry }:

let
  inherit (lib)
    attrNames
    filter
    foldl'
    listToAttrs
    mapAttrs
    ;
in
{
  scan = { cfg, pkgs }:
    let
      # path 源直扫:仅收有效 preset 目录(须含组合文件)
      scanPath = src:
        if builtins.pathExists "${toString src}/presets" then
          listToAttrs (map
            (id: { name = id; value = "${toString src}/presets/${id}"; })
            (filter
              (id: builtins.pathExists "${toString src}/presets/${id}/agent.cordis.yml"
                && builtins.readFileType "${toString src}/presets/${id}" == "directory")
              (attrNames (builtins.readDir "${toString src}/presets"))))
        else { };
      # derivation 源读 passthru.dshPresets(已按剥离过滤)
      scanDrv = src:
        listToAttrs (map
          (id: { name = id; value = "${toString src}/presets/${id}"; })
          src.passthru.dshPresets);
      scanSrc = src:
        if builtins.isPath src then scanPath src
        else if lib.isDerivation src && (src.passthru or { }) ? dshPresets then scanDrv src
        else { };
      scanOf = name: p:
        # 排除表非空 → 源必须可解析且校验通过(拼错/上游已删/不可剥
        # 离,均在 sourceOf 冒泡):此处不吞错。零排除保持旧语义
        # (未知插件静默跳过 —— 分发路径已 fail-loud)
        if (p.excludedPresets or [ ]) != [ ] then
          scanSrc (registry.sourceOf pkgs name p)
        else
          let r = builtins.tryEval (registry.sourceOf pkgs name p); in
          if r.success then scanSrc r.value else { };
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
