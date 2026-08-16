# nixdsh

[DeepSeek Harness (dsh)](https://github.com/deepseek-ai/deepseek-harness) 的 Nix 打包与 **nixvim 式声明配置**:profile 即 derivation,插件即 option。

> 设计基座取自社区精华并按 Nix 原语重组:
> 打包纪律来自 [NixOS/nixpkgs#552467](https://github.com/NixOS/nixpkgs/pull/552467),
> profile-as-store-path 模型来自 [Samuka007/dsh-nix](https://github.com/Samuka007/dsh-nix),
> yq-merge 声明式 settings 与共享 options 双模块来自 [TonyWu20/deepseek-harness-flake](https://github.com/TonyWu20/deepseek-harness-flake),
> dshPlugins 集合机制是 nixpkgs `vimPlugins` 的个人规模 transpose。

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

### LLM 供应商

`programs.dsh.providers` 声明多供应商路由,渲染进 settings.yaml 的
`llm-pi-ai` 命名空间段(dsh-llm-pi-ai 用户层,免重启生效)。catalog 路由
只补凭证名,端点/模型清单由上游 pi-ai catalog 持有;catalog 没有的端点
(如 zhipu coding plan 的 anthropic 兼容层)手声明全字段:

```nix
programs.dsh.providers = {
  deepseek.apiKeyEnv = "DEEPSEEK_API_KEY";    # catalog 路由

  "zhipu-coding-plan" = {                     # 手声明路由
    apiKeyEnv = "ZHIPU_API_KEY";
    api = "anthropic-messages";
    baseURL = "https://open.bigmodel.cn/api/anthropic";
    models = [ { id = "glm-4.7"; contextWindow = 200000; maxTokens = 128000; } ];
  };
};
```

凭证值经环境变量注入(`environment` / `home.sessionVariables` / sops),
wrapper 不落盘密钥。api 取值:`openai-completions` / `openai-responses` /
`anthropic-messages`;models 整表替换 catalog,modelOverrides 逐模型覆盖。


```sh
nix profile install github:FWW321/nixdsh   # 或仅 CLI
nix run github:FWW321/nixdsh#dsh -- web    # 试试
```

## 架构

```
nixdsh/
├── package.nix        # dsh CLI:nixpkgs#552467 基座(rc.5 源码 + 上游 lockfile
│                      #   + pnpm deploy 最小闭包 + 全套 installCheck:
│                      #   boot web/HTTP 探针、真 PTY、koffi/sharp、Landlock、
│                      #   坏链接与 build 路径泄漏扫描)
├── lib.nix            # 核心纯函数库:
│                      #   mkPlugin/mkProfile/buildProfile  profile→不可变 store 工件
│                      #   applyPlugins                     typed 插件层→profile 增量
│                      #   renderWrapper                    yq-merge settings + profile 注入
│                      #   mkDsh                            nixvim 的 mkNixvim 同构独立实例化
├── modules/options.nix# programs.dsh 共享 options(HM/NixOS/mkDsh 三方消费)
├── hm-module.nix      # HM 消费面:wrapper(子命令分发) + activation 物化 + systemd user 服务
├── nixos-module.nix   # 薄 NixOS 消费面(systemPackages)
├── checks.nix         # profile 模型验证:结构/正例/负例 fail-loud
├── plugins/           # dshPlugins 集合(vimPlugins 同构):
│   ├── names.txt      #   手动清单 owner/repo [subpath](= vim-plugin-names)
│   ├── update.sh      #   updater:tag 优先/HEAD 回退 + prefetch + 元数据物化
│   ├── generated.nix  #   机器生成,勿手改
│   └── overlay.nix    #   → pkgs.dshPlugins.<packageName>
└── plugins-modules/   # per-plugin typed module(按需,nixvim modules/plugins 同构)
```

### 语义模型(三层)

1. **profile = derivation**。`profiles.<name>` 声明插件组合,构建为不可变
   store 工件(package.json bundles 层序 + node_modules symlink + cordis.patch.yml),
   activation 以 stamp 比对物化到 `$DSH_HOME/profiles/<name>` 可写副本
   (dsh boot 会改写 profile 根 cordis.yml,故物化副本而非 symlink)。
2. **settings = 声明优先、运行时兼容**。wrapper 每次启动用 yq 把声明值
   merge 进 settings.yaml:声明键覆盖同名,本地键保留 —— dsh Web UI 的
   运行时改动不被抹掉(纯渲染只读方案会被 dsh 自修改行为击溃)。
3. **插件配置 = cordis patch 用户层**。dsh 官方优先级链:
   base insert → mode bundle → **profile cordis.patch.yml(这里)** → --patch。
   注意 patch 的 config 是**整行替换**不是深合并,覆盖 base 行须重述全部键。
4. **profile 数量 = 交互面数量(与插件数无关)**。dsh 的交互面 bundle
   (web-app/headless/第三方 TUI)两两互斥 —— 同树声明会 `duplicate
   loader entry id` 直接拒绝 boot;TTY-bound 的 TUI 混入 headless 树则
   `dsh "task"` 全挂(实测)。因此:

    | 轴 | 选项 | 增长方式 | 是否产生 profile |
    |---|---|---|---|
    | 供应商/模型/条目开关 | `providers` / `defaultModel` / `inBoxPlugins` | 全局一处 | 否 |
    | 功能插件 | `plugins.<name>` | `enable = true`(`profiles = []` 缺省全分发) | 否 |
    | 交互面 | `plugins.<name>.face = "<名>"` | 每种 UI 入口一个(有界) | 是(自动生成) |

    **交互面 profile 的最终树 = base 全套行 + 该 face 树叠层**(实测三 face
    物化 bundles 完全一致:`web = [dsh-base, dsh-web-app]`、`headless =
    [dsh-base, dsh-headless]`、`tui = [dsh-base, dsh-tui]`;模块配方
    lib.nix `[ "@deepseek-ai/dsh-base" source ]` 与物化一一对应)。boot 按
    bundles 有序叠 patch、同 id 后行胜出 —— base 的全部行(`llm-pi-ai`/
    `web`/`web-search-deepseek`/`tool-web`/...)在**三个 face 的最终树里
    都在**;face 树只是覆盖层(dsh-tui 自带的 `llm-deepseek` 强意见默认
    即一例)。手动 `profiles.*` 的层表由用户全权声明,base 习惯居首,
    顺序即叠层序。

     加功能插件 = 一处 `enable`,零新增;加交互面 = 一处
    `plugins.<name>.enable = true`(source/face 均可省:registry 收录的
    插件按键名尾缀反查,face 读收录时的 `face=` 元数据),自动生成
    `profiles.<face> = [ base + source ]` 与子命令入口 `dsh <face>` ——
    [base+face] 配方由模块一次编码,用户无从写错(base 丢失/顺序错误)。
    face 插件不参与跨 profile 分发(互斥);与显式 `profiles.<face>` 声明
    冲突、重复 face 名、撞上游子命令(保留集从上游 CLI 自动提取,web 除外
    —— 上游 `dsh web` 已等价 boot)均求值期 fail-loud。
    显式 `profiles.*` 保留为全权逃生口(自定义层序/patch);base 在其中
    显式重复是刻意的 —— plugins 是有序全树规格,隐式默认会被显式设置
    整体替换 → 静默丢 base → boot 期才炸(fail-loud 路径,nobase check 覆盖)。

## 插件形态与通道选择(设计准则)

配置词汇按"意图住在哪里"分层。这不是风格偏好,是防错边界:用错通道
= 意图耦合到组合树内部结构(face 装卸/上游重组时悬空),或产生"声明了
7 个 server 又禁用 mcp 插件"这类矛盾态。以下判据经上游源码逐条查证。

### 两形态:无任何载荷时,核心功能是否为零/必败

| 形态 | 判据 | 实测例 |
|---|---|---|
| **配置承载型**(value-shaped) | 无配置 → 功能为零或必败。配置 = 声明段/环境变量/credentials 服务,**住址不限** | `mcp-client`(零 server = 零工具)、`skill-filesystem`(空目录 = 空目录)、`web-search-deepseek`(每次搜索必败 `WEB_PROVIDER_CREDENTIAL_MISSING`,严格模式无降级)、`llm-deepseek`(每次请求必败 `MISSING_CREDENTIAL`) |
| **裸用型**(switch-shaped) | 零配置即完整工作 | `tool-bash`、`tool-fs`、`tool-todo`、`timer` |

- **凭据也是配置**:shell export、Web UI Models 页运行时存储、settings
  段,一律算。"检测到环境变量就启用"**不在 eval 期做**(impure eval,
  破坏可重现);在 nix 侧声明凭据来源(secretFile/env wrapper)的动作
  本身就是启用声明。打算纯运行时配 key → 显式启用,声明责任在配置
  作者,系统不猜运行时状态(Zig 式无隐式行为)。
- **"无用"≠"炸 boot"**:上游是惰性设计 —— 注册廉价(不看凭据)、按
  请求鉴权、使用点报结构化错误(llm-deepseek 的 `apply()` 无条件注册
  provider,`resolveApiKey` 每请求才解析)。正因不炸,未配置的配置
  承载型会**静默**占 UI 槽位(模型/工具选择器列出全部已注册条目)并吃
  prompt 预算(dsh-tool-web README 原话:"每个通过配置启用的工具都会
  为每次请求增加固定的指引 token 开销,即使限制隐藏了其 schema")。
  → 未声明即禁用有实益,不只是卫生。

### 通道选择纪律

| 层 | 通道 | 词汇 | 适用 |
|---|---|---|---|
| 1 首选 | typed 意图选项:`mcpServers` / `skills` / `presets`(已做)、`webSearch` 等(路线图) | "我要这个能力,这样配" —— 声明即启用,face 无关,载荷物化到共享层 | 载荷在声明里 |
| 2 次选 | `settings."<命名空间>"` | "调既有能力的参数" —— yq merge 免重启,UI 运行时改动保留 | 树里已有行,只改配置(如 `web-search-deepseek` 的 baseURL/maxUses) |
| 3 末选 | `inBoxPlugins` / `userPatches` | 树解剖词汇(行 id):修剪 / 反向启用 / 整行 config 重述 | 意图字面就是"树里这行怎么翻" |

层 3 引用的行 id 是组合树内部名字,上游重组树或 face 装卸后漂移;
配置频繁落在层 3 通常说明层 1 缺一个该有的 typed 选项 —— 性质类似
HM 的 `mkForce`:语义不可删除,但出现即设计缺口信号。

### 显式原则与落地状态

**作用域 = 组合树里无需用户声明就存在的行**(不只 dsh-base):face 树
内部行同样在内 —— `enable dsh-tui` 是对 UI 的显式声明,但它传递带入
的行(如树里的 `llm-deepseek`)仍未经行级声明,与 dsh-base 行同权适用
判据。社区插件**本体**不在作用域:`enable = true` 才进树,入口显式由
模块系统结构性保证,分类无事可做(其配置随同一声明块下发,way B 的
`plugins.<name>.settings` 即"声明即启用"同款)。

**多源行是常态,判据与禁用机制均来源无关**。同一行 id 可同时存在于
多棵树(实测 rc.6:`llm-deepseek` 在 dsh-base/cordis.patch.yml:450 有一
份中性默认,在 dsh-tui/cordis.yml:73 又有一份强意见默认 ——
`thinking: enabled` + `reasoningEffort: max`)。行归属哪个包无关紧要,判据
只看"这行是否未经你的声明就在树上"。因此 `inBoxPlugins` 的禁用行进
**所有 profile** 的用户 patch 层:两棵树里的同 id 行都被翻掉,没有该行的
树 warn+skip —— 一行声明天然覆盖多源,无需 per-face 重复。

**face 树 ≠ profile 树,判据永远对着最终树说话**(组合规律见语义模型:
交互面 profile = base 全套行 + face 树叠层,三 face 实测一致)。dsh-tui
自带树不建立在 dsh-base 上、必须自带全套运行时行,但 tui profile 的
最终树里 base 行都在 —— 单包树只是层的来源,行归属哪个包无关紧要。

**三态语义统一,默认值承载意图**(零 per-plugin 特殊处理):配置承载型
的 typed 选项一律 `null | {} | 配置attrs` ——

| 值 | 语义 |
|---|---|
| `null` | 禁用(disable 行进所有 profile 用户层) |
| `{}` | 显式启用·零配置(纯运行时配置留位:export / Web UI Models 页) |
| 非空 attrs | 启用 + settings 命名空间段渲染 |

插件间差异只允许出现在**默认值**,而默认值由空载荷代价选出(源码实证):
`llm-pi-ai` 空 providers = `directoryEntries()` 零注册、无可观测面 →
默认 `{}`(默认启用·惰性);`llm-deepseek` 空载荷 = `DEFAULT_MODELS`
catalog(v4-flash/pro)无条件注册、无 key 即死 UI 条目 → 默认 `null`
(默认禁用)。空载荷代价是选默认值的依据,**不是**豁免某插件三态语义的
理由 —— 谁都能禁,谁都能显式启用;`providers` 升级为 `nullOr`
(默认仍 `{}`,非破坏)即 pi-ai 的三态载体,`providers = null` × 非空
载荷声明 → 求值期 fail-loud(同 skills × disable 先例)。

**"声明即启用"精确化:声明必有效(在场,或被选择器解释)**。有选择器
的注册表类选项(选择器形态,如 `providers`+`defaultModel`、
`webSearch`+`webSearchProviders`)允许"声明 + 未选中"共存 —— 备案
待命不是矛盾;无选择器的载荷声明(mcpServers/skills/presets)仍是
声明即启用,配了又被禁 = 矛盾,fail-loud。两例对照:LLM 侧未选中
provider 全注册(模型可手切,活备选);webSearch 侧仅选中者启用
(web 搜索无切换面,未选中 = 死卡 → 禁行)。⚠ 后者的前提是上游
**无运行时 provider 切换**(dsh-web 实证:`searchProvider` 是行
Config 非命名空间段,构造器定格)—— 若上游将来支持热切,该策略
改为"声明即在,选择器热切"(lib.nix capabilityPatches 注释有同步
标记)。

**可见性规则:每个 UI 面跟随拥有它的行**(实测 rc.6)。禁用一个行后,
哪些面消失取决于"谁拥有那个面":

| UI 面 | 拥有者行 | 行禁用后 |
|---|---|---|
| 设置页插件卡(Web Plugins 页) | provider 自己(其 `apply()` 安装的 settings 命名空间) | **消失**(命名空间没装,`ui-settings-plugins` 原话:"A namespace this deployment does not expose renders nothing") |
| 模型面工具 schema(`web_search` 等) | tool 行(tool-web `apply()` 只看自身 config,无条件注册) | **仍在**("稳定注册"),调用时报错 |
| 模型选择器条目 | llm adapter 行(注册时展开 catalog) | 消失 |

所以"未声明=禁用"的收益按面盘点:禁 provider = 设置卡消失 + 调用必败;
禁 tool = 模型面工具与指引 token 归零。只禁 provider 不禁 tool 会留下
"看得见调不通"的工具(调用报 `WEB_PROVIDER_CONFIGURED_MISSING` —— base
的 `web` 行配了 `searchProvider: deepseek-official`,provider 未注册即
此码,dsh-web resolveProvider 实测;`UNAVAILABLE` 是"已注册但
`available()` 假",另一分支)。

 配置承载型**未声明 = 禁用**是目标姿态(UI 槽位/prompt 预算归零);
启用必显式 —— 给配置(声明即启用)或显式 enable(为纯运行时配置留位)。
落地状态:`mcpServers`/`skills`/`presets` 已是此语义;`webSearch` /
`llmDeepseek` typed 选项(默认 null)与 `providers` nullOr 升级(默认
{} 保持启用)已落地。

**迁移注记**:`webSearch` 默认 null 意味着三 face 的 `web_search` 工具
默认不再注册(base 树虽自带三行)—— 需要搜索的用户写
`webSearch = {};`(零配置,运行时配 key)或 `webSearch = { maxUses = 3; }`
找回。这是显式哲学的代价,明确选择不改。

**已知限制:web face 的 preset 挂独立 tool-web,patch 层不可达**(实测
rc.6)。`webSearch = null` 禁三行(`web`/`web-search-deepseek`/`tool-web`
—— 三个独立行,"不要搜索能力"同时覆盖 provider 与工具,工具禁用不
依赖 provider)。web face 上 tool-web 存在两份:宿主树行已被 web-app
的 bundle patch 禁掉(我们的 disable 行打上是 no-op,无冲突);shipped
preset(standard/code/cordis)的 `agent.cordis.yml` 各自带一份
`tool-web`(minimal 无)—— preset 是 CLI 包内只读独立组合,profile
patch 只作用宿主树,自建同名 preset 又被 shipped root first-root-wins
遮蔽,覆盖路线也堵死。后果:**"禁工具"意图在 web face 部分丢失** ——
preset 里的 tool-web 漏网照常注册,`web_search` 工具卡留在 UI、schema
token 照吃(provider 行已禁,调用报 `WEB_PROVIDER_CONFIGURED_MISSING`
结构化错误 —— 这本身是上游"稳定注册"的正常设计,问题只在禁用意图
没打全)。tui/headless 的 tool-web 是宿主树行,disable 全净。根治需
上游:preset 级配置化裁剪或 agent-presets 行级禁用(随 preset opt-out
issue 一并提)。

## 入口

单一 `dsh` wrapper:profile 子命令分发 `dsh <profile>` ≡
`dsh --profile <profile>`(手写 profiles 与自动 face 同权;`web` 走上游
原生子命令)。不再生成 per-profile wrapper(`dsh-<face>` 等)—— 子命令
分发等价,独立入口只是 $PATH 噪音,短命令需求由 shell alias 承担。

## 服务与 CLI:无共享守护进程(实测 rc.5 依赖图)

**每个 face boot 一棵完整独立的 cordis 树**,不是"后端守护 + 瘦前端"。
TUI 插件的依赖表直接内嵌运行时(`dsh-agent`/`dsh-session`/`dsh-storage`/
`dsh-cordis-host-runner`,无任何 RPC 客户端);`dsh-client-connection` 的
WebSocket server 是 web 应用**进程内**给浏览器用的传输层,不跨前端。

因此 `programs.dsh.web.enable` 的 systemd 服务 = 常驻的 web face 进程
(占 127.0.0.1:3080),**不是**可被 tui/headless 复用的会话后端 ——
上游没有跨 face 客户端协议,TUI 无法"连接"web 服务。

共享层是**文件系统**(`$DSH_HOME`):settings.yaml 热重载(所有运行中
进程可见,这也是 yq-merge 方案成立的前提)、凭证服务、会话存储。
web 服务与 `dsh tui` 并行运行是预期用法:两进程、两棵树、一份盘上状态。

## 装插件

## agent 预设

预设 = 一个会话 Agent 的插件组装(工具/提示词/能力),`agent.cordis.yml`
组合树 + `preset.yml` 元数据 + 任意 `.mjs` 插件文件 —— 纯文件零构建
(宿主 loader 负责解析),上游**热发现**(运行中新增免重启,同 settings
档,非 profile 树档)。

```nix
programs.dsh.presets.liangshen.source = ./presets/liangshen;
```

activation 物化到 `$DSH_HOME/.agent-presets/<name>`(stamp 语义同
profile:未变不动,孤儿自扫)。声明名 Nix 拥有 —— 物化覆盖 TUI 创造
模式的同名迭代版;**import 工作流**:创造模式做原型 → `cp -r
~/.config/deepseek-harness/.agent-presets/<名>` 进 config 仓库 → 声明
→ 之后迭代走仓库。缺 `agent.cordis.yml` 求值期 fail-loud。

**勿导入插件 shipped 的预设**(踩过:liangshen 是 dsh-tui 自带的)。
辨别:副本目录里有 `.dsh-tui-managed.json`(owner = 插件名)即是插件
管理的同步物 —— 插件更新经此通道自动跟进,导入 = 冻结当前版本,
遮蔽更新(root 优先级 first-root-wins,两 root 同 id)。shipped 预设
无需任何声明,插件装了就在;只导入**你自己创造/手写**的预设(无
managed marker)。与 shipped 预设撞 id 的自建预设会被 root 优先级
遮蔽 —— 改名。

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
> `plugins.<name>` 追加 options(nixvim 因此没有全局 plugins option)。
> typed module 挂在独立短路径 `programs.dsh.<短名>`,由 config 块回填
> 通用层 —— 用户视角仍是纯 typed 体验。给新插件写 typed module 时
> 照抄 `plugins-modules/status-rotator.nix` 的骨架即可。

**手写 patch 行(用户层直写,适合一次性覆盖)**

```nix
profiles.web.userPatches = [
  { id = "system-prompt"; config.persona = "You are..."; }
  { id = "hmr"; disabled = true; }
];
# !!js 表达式等复杂 YAML:userPatchesFile = ./web-patches.yml;
```

## 装插件(非 Nix 逃生口)

`dsh plugin --profile web add <pkg>` 在物化的可写 profile 副本里用 pnpm
装 —— 代价:偏离声明式,下次 profile stamp 变化时被重置。
私有 config.json 类插件(如 status-rotator)运行时写插件目录会因 store
只读失败,插件自身回退默认;确需改其配置时用此逃生口。

## API 一览

| Flake output | 内容 |
|---|---|
| `packages.<sys>.dsh` | CLI 包(全验证) |
| `overlays.default` | `pkgs.dsh` + `pkgs.dshPlugins` |
| `homeManagerModules.dsh` | `programs.dsh` 模块 |
| `nixosModules.dsh` | 薄 NixOS 模块 |
| `checks` | profile 模型验证(结构/正例/负例 fail-loud) |
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
└── profiles/
    ├── default.nix # imports
    ├── web.nix     # web profile(含插件声明)
    └── headless.nix
```

## 上游化路线

nixpkgs#552467 合并后:删 `package.nix`,overlay 改 `dsh = prev.dsh;`,
其余(模块/lib/插件机制)原样。rc.5 钉扎原因见 package.nix 头注。

## 维护

- `nix flake check` — profile 模型 + 包验证
- bump dsh:改 `package.nix` 的 rev/hash + pnpmDepsHash(注释里有流程)
- bump 插件:合并每周 PR,或手动 `nix run .#dsh-plugins-update`
