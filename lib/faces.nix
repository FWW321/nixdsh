# 交互面(face)推导层 —— face 名的唯一所有权:
#   faceOf        插件 → null|true|str(显式声明 > 源元数据)
#   faceNameOf    插件 → 最终 face 名(true = 键名剥 dsh- 前缀;null = 非 face)
#   faceProfiles  face 插件 → 自动 profile(base + 本源)+ dup/kebab/冲突断言
#   faceValues    per-插件 per-face 值收集(defaultPreset/permissionMode 两处
#                 同构消费,此前三处复制的 faceName 推导在此收敛)
#   rosterEligible  face 树是否承载 roster 舞(presetRoster 选项 > 源元数据
#                 > 缺省 true)
#   exclusivityAssert  手写 profile 嵌 face bundle → throw(交互树独占插件通道)
#
# face 插件互斥不参与分发(进其他树 = duplicate entry / TTY 致死,均实测),
# 功能插件分发到所有 face。face 名约束 kebab-case:它被拼进文件路径
# ($DSH_HOME/profiles/<face>)与子命令名(dsh <face>)。
{ lib, registry }:

let
  inherit (lib)
    any
    attrNames
    concatMap
    concatStringsSep
    elem
    filter
    filterAttrs
    flatten
    listToAttrs
    mapAttrs'
    mapAttrsToList
    nameValuePair
    removePrefix
    ;

  # face 名约束:拼进路径与子命令名(同上游 settingsNamespace 模式)
  validFace = f: builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" f != null;

  # face 推导(源解析感知):显式 plugins.<name>.face > source 的
  # passthru.dshFace(registry 收录时人审)/ inBoxFaces(in-box 表) >
  # 零 source 时先解析源(registry 反查 derivation 同样带 dshFace)再读。
  # 无法纯自动判定互斥(id 冲突之外还有 TTY 等运行期约束,eval 期
  # 不可见),故判定下沉为插件元数据 —— 用户侧只需 enable。
  # false = 显式压制(registry 标记的 face 当功能插件用)→ 归 null
  faceOf = pkgs: name: p:
    let
      derived =
        if p.face != null then p.face
        else if p.source != null then registry.faceOfSource p.source
        else
          # 零 source:in-box 键名反查 > registry 反查(两者都返回源,读元数据)
          if registry.faceOfSource (registry.inBoxName name) != null then registry.faceOfSource (registry.inBoxName name)
          else if registry.lookup pkgs name != null then registry.faceOfSource (registry.lookup pkgs name)
          else null;
    in
    if derived == false then null else derived;

  # 最终 face 名:true = 从 attr 键派生(剥一次 "dsh-" 前缀,免
  # `dsh dsh-tui` 冗余子命令 —— cargo cargo-xx 惯例);字符串尊重显式
  faceNameOf = pkgs: name: p:
    let f = faceOf pkgs name p; in
    if f == true then removePrefix "dsh-" name else f;

  # 交互面插件 → 自动 profile(base + 本源)。face 推导与命名在此
  # 单点定义,faceProfiles/faceValues/roster 消费同一函数
  faceProfiles = { cfg, pkgs }:
    let
      enabled = filterAttrs (name: p: p.enable && faceOf pkgs name p != null) cfg.plugins;
      gen = mapAttrs'
        (name: p:
          let fname = faceNameOf pkgs name p; in
          nameValuePair fname (
            if p.profiles != [ ] then
              throw "programs.dsh.plugins.${name}: face plugin cannot also list target profiles (faces are mutually exclusive trees)"
            else if elem fname (attrNames (cfg.profiles or { })) then
              throw "programs.dsh: face '${fname}' conflicts with explicitly declared profiles.${fname}"
            else {
              plugins = [ "@deepseek-ai/dsh-base" (registry.faceSourceOf pkgs name p) ];
              userPatchesFile = null;
              userPatches = [ ];
            }))
        enabled;
      _dupAssert =
        let faceNames = mapAttrsToList (name: p: faceNameOf pkgs name p) enabled; in
        if builtins.length faceNames != builtins.length (lib.unique faceNames) then
          throw "programs.dsh.plugins: duplicate face names (${concatStringsSep ", " faceNames})"
        else if any (f: !validFace f) faceNames then
          throw "programs.dsh.plugins: face names must be kebab-case ([a-z0-9-], got: ${concatStringsSep ", " faceNames}) — face becomes a profile directory and the dsh <face> subcommand name"
        else null;
    in
    builtins.seq _dupAssert gen;

  # per-插件 per-face 值 → { tree = value }(defaultPreset / permissionMode
  # 等所有"值挂交互插件"的选项共用;推导链与 faceProfiles 同源,
  # face 改名自动跟随)
  faceValues = cfg: pkgs: key:
    listToAttrs (map
      (e: nameValuePair e.tree e.value)
      (flatten (mapAttrsToList
        (name: p:
          let v = p.${key} or null; in
          if p.enable && v != null then [{ tree = faceNameOf pkgs name p; value = v; }] else [ ])
        (cfg.plugins or { }))));

  # roster 舞资格:显式 presetRoster > 源元数据(in-box 表/registry
  # passthru)> 缺省 true。headless(in-box roster=false)由此排除 ——
  # 无 base agent-presets 行的树出舞行只会注入服务 + 幽灵禁行警告
  rosterEligible = { cfg, pkgs, name, p }:
    let
      explicit = p.presetRoster or null;
      meta =
        if p.source != null then registry.rosterOfSource p.source
        else if registry.rosterOfSource (registry.inBoxName name) != null then registry.rosterOfSource (registry.inBoxName name)
        else if registry.lookup pkgs name != null then registry.rosterOfSource (registry.lookup pkgs name)
        else null;
      # 元数据可能以字符串形态物化(update.py 尾参 "true"/"false");
      # 归一为 bool,显式选项天然已是 bool
      normalize = v:
        if v == null then null
        else v == true || v == "true";
    in
    normalize (if explicit != null then explicit else meta);
