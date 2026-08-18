# cordis patch 行的 YAML 渲染层(profile patch 文件的单一事实源):
#   patchesToYaml  行列表 → 块式 YAML(buildProfile 落 cordis.patch.yml)
#   rawYaml        原生 YAML 标量标记 —— {!!js process.cwd()} 等 JSON 无法
#                  表达的 base 行值;整行重述纪律的载体(A3 级修复:
#                  sandbox-policy.workspaceRoot 与上游 !!js 同构重述)
#   isRawYaml      标记判别(yq 重放路径借此 fail-loud 拒收 raw 值)
#
# 背景:上游 patch 文件本身就是块式 YAML 且带 !!js 标签(dsh-base
# cordis.patch.yml);此前用 toJSON 渲染是"JSON 是 YAML 子集"的便利,
# 代价是标量域被锁死在 JSON → 重述 base 行只能丢键(靠运行时兜底
# 碰巧不炸)。此模块把渲染面与上游格式对齐:块式 + raw 标量。
# dsh 的 loader 用同一 YAML schema 解析 patch 文件,!!js 在 boot 期
# 求值,语义与 base 行一致。
{ lib }:

let
  inherit (lib)
    concatLists
    concatStringsSep
    genList
    mapAttrsToList
    removePrefix
    ;

  # 原生 YAML 值:文本原样落盘(不引号、不转义)。attr 名刻意怪异,
  # 避免与真实 config 键撞形;结构上不是标量 → isBlock 判定须排除
  rawYaml = text: { __rawYaml = text; };
  isRawYaml = v: builtins.isAttrs v && builtins.attrNames v == [ "__rawYaml" ];

  # 标量渲染:字符串走 toJSON(JSON 双引号串是合法 YAML 双引号串,
  # 转义规则一致);bool 显式(Nix 的 toString true = "1" 是 shell 惯例
  # 强转,直书会产出非法 YAML 布尔);path/derivation toString 收敛
  scalar = v:
    if isRawYaml v then v.__rawYaml
    else if v == null then "null"
    else if builtins.isBool v then (if v then "true" else "false")
    else if builtins.isInt v || builtins.isFloat v then toString v
    else if builtins.isString v then builtins.toJSON v
    else if lib.isDerivation v || builtins.isPath v then builtins.toJSON (toString v)
    else throw "nixdsh patch: cannot render a ${builtins.typeOf v} as a YAML scalar";

  # 键:常规标识符平书;含特殊字符的键走 toJSON 双引号(合法 YAML 键)
  safeKey = k:
    if builtins.match "[A-Za-z_][A-Za-z0-9_-]*" k != null then k
    else builtins.toJSON k;

  # 空集合内联("[]"/"{}"),非空集合走块式
  inline = v:
    if builtins.isList v && v == [ ] then "[]"
    else if builtins.isAttrs v && !isRawYaml v && v == { } then "{}"
    else scalar v;
  isBlock = v:
    (builtins.isList v && v != [ ])
    || (builtins.isAttrs v && !isRawYaml v && v != { });

  # 块式 emitter:返回行列表(每行含自身缩进)。序列项 "- " 前缀与
  # 子级缩进的对齐靠"先按子级缩进渲染,再把首行前缀换成 '- '"
  linesOf = depth: v:
    let
      pad = concatStringsSep "" (genList (_: "  ") depth);
      childPad = pad + "  ";
      child = linesOf (depth + 1);
      seqItem = x:
        let xs = child x; in
        [ (pad + "- " + removePrefix childPad (builtins.head xs)) ] ++ builtins.tail xs;
      mapEntry = k: val:
        if isBlock val
        then [ (pad + "${safeKey k}:") ] ++ child val
        else [ (pad + "${safeKey k}: ${inline val}") ];
    in
    if isRawYaml v then [ (pad + v.__rawYaml) ]
    else if builtins.isList v then
      (if v == [ ] then [ (pad + "[]") ] else concatLists (map seqItem v))
    else if builtins.isAttrs v then
      (if v == { } then [ (pad + "{}") ] else concatLists (mapAttrsToList mapEntry v))
    else [ (pad + scalar v) ];

  patchesToYaml = rows:
    concatStringsSep "\n" (linesOf 0 rows) + "\n";
in
{
  inherit rawYaml isRawYaml patchesToYaml;
}
