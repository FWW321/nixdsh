# 权限模式行组(新会话默认;宿主组合层,per-face 物理成立):
#   三行同步一致(sandbox-policy.mode / approval.policy /
#   permission.defaultPreset + presets),knobs 不匹配任何 preset →
#   上游推断 "custom" → throw(dsh-permission-presets :116)。
#
# 整行重述纪律在此的两处应用:
#   sandbox-policy 行重述 workspaceRoot(base 值 !!js process.cwd();
#   之前只写 mode,靠服务构造器 ?? process.cwd() 兜底碰巧同值 ——
#   上游一改兜底即断,现以 rawYaml 与 base 行同构重述)
#   permission 行恒带整张 presets 表(base 行三键镜像,含 read-only)。
#   presets 是 z.dict 整表替换语义:只带 defaultPreset 会把表打回
#   服务默认两条 → 运行期切 read-only 显示 custom(此前非 read-only
#   分支正是如此)。表条目只镜像负载键(sandbox/approval,上游常量,
#   漂移即上游语义变化,check 兜底),name/description 是 UI 文案且
#   base 行本就不带 —— 不镜像,缩 drift 面。
#
# 与 defaultPreset 的 settings 协调不同:permission 的 settings 命名
# 空间是 UI 手选的运行时用户层,nixdsh 不写也不清 —— 行 config 是
# 组合层基底,UI 手选后遮蔽本选项(caveat 入文档)。
{ lib, rawYaml }:

let
  # base 行 permission.presets 的三键镜像(rc.7 dsh-base cordis.patch.yml;
  # read-only 在 base 行中在场,服务 Config 默认表反而只有两条 ——
  # 整表重述必须以 base 行为准)
  presetsTable = {
    "workspace-write" = {
      sandbox = "workspace-write";
      approval = "ask";
    };
    "danger-full-access" = {
      sandbox = "danger-full-access";
      approval = "never";
    };
    "read-only" = {
      sandbox = "read-only";
      approval = "ask";
    };
  };
in
{
  inherit presetsTable;

  # mode → 三行(恒整表;mode ∈ enum 由 options 层保证)
  rowsFor = mode: [
    {
      id = "sandbox-policy";
      config = {
        inherit mode;
        workspaceRoot = rawYaml "!!js process.cwd()";
      };
    }
    {
      id = "approval";
      config.policy = if mode == "danger-full-access" then "never" else "ask";
    }
    {
      id = "permission";
      config = {
        defaultPreset = mode;
        presets = presetsTable;
      };
    }
  ];
}
