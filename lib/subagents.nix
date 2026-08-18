# subagent 委托实例(subagents.<name> → dsh-tool-subagent 行):
# 新行 id 不在树上 → insert 通道(同 MCP;裸 patch 只会 warn+skip)。
# 行落宿主组合层 global 层:preset 会话经 dsh-tools view() 的
# global 基底看到新 toolName(只遮蔽同名),故不进 buildPreset
# rows —— 与 web 缝的同 id 遮蔽需 preset 重放的根因不同。
# child 组合/权限固定见 docs/internals.md「subagent 机制调研」。
# assert 单独出口:结果集 WHNF(顶层 seq 链)即炸,不依赖行被消费。
{ lib }:

let
  inherit (lib)
    attrNames
    concatStringsSep
    elem
    filter
    filterAttrs
    flatten
    mapAttrsToList
    optionalAttrs
    ;
in
{
  mk = { cfg }:
    let
      entries = filterAttrs (_: p: p.enable or false) (cfg.subagents or { });
      toolNameOf = name: p: p.toolName or "subagent_${name}";
      # 工具名查重(实例间 + base 全局名/控制工具):撞名 = 上游
      # boot 期 "already registered"(上游 TODO 已认晚期),前移到
      # eval 期。control 工具(send_message 等)是全局注册,同样在
      # global 层冲突
      reservedToolNames = [
        "subagent" "subagent_fork"
        "send_message" "interrupt_agent" "list_agents" "report"
      ];
      names = mapAttrsToList toolNameOf entries;
      dupNames = filter (n: builtins.length (filter (m: m == n) names) > 1)
        (lib.unique names);
      reservedHit = filter (n: elem n reservedToolNames) names;
      # 生成行 id 撞 base 既有 id(attr 名 "fork"/"" → tool-subagent-fork
      # /tool-subagent)→ insert 出重复 id,entryMap 混乱
      idClash = filter (name: elem name [ "fork" "" ]) (attrNames entries);
      # agentOptions/toolFilter 空值过滤后渲染(全空省略整键);
      # `or` 缺省:裸 attrs fixture 不走 module system 无 default
      agentOpts = p:
        let ao = p.agentOptions or null; in
        if ao == null then { }
        else filterAttrs (_: v: v != null) {
          provider = ao.provider or null;
          model = ao.model or null;
          maxTokens = ao.maxTokens or null;
        };
      filterOpts = p:
        let
          tf = p.toolFilter or null;
          allow = if tf == null then [ ] else tf.allow or [ ];
          deny = if tf == null then [ ] else tf.deny or [ ];
        in
        (optionalAttrs (allow != [ ]) { inherit allow; })
        // (optionalAttrs (deny != [ ]) { inherit deny; });
      assertion =
        if idClash != [ ] then
          throw "programs.dsh.subagents: instance name(s) ${concatStringsSep ", " idClash} would generate row ids clashing with base tree rows (tool-subagent/tool-subagent-fork); pick another name"
        else if dupNames != [ ] then
          throw "programs.dsh.subagents: duplicate toolName(s) ${concatStringsSep ", " dupNames} across instances — the model-facing name registers once per tool layer"
        else if reservedHit != [ ] then
          throw "programs.dsh.subagents: toolName(s) ${concatStringsSep ", " reservedHit} collide with base/global control tools (subagent, subagent_fork, send_message, interrupt_agent, list_agents, report); override toolName explicitly"
        else null;
      rows = mapAttrsToList
        (name: p: {
          insert = [({
            id = "tool-subagent-${name}";
            name = "@deepseek-ai/dsh-tool-subagent";
            config = {
              provider = p.provider or "spawn";
              toolName = toolNameOf name p;
            }
            // (optionalAttrs ((p.backgroundMode or null) != null) { backgroundMode = p.backgroundMode; })
            // (optionalAttrs ((p.enableRunInBackground or null) != null) { enableRunInBackground = p.enableRunInBackground; })
            // (optionalAttrs (agentOpts p != { }) { agentOptions = agentOpts p; })
            // (optionalAttrs ((p.persona or null) != null) { persona = p.persona; })
            // (optionalAttrs (filterOpts p != { }) { toolFilter = filterOpts p; })
            // (optionalAttrs ((p.maxDepth or null) != null) { maxDepth = p.maxDepth; });
          }) ];
        })
        entries;
    in
    { inherit assertion rows; };
}