in
{
  inherit validFace faceOf faceNameOf faceProfiles faceValues rosterEligible;

  # ── 强一致性:face 树独占插件通道 ──────────────────────────────
  # 手写 profile 嵌 face bundle(交互插件)→ throw。软一致性的三个
  # 漏洞(face=false 压制/face 改名/手写树绕开推导)全部源于双通道
  # 都能建交互树;收口后 per-插件选项(defaultPreset/permissionMode)
  # 恒有锚,face 改名自动跟随,树生命周期严格绑定插件。
  # 检测:in-box 字符串命中 inBoxFaces(web-app/headless)/ derivation
  # 源带 passthru.dshFace(registry 收录时人审)。路径源无元数据,
  # 不可检 —— 文档纪律:交互 bundle 走插件通道。
  # 手写 profiles 的存在本身合法(非交互命名组合:base+功能插件+
  # patches);userPatchesFile 是全权委托,检测不到,同属文档纪律。
  exclusivityAssert = { cfg, pkgs }:
    let
      isFaceSource = s: registry.faceOfSource s != null;
      offenders =
        concatMap
          (pname:
            let p = (cfg.profiles or { }).${pname}; in
            map
              (s: { profile = pname; source = s; })
              (filter isFaceSource (p.plugins or [ ])))
          (attrNames (cfg.profiles or { }));
      fmt = o: "${o.profile} ← ${if builtins.isString o.source then o.source else toString o.source}";
    in
    if offenders != [ ] then
      throw "programs.dsh: face bundles in hand-written profiles (${concatStringsSep "; " (map fmt offenders)}) — interactive trees come exclusively from the plugin channel (plugins.<name>.enable auto-generates the face profile); hand-written profiles are for non-interactive named compositions"
    else null;
}
