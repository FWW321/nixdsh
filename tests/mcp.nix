# MCP 域(nix-unit):行渲染(insert 包裹/判别联合/secret 占位符)、
# secret refs 结构化收集、名校验前移。
# 行为级(secret 注入真跑/stderr 日志/insert 通道真 boot)在 checks/mcp.nix
{
  pkgs,
  dshLib,
  fx,
}:

let
  inherit (fx) applyWith;

  # stderr 收纳包装的标准形(command/args 原样跟随,$0 占位防丢命令)
  stderrScript = name: ''
    _d="${"$"}{XDG_STATE_HOME:-$HOME/.local/state}/deepseek-harness/mcp"
    mkdir -p "$_d"
    exec "$@" 2>>"$_d/${name}.log"
  '';

  fullServer = {
    transport = "stdio";
    args = [ ];
    env = { };
    cwd = null;
    url = null;
    headers = { };
    toolCallTimeoutMs = null;
    failOnStartupError = false;
    settings = { };
  };

  rowsOf = cfg: (applyWith cfg).mcpPatches;
  cfgOf =
    rows:
    builtins.listToAttrs (
      map (x: {
        name = x.id;
        value = x;
      }) (pkgs.lib.flatten (map (x: x.insert or [ ]) rows))
    );

  # 三服务器场景:判别联合全覆盖
  three = rowsOf {
    mcpServers = {
      filesystem = fullServer // {
        command = "/run/current-system/sw/bin/npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/home"
        ];
        settings = {
          reconnect.maxAttempts = 5;
        };
      };
      remote = fullServer // {
        transport = "streamable-http";
        url = "https://mcp.example.com/mcp";
        headers = {
          Authorization.secretFile = "/run/secrets/fake-token";
          Authorization.prefix = "Bearer ";
          X-Plain = "literal";
        };
        command = null;
        toolCallTimeoutMs = 30000;
      };
      gh = fullServer // {
        command = "gh";
        env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh";
      };
    };
  };
  byId = cfgOf three;

  # opt-out:原始 command/args 原样
  fsRaw =
    (cfgOf (rowsOf {
      mcpStderrToLog = false;
      mcpServers.filesystem = fullServer // {
        command = "/run/current-system/sw/bin/npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/home"
        ];
      };
    }))."mcp-filesystem".config;
in
{
  mcp = {
    # 行必须 insert 包裹(patch 形状对树上不存在的 id 只 warn+skip)
    test-rows-insert-wrapped = {
      expr = map (x: builtins.attrNames x) three;
      expected = [
        [ "insert" ]
        [ "insert" ]
        [ "insert" ]
      ];
    };
    # stdio:serverName 派生 / null 字段省略 / settings 逃生口并入 /
    # 默认 sh -c 包装 + 每服务器 stderr 日志
    test-stdio-filesystem = {
      expr = byId."mcp-filesystem".config;
      expected = {
        serverName = "filesystem";
        transport = "stdio";
        command = "sh";
        args = [
          "-c"
          (stderrScript "filesystem")
          "sh"
          "/run/current-system/sw/bin/npx"
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/home"
        ];
        failOnStartupError = false;
        reconnect.maxAttempts = 5;
      };
    };
    # mcpStderrToLog=false → 原始 command/args 形状
    test-stdio-raw-opt-out = {
      expr = fsRaw;
      expected = {
        serverName = "filesystem";
        transport = "stdio";
        command = "/run/current-system/sw/bin/npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/home"
        ];
        failOnStartupError = false;
      };
    };
    # streamable-http:url/headers/超时;secretFile 头渲染 prefix+占位符,
    # 字面头原样;不得携带 stdio 字段
    test-streamable-http = {
      expr = byId."mcp-remote".config;
      expected = {
        serverName = "remote";
        transport = "streamable-http";
        url = "https://mcp.example.com/mcp";
        headers = {
          Authorization = "Bearer @dsh-secret:/run/secrets/fake-token@";
          X-Plain = "literal";
        };
        toolCallTimeoutMs = 30000;
        failOnStartupError = false;
      };
    };
    # secretFile env 渲染裸占位符
    test-stdio-env-placeholder = {
      expr = byId."mcp-gh".config.env;
      expected = {
        GITHUB_PERSONAL_ACCESS_TOKEN = "@dsh-secret:/run/secrets/fake-gh@";
      };
    };
    # refs 去重收集
    test-refs-dedupe = {
      expr =
        (applyWith {
          mcpServers.gh = fullServer // {
            command = "gh";
            env.GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh";
          };
        }).mcpSecretRefs;
      expected = [ "/run/secrets/fake-gh" ];
    };
    # 同一 server 多 secret 的结构化收集(A5 回归:文本回扫时代贪婪正则
    # 每行只收一个)
    test-refs-multi-secrets = {
      expr =
        (applyWith {
          mcpServers.gh = fullServer // {
            command = "gh";
            env = {
              GITHUB_PERSONAL_ACCESS_TOKEN.secretFile = "/run/secrets/fake-gh";
              OTHER_TOKEN.secretFile = "/run/secrets/fake-other";
            };
          };
        }).mcpSecretRefs;
      expected = [
        "/run/secrets/fake-gh"
        "/run/secrets/fake-other"
      ];
    };
    # 名校验负例(B12:上游 SERVER_NAME_PATTERN ^[A-Za-z0-9_-]{1,32}$ 前移)
    test-name-validation = {
      expr = applyWith {
        mcpServers."bad name!".command = "x";
      };
      expectedError.type = "ThrownError";
    };
  };
}
