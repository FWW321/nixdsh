# nixdsh

[DeepSeek Harness (dsh)](https://github.com/deepseek-ai/deepseek-harness) 的 Nix 打包与 **nixvim 式声明配置**:profile 即 derivation,插件即 option。

> 设计基座取自社区精华并按 Nix 原语重组:
> 打包纪律来自 [NixOS/nixpkgs#552467](https://github.com/NixOS/nixpkgs/pull/552467),
> profile-as-store-path 模型来自 [Samuka007/dsh-nix](https://github.com/Samuka007/dsh-nix),
> yq-merge 声明式 settings 与共享 options 双模块来自 [TonyWu20/deepseek-harness-flake](https://github.com/TonyWu20/deepseek-harness-flake),
> dshPlugins 集合机制是 nixpkgs `vimPlugins` 的个人规模 transpose。

设计裁决、上游源码实证与调研结论见 [docs/internals.md](docs/internals.md);
上游插件机制调研见 [docs/deepseek-harness-plugin-research.md](docs/deepseek-harness-plugin-research.md)。

## 快速开始

```nix
# flake.nix
inputs.nixdsh.url = "github:FWW321/nixdsh";

# NixOS: overlay 提供 pkgs.dsh / pkgs.dshPlugins
nixpkgs.overlays = [ inputs.nixdsh.overlays.default ];
# Home Manager: 挂模块
home-manager.sharedModules = [ inputs.nixdsh.homeManagerModules.dsh ];
```

```nix
# 任意 HM 配置
programs.dsh = {
  enable = true;
  defaultProfile = "headless";
  settings.models.provider = "deepseek";
  web.enable = true;              # 常驻 dsh web(127.0.0.1:3080,systemd user)

  profiles.web.plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  profiles.headless.plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-headless" ];
};
```

```sh
nix profile install github:FWW321/nixdsh   # 或仅 CLI
nix run github:FWW321/nixdsh#dsh -- web    # 试试
```

## 核心概念

1. **profile = derivation**。`profiles.<name>` 声明插件组合,构建为不可变
   store 工件,activation 以 stamp 比对物化到 `$DSH_HOME/profiles/<name>`
   可写副本(dsh boot 会改写 profile 根 cordis.yml,故物化副本而非 symlink)。
2. **settings = 声明优先、运行时兼容**。wrapper 每次启动用 yq 把声明值
   merge 进 settings.yaml:声明键覆盖同名,本地键保留 —— Web UI 的运行时
   改动不被抹掉。
3. **插件配置 = cordis patch 用户层**。dsh 官方优先级链:
   base insert → mode bundle → **profile cordis.patch.yml(这里)** → --patch。
   注意 patch 的 config 是**整行替换**不是深合并,覆盖 base 行须重述全部键。
4. **profile 数量 = 交互面数量(与插件数无关)**。dsh 的交互面 bundle
   (web-app/headless/第三方 TUI)两两互斥 —— 同树声明会
   `duplicate loader entry id` 直接拒绝 boot。因此:

   | 轴 | 选项 | 增长方式 | 是否产生 profile |
   |---|---|---|---|
   | 供应商/模型/条目开关 | `providers` / `defaultModel` / `inBoxPlugins` | 全局一处 | 否 |
   | 功能插件 | `plugins.<name>` | `enable = true`(`profiles = []` 缺省全分发) | 否 |
   | 交互面 | `plugins.<name>.face = "<名>"` | 每种 UI 入口一个(有界) | 是(自动生成) |

   交互面 profile 的最终树 = base 全套行 + 该 face 树叠层(三 face 实测
   一致:`web = [dsh-base, dsh-web-app]`、`headless = [dsh-base,
   dsh-headless]`、`tui = [dsh-base, dsh-tui]`)。加功能插件 = 一处
   `enable`,零新增;加交互面 = 一处 `plugins.<name>.enable = true`
   (registry 收录的插件 source/face 均可省),自动生成 profile 树与
   子命令入口 `dsh <face>` —— [base+face] 配方由模块一次编码,用户
   无从写错。显式 `profiles.*` 保留为全权逃生口(自定义层序/patch)。

## LLM 供应商

`programs.dsh.providers` 声明多供应商路由,渲染进 settings.yaml 的
`llm-pi-ai` 命名空间段(免重启生效)。catalog 路由只补凭证名;catalog
没有的端点(如 zhipu coding plan 的 anthropic 兼容层)手声明全字段:

```nix
programs.dsh.providers = {
  deepseek.apiKeyEnv = "DEEPSEEK_API_KEY";    # catalog 路由

  "zhipu-coding-plan" = {                     # 手声明路由
    apiKeyEnv = "ZHIPU_API_KEY";
    api = "anthropic-messages";
    baseURL = "https://open.bigmodel.cn/api/anthropic";
    models = [
      { id = "glm-5.3"; contextWindow = 1000000; maxTokens = 131072; }
      { id = "glm-5v-turbo"; input = [ "text" "image" ]; }   # 多模态声明
      { id = "glm-5.2"; reasoningEfforts.off = null; reasoningEfforts.high = "high"; }
    ];
  };
};
```

凭证值经环境变量注入(`environment` / `home.sessionVariables` / sops),
wrapper 不落盘密钥。api 取值:`openai-completions` / `openai-responses` /
`anthropic-messages`;models 整表替换 catalog,modelOverrides 逐模型覆盖。

模型条目常用键:`id`/`name`/`contextWindow`(compaction 触发线)/
`maxTokens`(每请求输出上限)/`input`(输入模态 —— 低报 = 附件期早拒,
高报 = provider 中途拒且会话卡死,**宁可低报**)/`reasoningEfforts`
(`false` 或 `{档位: wire 拼写}`,仅 off 可空值)。未 typed 的未来字段
裸透传,typo 由上游严格 schema 在 settings 载入期拒(点名路由/模型)。

## 交互面与入口

单一 `dsh` wrapper:profile 子命令分发 `dsh <profile>` ≡
`dsh --profile <profile>`(手写 profiles 与自动 face 同权;`web` 走上游
原生子命令)。不生成 per-profile wrapper —— 短命令需求由 shell alias 承担。

**交互树只能由 face 插件生成**(强一致:`plugins.dsh-tui` 的选项永不
失焦、enable/disable 即树的存在/消失);手写 `profiles.<name>` 是非交互
组合的通道。变体交互树不需要手写:

```nix
# 第二棵 web 树:同 bundle 不同名,零手写 profile
plugins."web-dev" = {
  source = "@deepseek-ai/dsh-web-app";
  face = "web-dev";                # → dsh web-dev 子命令
};
```

`programs.dsh.web.enable` 的 systemd 服务 = 常驻 web face 进程
(127.0.0.1:3080)。**没有共享守护进程**:每个 face boot 一棵独立完整
的树,TUI 不能"连接"web 服务;共享层是文件系统(`$DSH_HOME`)——
web 服务与 `dsh tui` 并行运行是预期用法。

**默认 preset**(新会话装载哪个 agent 组合):

```nix
plugins.dsh-tui.defaultPreset = "liangshen";    # tui 树(插件托管,零声明发现)
programs.dsh.defaultPreset = "custom-standard"; # 其余树兜底(再缺省 standard)
```

值进 face 树 `agent-presets-nix` 行的 `config.default`。手写/拼写错的
id 求值期 throw 并列出全集;shipped fork 用
`presets.<id>.source = nixdsh.lib.shippedPreset pkgs "standard";` 换名接管。

**权限模式**(新会话默认):

```nix
programs.dsh.permissionMode = "workspace-write";           # 全局兜底
programs.dsh.plugins.dsh-tui.permissionMode = "read-only"; # per-face 胜
```

`read-only` 会同步补进 permission 表(上游默认只有两条 preset)。
两个 caveat:① UI 里手选过"新会话默认权限"后,该运行时值恒胜本
选项(UI 改回即恢复);② subagent child 的权限在委托边界一次性固定
(approval 钉死 never)—— per-face permissionMode 自动覆盖该树全部后代。

**stderr 过滤(wrapper 拥有的层)**:dsh-tui 启动期对每个版本错位的
peer 打一条 `upstream drift` 警告(无开关)。宿主与 tui 同批升级时零行;
错位过渡窗会整屏刷屏,wrapper 滤掉该模式兜底。要看原始警告直跑 store
里的 `bin/dsh`(绕过 wrapper)。版本串对齐时此过滤自然空转。

## 网页搜索

`webSearch` 是**能力开关 + provider 选择器二合一**(唯一自由度:provider
是谁)。选中才启用,未选中后端零行。**默认 `null`**:三 face 的
`web_search` 工具默认不注册 —— 需要搜索写一行找回:

```nix
# DeepSeek 原生搜索(base 自带后端:零配置,key 走 export
# DEEPSEEK_API_KEY 或 Web UI 运行时配;无 key 每次搜索必败)
programs.dsh.webSearch = "deepseek-official";
programs.dsh.webSearchProviders."deepseek-official".maxUses = 3;  # 可选

# Exa(社区包 @tonydua/dsh-web-search-exa,registry 收录;无 key 走
# mcp.exa.ai 匿名兜底零配置可用,有 key 走 REST)
programs.dsh.webSearch = "exa";
programs.dsh.webSearchProviders.exa = {
  row = {                                # 完整声明 = 非 base 自带后端
    name = "@tonydua/dsh-web-search-exa";          # cordis 包名
    config.apiKeyEnv = "EXA_API_KEY";              # 行引导配置
  };
  settings.numResults = 5;               # 该后端 settings 段参数(热生效)
};

# 任意私有/新后端:同一条声明语法(row.name 换成你的包)
# 切换后端 = 改一个字符串(两边声明都在,备案待命)
```

注册表是开放的:新后端一条声明接入,零 nixdsh 改动。声明含 secretFile
的见「密钥与凭证」。

## 网页抓取

`webFetch` 与 webSearch 同构(fetch 缝选择器),差异:fetch 缝无 base
自带后端(选中必声明),且模型面 `web_fetch` 工具默认有 `fetch: false`
保险丝 —— 选中即自动打开(打开动作本身即"信任该 provider 的 SSRF
姿态"的显式声明;上游把 SSRF 防护责任交给 provider,选远端 reader 型
provider 如 Zhipu web_reader 则无本机抓取面):

```nix
programs.dsh.webFetch = "zhipu";
programs.dsh.webFetchProviders.zhipu.row = {
  name = "@fww/dsh-web-fetch-zhipu";
  secretFile = "/run/secrets/zhipu_api_key";  # 派生 apiKeyEnv,同 env 同
  # 文件自动去重(一个 ZHIPU_API_KEY 喂搜索+抓取+LLM 路由)
};
```

选中后 fetch 能力自动穿透全部 agent preset(含 shipped —— 经 farm
重放,见 docs/internals「roster 接管」)。

## MCP 服务器

`mcpServers` 声明即启用(每 server 一行 insert 进所有 profile),工具
暴露为 `mcp__<serverName>__<tool>`:

```nix
programs.dsh.mcpServers = {
  github = {
    transport = "streamable-http";
    url = "https://api.githubcopilot.com/mcp/";
    headers.Authorization = {                   # 值 = 字面串,或 secret 形态
      secretFile = "/run/secrets/github_pat";
      prefix = "Bearer ";
    };
  };
  context7 = {
    command = "${pkgs.context7-mcp}/bin/context7-mcp";   # stdio(缺省)
    env.API_KEY.secretFile = "/run/secrets/context7_key";
    failOnStartupError = false;                # 连接失败跳过该 server 继续
  };
};
```

密钥渲染为占位符(store 工件零密钥),wrapper 启动期注入真值到物化
patch(0600);服务器名须匹配上游规则(`^[A-Za-z0-9_-]{1,32}$`,
求值期校验)。

## agent 预设

预设 = 一个会话 Agent 的插件组装(工具/提示词/能力),目录含
`agent.cordis.yml` 组合树(+ 可选 `preset.yml` 元数据)—— 纯文件零
构建,上游热发现(运行中新增免重启)。

```nix
programs.dsh.presets.liangshen-custom.source = ./presets/liangshen-custom;
```

- 声明的 preset 进 farm(roster 根,**零 activation 物化**,store 只读)
- **插件托管的 preset 零声明**:`plugins.dsh-tui.enable` 即自动发现
  接管(如 liangshen),随插件生命周期;撞名显式胜;`excludedPresets`
  = **彻底移除**(构建期从插件源物理剥离 —— farm 无从接管、dsh-tui
  的播种器无从种出、菜单不可见不可选;user 根已播种的历史副本需
  一次性手动删除,删后不再生);全禁接管但保留上游播种原件用
  `plugins.<name>.presets = false`
- **import 工作流**:TUI 创造模式做原型(`~/.config/deepseek-harness/
  .agent-presets/<名>`,user 根热发现)→ `cp -r` 进 config 仓库 → 声明
- **勿导入插件 shipped 的预设**(辨别:副本目录里有
  `.dsh-tui-managed.json` 即插件管理的同步物);shipped 无需任何声明

`dsh-presets` 命令列出全部 preset 及归属(replayed = shipped 重放 /
declared = 显式 / discovered = 插件托管),`--live` 比对各树 roster
是否指向当前 farm,`--tree <face>` 单树诊断。

能力行(webFetch 等)如何穿透 preset 层、farm 重放机制与上游四条
分化通道的实证,见 docs/internals「roster 接管与能力行重放」。

## subagent 实例

```nix
programs.dsh.subagents = {
  researcher = {                                    # attr 名 = 实例名
    enable = true;
    backgroundMode = "continuable";                 # one-shot(缺省)| continuable
    agentOptions = {                                # child 模型路由(全可省 = 继承父)
      provider = "zai-coding-cn";
      model = "glm-5.3";
    };
    toolFilter.deny = [ "web_fetch" ];
    # toolName 缺省派生 "subagent_researcher";persona/maxDepth/
    # enableRunInBackground 见 options
  };
};
```

每个实例渲染一行 `dsh-tool-subagent` 进宿主 global 层(新 toolName 不
与 preset 遮蔽,**无需 preset 重放**)。spawn = 全新 child 空会话;
fork = 种入父已完成 turn 前缀。求值期查重(toolName 撞实例/全局名)。
启用 shipped 禁用行(`subagent_claude_code`/`subagent_codex`)走
`presets.<id>.patches` 逃生口,不归本面管 —— 机制见 docs/internals
「subagent 机制调研」。

## 装插件

**方式 A:进 registry(常用插件,nixvim 式零样板)**

```sh
echo "AKS1st/dsh-sysmon" >> plugins/names.txt   # nixdsh 仓库
nix run .#dsh-plugins-update                     # 解析 tag/hash,重生成 generated.nix
git commit -am "dshPlugins: +sysmon"
```

每周 workflow 自动开 bump PR(人审合并)。使用方 `nix flake update nixdsh` 拉取。

**方式 B:通用层直接声明(任意插件,无需 module)**

```nix
programs.dsh.plugins.dsh-sysmon = {          # registry 收录 → source 免声明(键名尾缀反查)
  enable = true;
  patchId = "dsh-sysmon";                    # settings 渲染为 { id; config; } patch 行
  settings = { position = "bottom-right"; }; # 整行替换语义!
  profiles = [ "web" ];                      # 空 = 所有 profile
};
# 不在 registry:source = pkgs.fetchFromGitHub { ... }; (名字任意)
```

**方式 C:typed module(nixvim modules/plugins 同构,最舒适)**

```nix
# 消费方 import inputs.nixdsh.homeManagerModules.dsh-status-rotator 后:
programs.dsh.status-rotator = {
  enable = true;
  profiles = [ "web" ];
};
```

> module system 硬约束:attrsOf submodule 不支持外部模块向
> `plugins.<name>` 追加 options。typed module 挂在独立短路径
> `programs.dsh.<短名>`,由 config 块回填通用层。给新插件写 typed
> module 时照抄 `plugins-modules/status-rotator.nix` 的骨架即可。

**手写 patch 行(用户层直写,适合一次性覆盖)**

```nix
profiles.web.userPatches = [
  { id = "system-prompt"; config.persona = "You are..."; }
  { id = "hmr"; disabled = true; }
];
# !!js 表达式等复杂 YAML:userPatchesFile = ./web-patches.yml;
```

**非 Nix 逃生口**:`dsh plugin --profile web add <pkg>` 在物化的可写
profile 副本里用 pnpm 装 —— 偏离声明式,下次 profile stamp 变化时被
重置。私有 config.json 类插件(如 status-rotator)运行时写插件目录会因
store 只读失败,插件自身回退默认;确需改其配置时用此逃生口。

## 密钥与凭证

**env 型凭证(llm 路由、webSearch/webFetch 后端)—— 全程零明文**:

`providers.<id>.secretFile` / `webSearchProviders.<id>.row.secretFile` /
`webFetchProviders.<id>.row.secretFile` 声明后,wrapper 每次启动现读文件
export —— 密钥来源与消费者同处一行,CLI/TUI/headless/web 服务统一入口:

- env 名 = 显式 `apiKeyEnv` > **文件名大写约定**
  (`/run/secrets/zhipu_api_key` → `ZHIPU_API_KEY`)
- 同 env 多声明:同文件去重(一个 ZHIPU_API_KEY 喂 LLM 路由 + 搜索 +
  抓取),不同文件 → 求值期 throw(配置漂移)
- 文件缺失 → 不 export,provider 按请求报结构化错误
- 轮换即生效:每次调用现读,优于 EnvironmentFile 的启动快照

**MCP headers/env 型凭证 —— store 零密钥,物化层明文**:
占位符进 store 工件(world-readable 无密可泄),activation 注入真值到
`~/.config/deepseek-harness/profiles/<name>/cordis.patch.yml`(0600)。
上游 mcp 行 schema 是字面量 map 无 env 间接引用,这是当前最优解
(同 sops-nix 物化哲学);轮换 = 改 /run/secrets 源 → 重建,无残留。

## stdio MCP 子进程 stderr 收纳

上游 mcp-client 不传 SDK 的 `stderr` 选项 → stdio server 的启动日志
直通终端,TUI 里刷屏遮挡。nixdsh 渲染期默认把 stdio server 的
`command` 包成
`sh -c '… exec "$@" 2>>$XDG_STATE_HOME/deepseek-harness/mcp/<name>.log'`
(`mcpStderrToLog`,默认 true):日志保留排查能力、终端干净;`false`
恢复原始形状。env/cwd 语义不变。

## 已知限制

- **Web Plugins 页的表单卡是上游硬编码**:第三方 provider(exa 的
  `web-search-exa` 段)装了 settings 命名空间也不会有表单卡;声明侧
  settings 段照常渲染(yq merge 热改),运行时改值走 host settings
  scope API。动态表单需上游做,可提 issue
- **web/tui face 上"禁搜索工具"意图部分丢失**:preset 层挂独立
  tool-web,宿主 patch 够不着 —— `webSearch = null` 禁的是宿主三行,
  preset 漏网的 `web_search` 工具卡留在 UI、schema token 照吃(调用
  报结构化错误)。headless 全净。根治需上游(preset 级裁剪配置化)
- **会话事件是封闭集**:仓库外插件写自定义事件会毒化会话日志(读端
  拒读整份日志)—— 上游 by design;手术手册见 docs/internals
- bundle store 路径变化已被 dsh-web 服务指纹覆盖(路径变 → unit 变 →
  HM 自动重启服务,无需手动)

## API 一览

| Flake output | 内容 |
|---|---|
| `packages.<sys>.dsh` | CLI 包(全验证) |
| `overlays.default` | `pkgs.dsh` + `pkgs.dshPlugins` |
| `homeManagerModules.dsh` | `programs.dsh` 模块 |
| `nixosModules.dsh` | 薄 NixOS 模块 |
| `checks` | profile 模型验证(结构/正例/负例 fail-loud) |
| `checks.<sys>.dsh-options-doc` | 114 option 参考文档,description 真源自动渲染:`nix build .#checks.x86_64-linux.dsh-options-doc` → `options.md` / `options.json`(声明链接指向本仓 GitHub) |
| `apps.<sys>.dsh-plugins-update` | 插件集合更新器 |
| `lib.mkDsh` | 独立实例化(不依赖 HM/NixOS) |

`lib.mkDsh` 用法(nixvim 的 `mkNixvim` 同构):

```nix
dshLib.mkDsh {
  inherit pkgs;
  modules = [ ./my-settings.nix ./my-profiles.nix ];
} # → { wrapper; profileBundles; config; options; }
```

## config 侧分文件惯例(消费方示例)

```
users/me/dsh/
├── default.nix     # enable + defaultProfile + web 服务 + imports
├── settings.nix    # settings/telemetry
├── subagents.nix   # subagents 实例表(可选)
└── profiles/
    ├── default.nix # imports
    ├── web.nix     # web profile(含插件声明)
    └── headless.nix
```

## 维护

- `nix flake check` — profile 模型 + 包验证
- bump dsh:改 `package.nix` 的 rev/hash + pnpmDepsHash + `upstreamVersion`
  (注释里有流程),再重算 `checks/npm-oracle.nix` 的 tarball hash;
  `nix flake check` 过 oracle = 物化循环与上游 publish 仍然一致
- bump 插件:合并每周 PR,或手动 `nix run .#dsh-plugins-update`
- 深入阅读:[docs/internals.md](docs/internals.md)(设计准则/上游实证/
  手术手册)、[docs/deepseek-harness-plugin-research.md](docs/deepseek-harness-plugin-research.md)
