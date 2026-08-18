# LLM 适配器缝(llm-deepseek / llm-pi-ai 三态 typed 选项的行组与断言):
#   llmDeepseek  null → llm-deepseek 禁行(DEFAULT_MODELS catalog 无条件
#               注册,无 key 即模型选择器死条目);attrs → settings 段
#               (settings.nix 渲染,无行)
#   providers    null → llm-pi-ai 禁行;attrs → settings 段
# 断言家族:typed 启用 × inBox 禁同组行 / typed 禁用 × settings 声明 /
# typed 禁用 × defaultModel 指向它 —— 全部 eval 期 fail-loud。
# 注意:defaultModel.provider 无法 eval 期判 pi-ai 归属(pi-ai catalog
# 路由名与 llm-deepseek id "deepseek-official" 无先验区分,不猜)——
# 唯一可靠例外是 deepseek-official(llm-deepseek 固定 id)。
{ lib }:

let
  inherit (lib) findFirst;
in
{
  mk = { cfg }:
    let
      dshNull = (cfg.llmDeepseek or null) == null;
      # 缺省语义:键缺失(stub cfg)与 {}(显式启用零配置)等价 —— 均
      # 不出禁行;只有显式 null 才禁(`or {}` 而非 `or null`)
      piAiNull = (cfg.providers or { }) == null;
      inbox = id: (cfg.inBoxPlugins or { }).${id} or { enable = null; };
      rows =
        lib.optional (dshNull) { id = "llm-deepseek"; disabled = true; }
        ++ lib.optional (piAiNull) { id = "llm-pi-ai"; disabled = true; };
      violations = [
        {
          cond = !dshNull && (inbox "llm-deepseek").enable == false;
          msg = "programs.dsh: llmDeepseek is set but inBoxPlugins.\"llm-deepseek\".enable = false — use llmDeepseek alone (null disables the row)";
        }
        {
          cond = piAiNull && (inbox "llm-pi-ai").enable == false;
          msg = "programs.dsh: providers = null but inBoxPlugins.\"llm-pi-ai\".enable = false is redundant — providers = null already disables the row";
        }
        {
          cond = piAiNull && (cfg.settings or { }) ? "llm-pi-ai";
          msg = "programs.dsh: providers = null but settings.\"llm-pi-ai\" is declared (or defaultModel routes through pi-ai) — a disabled adapter cannot consume them; set providers = {} or drop the declarations";
        }
        {
          cond = dshNull && (cfg.defaultModel or null) != null
            && cfg.defaultModel.provider == "deepseek-official";
          msg = "programs.dsh: llmDeepseek = null but defaultModel.provider = \"deepseek-official\" — the default route points at a disabled adapter; enable llmDeepseek or re-route defaultModel";
        }
      ];
      first = findFirst (v: v.cond) null violations;
      assertion = if first != null then throw first.msg else null;
    in
    builtins.seq assertion { inherit rows; };
}
