# 插件源解析与元数据(单一定义点,faces/webseam/discovery 共用):
#   lookup          registry(pkgs.dshPlugins)尾名反查
#   sourceOf        功能插件源解析(显式 > pkgs.dshPlugins > registry 反查)
#   faceSourceOf    face 插件源解析(face 不参与分发,走 in-box 表/registry)
#   faceOfSource    源 → face 名元数据(in-box 表 / passthru.dshFace)
#   rosterOfSource  源 → roster 资格元数据(in-box 表 / passthru.dshRoster)
#
# 元数据读取永不强制构建 derivation(passthru 是 eval 期属性);对
# path/无元数据源返回 null,由调用方给缺省语义。
{ lib, inBoxFaces }:

let
  inherit (lib)
    concatStringsSep
    filterAttrs
    last
    splitString
    ;
  inBoxName = name: "@deepseek-ai/dsh-${name}";

  # registry 尾名反查:键名 "dsh-tui" → "@deepseek-harness-tui/dsh-tui"
  # (nixvim 式零 source)。attr 名 <scope>/<pkg>,pkg == <键名> 或
  # "dsh-<键名>" 双形态;唯一匹配取之,空 = null(调用方决定报错语义),
  # 多匹配 throw 列候选(须显式 source)
  lookup = pkgs: name:
    let
      table = pkgs.dshPlugins or { };
      tailOf = k: last (splitString "/" k);
      candidates = filterAttrs
        (k: _: tailOf k == name || tailOf k == "dsh-${name}")
        table;
      ns = builtins.attrNames candidates;
    in
    if ns == [ ] then null
    else if builtins.length ns == 1 then table.${builtins.head ns}
    else throw "programs.dsh.plugins.${name}: registry tail-name lookup is ambiguous (${concatStringsSep ", " ns}); set source explicitly";

  # 名字→源:缺省 registry(不在 registry 且未显式给 source 时,mkPlugin
  # 端 passthru 缺 packageName 会 throw —— 提前给友好错误)
  sourceOf = pkgs: name: p:
    if p.source != null then p.source
    else if pkgs ? dshPlugins && pkgs.dshPlugins ? ${name} then pkgs.dshPlugins.${name}
    else if lookup pkgs name != null then lookup pkgs name
    else throw "programs.dsh.plugins.${name}: no source given and '${name}' not in pkgs.dshPlugins (add it to plugins/names.txt and run the updater, or set source)";

  # face 插件源:in-box 键名映射(headless → @deepseek-ai/dsh-headless)>
  # 显式 source > registry 尾名反查
  faceSourceOf = pkgs: name: p:
    if p.source != null then p.source
    else if inBoxFaces ? ${inBoxName name} then inBoxName name
    else if lookup pkgs name != null then lookup pkgs name
    else throw "programs.dsh.plugins.${name}: face plugin requires a source (registry entry, in-box bundle, or explicit source)";
in
{
  inherit lookup sourceOf faceSourceOf inBoxName;

  # 源 → face 名:derivation 读 passthru.dshFace(registry 收录时人审);
  # 字符串读 in-box 表;其余(path 源等)无元数据 = null
  faceOfSource = s:
    if lib.isDerivation s then (s.passthru or { }).dshFace or null
    else if builtins.isString s && inBoxFaces ? ${s} then inBoxFaces.${s}.face
    else null;

  # 源 → roster 资格(face 树是否带 base agent-presets 行):in-box 表
  # 实测维护(web-app 有/headless 无);registry 收录时物化(update.py
  # roster= 尾参);无元数据 = null(调用方缺省 true:宁可多接管,不可
  # 静默丢接管 —— 错误方向的幽灵禁行只是一行 stderr 警告,反向是
  # preset 接管静默失效)
  rosterOfSource = s:
    # passthru.dshRoster 经 update.py 物化时是字符串("true"/"false",
    # names.txt 尾参形态);字符串化统一,消费侧见 true 即资格
    if lib.isDerivation s then
      (s.passthru or { }).dshRoster or null
    else if builtins.isString s && inBoxFaces ? ${s} then inBoxFaces.${s}.roster
    else null;
}
