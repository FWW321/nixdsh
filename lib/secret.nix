# secret 双通道:
#   env 桥(secretEnvName/secretEnv)— secretFile 声明 → wrapper export 环境变量,
#     每次调用现读文件(轮换即生效);文件缺失不 export(boot 不炸,provider 按请求报错)
#   占位符通道(secretPlaceholder/renderSecretVal/renderSecretAttrs)— store 工件渲染
#     "@dsh-secret:<path>@" 占位符,wrapper 启动期对物化副本 replace-secret 注入真值
#     (MCP env/headers 用;boot fail-loud)
{ lib }:

let
  inherit (lib)
    attrValues
    baseNameOf
    concatMap
    filter
    foldl'
    mapAttrs
    ;

  # secretFile 声明的 env 名派生约定:/run/secrets/zhipu_api_key →
  # ZHIPU_API_KEY(文件名大写)。派生不是猜上游默认 —— 它同时定义并
  # 渲染 apiKeyEnv 进行 config/路由,行自描述,不存在"猜错"形态;
  # 不符约定的文件名 → 显式写 apiKeyEnv。
  secretEnvName = f: lib.toUpper (baseNameOf f);

  # 密钥 env 收集:providers 全表 + webSearch 选中后端 row 的 secretFile
  # 声明 → { env = file; }(wrapper export 清单)。同 env 多声明:
  # 同文件去重(一个 ZHIPU_API_KEY 喂所有消费者),不同文件 → throw
  # (配置漂移,fail-loud)。独立于 renderSettings,可被 stub cfg 直调。
  secretEnv =
    { cfg }:
    let
      wsSel = cfg.webSearch or null;
      wsDecl = if wsSel == null then null else (cfg.webSearchProviders or { }).${wsSel} or null;
      wsRow =
        if wsDecl != null && (wsDecl.row.secretFile or null) != null then [
          {
            env = (wsDecl.row.config or { }).apiKeyEnv or (secretEnvName wsDecl.row.secretFile);
            file = wsDecl.row.secretFile;
          }
        ] else [ ];
      provTable = if (cfg.providers or null) == null then { } else cfg.providers;
      wfSel = cfg.webFetch or null;
      wfDecl = if wfSel == null then null else (cfg.webFetchProviders or { }).${wfSel} or null;
      wfRow =
        if wfDecl != null && (wfDecl.row.secretFile or null) != null then [
          {
            env = (wfDecl.row.config or { }).apiKeyEnv or (secretEnvName wfDecl.row.secretFile);
            file = wfDecl.row.secretFile;
          }
        ] else [ ];
      provs = filter
        (p: (p.secretFile or null) != null)
        (attrValues provTable);
      entries =
        wsRow
        ++ wfRow
        ++ map
          (p: {
            env = if (p.apiKeyEnv or null) != null then p.apiKeyEnv else secretEnvName p.secretFile;
            file = p.secretFile;
          })
          provs;
    in
    foldl'
      (acc: e:
        if acc ? ${e.env} then
          (if acc.${e.env} == e.file then acc
           else throw "programs.dsh: secretFile conflict — env '${e.env}' declared with different files (${acc.${e.env}} vs ${e.file}); align the declarations")
        else acc // { ${e.env} = e.file; })
      { }
      entries;

  # ── secret 通道(通用模式,当前消费面 mcpServers)──────────────────
  # 上游实测约束:dsh MCP config.env/headers 是值直存(z.dict(String),无
  # apiKeyEnv 间接层),且子进程 spawn 用 scrubbedParentEnv 擦掉父环境里
  # KEY|PASSWORD|SECRET|TOKEN 名(官方注释:转交凭证"goes through the
  # spec's explicit env")—— 值必须在 config 里。而 profile bundle 是
  # 全局可读 store 工件,密钥值不可 build 期渲染。
  # 方案(同 nixpkgs replace-secret / sops-nix 哲学):store 渲染占位符
  # "@dsh-secret:<path>@",wrapper 启动期对物化副本注入真值 + chmod 600
  # (settingsPrelude 同机时机;轮换安全:每次启动重注,密钥文件更新即生效)
  secretPlaceholder = path: "@dsh-secret:${path}@";
  # 值渲染:string 直存;{ secretFile; prefix? } → 占位符(prefix 拼前;
  # submodule 输出 prefix 恒存在(null),须显式判空而非 `or`)
  renderSecretVal = v:
    if builtins.isString v then { text = v; refs = [ ]; }
    else if v ? secretFile then
      let pre = if v.prefix or null == null then "" else v.prefix; in
      { text = pre + secretPlaceholder (toString v.secretFile); refs = [ (toString v.secretFile) ]; }
    else { text = toString v; refs = [ ]; };
  # attrsOf 值渲染:返回 { data = 同形 attrs;text-only; refs = 去重 refs }
  renderSecretAttrs = attrs:
    let
      rendered = mapAttrs (_: renderSecretVal) attrs;
    in
    {
      data = mapAttrs (_: r: r.text) rendered;
      refs = lib.unique (concatMap (r: r.refs) (attrValues rendered));
    };
in
{
  inherit secretEnvName secretEnv secretPlaceholder renderSecretVal renderSecretAttrs;
}
