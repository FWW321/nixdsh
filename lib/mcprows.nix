# MCP 服务器行(rc.8 dsh-mcp-client 实测):插件不在默认树,每 server
# 一个条目,包裹成 insert 行 —— cordis patch applier 对组合树里不
# 存在的 id 只 warn+skip(实测 cordis-plugin-include:`patch: entry
# not found`,7 行全丢、/mcp 空屏),新条目必须走 insert 通道
# (data.push)。config 判别联合由 transport 定形;null/空省略;
# settings 逃生口最后并。env/headers 值支持 secretFile 形态 →
# 占位符渲染(见 secret.nix renderSecretAttrs),refs 结构化收集给
# wrapper 注入(单一事实源:wrapper 不再重扫行文本)。
# 插件随行:设置 mcpServers 即插入 @deepseek-ai/dsh-mcp-client,
# 无法经 inBoxPlugins 关闭(id 不在树上,disable 行同样 not-found
# 跳过)—— 不装就删 mcpServers 条目。
#
# stdio stderr 收纳:SDK 默认 inherit(stdio.js `?? 'inherit'`)
# → 子进程日志刷终端(TUI 遮挡)。包装 command 为 sh -c,
# stderr 追加到 $XDG_STATE_HOME/deepseek-harness/mcp/<name>.log
# (mkdir -p 幂等;日志保留排查能力)。env/cwd 不受影响(row 级
# 配置作用在 exec 后的真实进程上)。opt-out 走 mcpStderrToLog。
# sh -c 形状:'-c' script <command> <args...> → script 内
# $@ = 原命令+参数,原样 exec。
{ lib, renderSecretAttrs }:

let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    concatStringsSep
    filter
    filterAttrs
    escape
    mapAttrs
    optionalAttrs
    unique
    ;

  # 上游 dsh-mcp-client SERVER_NAME_PATTERN(lib/index.js:549):
  # serverName 进工具名(mcp__<serverName>__<tool>)与行 id(mcp-<name>),
  # 非法名在 boot 期才炸 → 前移到 eval 期(自家 fail-loud 哲学)
  serverNamePattern = "[A-Za-z0-9_-]{1,32}";
in
{
  # { rows; refs; assertion } —— rows = insert 包裹行组(refs 是
  # secret 文件路径清单,wrapper 据此派生占位符)
  mk = { cfg }:
    let
      servers = cfg.mcpServers or { };
      _nameAssert =
        let bad = filter (n: builtins.match serverNamePattern n == null) (attrNames servers); in
        if bad != [ ] then
          throw "programs.dsh.mcpServers: server name(s) ${concatStringsSep ", " bad} must match ^[A-Za-z0-9_-]{1,32}\$ (upstream dsh-mcp-client SERVER_NAME_PATTERN — it rides tool names mcp__<serverName>__<tool> and row id mcp-<name>)"
        else null;
      mcpStderrToLog = cfg.mcpStderrToLog or true;
      stderrWrap = name: m:
        let
          # 日志文件名内插进双引号串,转义 shell 元字符(attr 名常规是
          # 标识符,防御即可;名字已过上面的字符集校验)
          logName = escape [ "$" "\"" "\\" "`" ] name;
          script = ''
            _d="''${XDG_STATE_HOME:-$HOME/.local/state}/deepseek-harness/mcp"
            mkdir -p "$_d"
            exec "$@" 2>>"$_d/${logName}.log"
          '';
        in
        {
          command = "sh";
          # '-c' script $0 cmd args...:$0 占位(sh),命令+参数全在 $@ ——
          # 直接把 cmd 放 $0 位则 exec "$@" 丢命令、把首参数当选项
          args = [ "-c" script "sh" m.command ] ++ (m.args or [ ]);
        };
      renderServer = name: m:
        let
          common = { inherit (m) transport; serverName = name; }
            // (filterAttrs (_: v: v != null && v != { } && v != [ ]) {
              toolCallTimeoutMs = m.toolCallTimeoutMs or null;
              failOnStartupError = m.failOnStartupError or null;
            })
            // (m.settings or { });
          body =
            if m.transport == "stdio" then
              let
                extras = filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                  inherit (m) env;
                  cwd = m.cwd or null;
                };
              in
              if mcpStderrToLog then (stderrWrap name m) // extras
              else extras // (filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                inherit (m) args;
                command = m.command or null;
              })
            else
              filterAttrs (_: v: v != null && v != { } && v != [ ]) {
                url = m.url or null;
                headers = m.headers or { };
              };
        in
        {
          id = "mcp-${name}";
          name = "@deepseek-ai/dsh-mcp-client";
          config = common // body;
        };
      renderedServers = mapAttrs renderServer servers;
      # env/headers 二次渲染为占位符,同时收集 refs(结构化,免文本回扫)
      withSecrets = mapAttrs
        (name: row:
          let
            env' = if row.config ? env then (renderSecretAttrs row.config.env).data else { };
            headers' = if row.config ? headers then (renderSecretAttrs row.config.headers).data else { };
            allRefs =
              (if row.config ? env then (renderSecretAttrs row.config.env).refs else [ ])
              ++ (if row.config ? headers then (renderSecretAttrs row.config.headers).refs else [ ]);
          in
          {
            row = row // {
              config = removeAttrs row.config [ "env" "headers" ]
                // (optionalAttrs (env' != { }) { env = env'; })
                // (optionalAttrs (headers' != { }) { headers = headers'; });
            };
            refs = allRefs;
          })
        renderedServers;
    in
    builtins.seq _nameAssert {
      rows = map (row: { insert = [ row ]; })
        (attrValues (mapAttrs (_: w: w.row) withSecrets));
      refs = unique (concatMap (w: w.refs) (attrValues withSecrets));
    };
}
