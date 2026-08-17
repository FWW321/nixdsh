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

模型条目是 **typed core + freeform 尾巴** submodule(schema 实测于
dsh-llm-pi-ai `modelFields`,rc.6):typed 键 = 数据描述符
(`id`/`name`/`contextWindow`(compaction 触发线)/`maxTokens`(每请求
输出上限)/`input`(输入模态 `["text","image"]` —— 低报=附件期早拒,
高报=provider 中途拒且会话卡死,**宁可低报**)/`reasoningEfforts`
(`false` 或 `{档位: wire 拼写}`,仅 off 可空值)/`compat`
(thinkingFormat 八方言/supportsReasoningEffort));未 typed 的未来
新字段裸透传(drift 负债同纯 attrs 形态),typo 也随之透传 —— 由上游
严格 z.object 在 settings 载入期拒(fail-loud 点名路由/模型)。渲染面
剥 submodule 的 default null 键(上游 z.number() 拒 null 值键)。


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
├── lib/                # 核心纯函数库(单向 DAG: inbox,secret → settings,apply
│   ├── inbox.nix       #   → wrapper → mkDsh):
│   │                   #   mkPlugin/mkProfile/buildProfile  profile→不可变 store 工件
│   ├── secret.nix      #   secretEnv(env 桥)/renderSecretAttrs(占位符通道)
│   ├── settings.nix    #   renderSettings/validatePresets/validateSkills
│   ├── apply.nix       #   applyPlugins(typed 层→profile 增量+face+能力缝行组)
│   ├── wrapper.nix     #   renderWrapper/renderCompletion/upstreamSubcommands
│   ├── mkDsh.nix       #   mkDsh: nixvim 的 mkNixvim 同构独立实例化
│   └── default.nix     #   组装 + 公共 API 导出
├── modules/options.nix# programs.dsh 共享 options(HM/NixOS/mkDsh 三方消费)
├── hm-module.nix      # HM 消费面:wrapper(子命令分发) + activation 物化 + systemd user 服务
├── nixos-module.nix   # 薄 NixOS 消费面(systemPackages)
├── checks/            # profile 模型验证:结构/正例/负例 fail-loud
│   ├── fixtures.nix   #   共享夹具(applyWith/mkFakeCfg/materialize/inTreeCheck)
│   ├── profile.nix    #   bundle 形状/boot 正负例/face 四态/in-box 行
│   ├── seam.nix       #   webSearch/webFetch 缝行组/secretFile 桥/in-tree×3
│   ├── mcp.nix        #   MCP 行渲染/secret 注入/insert 通道
│   └── sources.nix    #   providers 合并/presets/skills 校验
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
    lib/inbox.nix `[ "@deepseek-ai/dsh-base" source ]` 与物化一一对应)。boot 按
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

**包的"在场"有三种形态,启用路径各不同**(实测 rc.6;dsh-mcp-client
查证:CLI runtime node_modules 有包,base/tui/web 三树零行引用,tui
profile 的 package.json 也不含它):

| 形态 | 例子 | 在场方式 | 启用路径 |
|---|---|---|---|
| 树行自带 | `llm-deepseek`、`web-search-deepseek` | base/face 树里有行 | 行已在(默认启用);禁用出 disable 行 |
| **装而未挂**(shipped but unrouted) | `dsh-mcp-client` | 随 CLI runtime 发布,任何树**无行** —— 已装但沉睡,boot 零工具 | insert 行(我们的 `mcpServers` 渲染;loader 从 CLI 自身安装解析包,profile node_modules 无须有它);无需也无法 disable(无行可翻,卸载 = 删声明) |
| 完全外部 | `@tonydua/dsh-web-search-exa` | 不随 CLI,不在任何树 | insert 行 **+ 包源进 profile**(nixdsh registry/显式 source);这是它与 mcp-client 的关键差别 |

配置承载判据对三种形态照常适用("装而未挂"的 mcp-client 零 server =
零 UI/prompt 占用,默认沉睡即正确姿态)。

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
改为"声明即在,选择器热切"(lib/apply.nix capabilityPatches 注释有同步
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
落地状态:`mcpServers`/`skills`/`presets` 已是此语义;`webSearch`(选择
器形态)/`llmDeepseek`(默认 null)与 `providers`(nullOr,默认 {} 保持
启用)已落地,见「网页搜索」节。

**迁移注记**:`webSearch` 默认 null 意味着三 face 的 `web_search` 工具
默认不再注册(base 树虽自带三行)—— 需要搜索的用户写
`webSearch = "deepseek-official";`(零配置,运行时配 key)找回。这是
显式哲学的代价,明确选择不改。

## 网页搜索

`webSearch` 是**能力开关 + provider 选择器二合一**(唯一自由度:provider
是谁;骨架行 web/tool-web 无独立旋钮 —— 启 provider 必启、禁 provider
必禁,独立配置是假自由度)。选中才启用,未选中后端禁行(死卡清理;
前提:上游无运行时切换,见设计准则的 ⚠ 标记)。

**webSearchProviders 是开放注册表**:选择器指向的注册表开放,新后端
一条声明接入,零 nixdsh 改动 —— 内置后端与新后端走同一条声明路径
(预置只是默认值语法糖,不是代码分支)。

```nix
# DeepSeek 原生搜索(base 自带后端:裸 attrs 即参数;key 走 export
# DEEPSEEK_API_KEY 或 Web UI 运行时配;无 key 每次搜索必败,严格模式无降级)
programs.dsh.webSearch = "deepseek-official";
programs.dsh.webSearchProviders."deepseek-official".maxUses = 3;  # 可选

# Exa(社区包 @tonydua/dsh-web-search-exa,registry 收录;无 key 走
# mcp.exa.ai 匿名兜底零配置可用,有 key 走 REST)
programs.dsh.webSearch = "exa";
programs.dsh.webSearchProviders.exa = {
  row = {                                # 完整声明 = 非 base 自带后端
    name = "@tonydua/dsh-web-search-exa";          # cordis 包名
    config.apiKeyEnv = "EXA_API_KEY";              # 行引导配置
    # id = "web-search-exa";            # 行 id 缺省 = 包名尾段剥 dsh-
    # settingsNamespace = "web-search-exa";  # 段名缺省 = web-search-<id>
  };
  settings.numResults = 5;               # 该后端 settings 段参数(热生效)
  # source = pkgs.dshPlugins."…";        # 包源缺省 registry 尾名反查
};

# 任意私有/新后端:同一条声明语法(row.name 换成你的包)
# 切换后端 = 改一个字符串(两边声明都在,备案待命)
```

机制:选中 base 自带后端 → 树行原样 + 参数渲染进 settings 段(按次
投影热生效);选中声明后端 → base 后端禁行 + insert 行(行 config =
row.config)+ `web` 行重述 `searchProvider` + 包源进所有 profile
(声明 source 或 registry 反查;参数渲染进该后端 settings 段,热改)。
求值期断言:选择 id 须在声明表 ∪ {deepseek-official};能力禁 ×
声明表非空 → throw。

## 网页抓取(fetch 缝,rc.6 现状:空)

`ctx.web` 是**一个缝两个操作**(dsh-web README:17 原话:"one seam …
one provider-selection policy owner"):search/fetch 两套同构机制,
共用选择器策略、错误码词汇(`WEB_PROVIDER_*`)与执行时分发 —— 差异
只在生态现状。

| | search 缝 | fetch 缝 |
|---|---|---|
| 注册表 | `searchProviders`(exa/zhipu/deepseek 在填) | `fetchProviders`(**rc.6 零注册者**) |
| 接口 | `{id, available(), search({query, maxResults}) → {sources[]}}` | `{id, available(), fetch({url}) → {statusCode, body}}`(body 封闭 union `html`\|`text`) |
| 选择器 | `searchProvider` / `DSH_WEB_SEARCH_PROVIDER` | `fetchProvider` / `DSH_WEB_FETCH_PROVIDER` |
| 模型面工具 | `web_search`(tool-web) | `web_fetch`(tool-web,`fetch` 键,base 默认 **false**) |

**fetch 缝为什么空:SSRF 责任推给 provider**(dsh-base patch 源码
注释:"that provider defers SSRF protection and the model would
choose the request target")。模型自选 URL + provider 在本机发请求 =
经典 SSRF 面(127.0.0.1/169.254.169.254 云元数据/RFC1918/DNS
rebinding/重定向跳内网);上游立场是 seam 不挡、谁注册谁防护,官方
规划中的 `dsh-web-fetch-http`(README 生态表)未随 rc.6 发布,故
`fetch: false` 保险丝。search 缝无此问题(query 是字符串非 URL,
请求目标永远是 provider 自己的 API)。

**远端 reader 型 fetch provider 无 SSRrf 面**(如 Zhipu web_reader
包装):抓取发生在 provider 服务商的网络(bigmodel.cn),不是本机 ——
经典目标(本机回环/内网/云元数据)从服务商网络不可达;本机唯一网络
活动是到 MCP 端点的出站 HTTPS。上游"provider 自负 SSRF 责任"对这类
provider 平凡满足(不从本地网络抓取,防护清单零条适用)。

nixdsh 侧:`webFetch`/`webFetchProviders` 已落地(fetch 缝对称选择器,
镜像 webSearch 语义;差异:fetch 缝无 base 自带后端,选中必声明,且
模块代开 tool-web 的 `fetch: true` 保险丝 —— 打开动作本身即"信任
该 provider 的 SSRF 姿态"的显式声明):

```nix
programs.dsh.webFetch = "zhipu";
programs.dsh.webFetchProviders.zhipu.row = {
  name = "@fww/dsh-web-fetch-zhipu";
  secretFile = "/run/secrets/zhipu_api_key";  # 派生 apiKeyEnv,与
  # search/providers 同 env 同文件自动去重(一个 ZHIPU_API_KEY 全喂)
};
```
选中渲染三行:insert 后端行 + `web` 行 `fetchProvider` 重述 +
`tool-web` 行 `fetch: true`;未选中后端禁行(备案待命,同 ws 语义);
断言:未知 id / 表非空×`webFetch = null` / inBox 禁 tool-web 均
eval throw。

**已知限制:Web Plugins 页的表单卡是上游硬编码,不随命名空间出现**
(实测 rc.6,`dsh-client-ui-settings-plugins/client.js`)。Plugins 页
每张卡在前端代码里写死:agent-loop / shell / **web-search-deepseek**
(ns 常量 :911,表单字段 baseURL/maxUses/apiKey 同样硬编码)—— 没有
"扫描已装 settings 命名空间动态出卡"的机制。因此第三方 provider
(exa 的 `web-search-exa` 段)装了命名空间也不会有表单卡;另一页的
Plugin Inventory(loader 条目只读投影)会列出该插件"已启用",与表单
卡无关。配置面:声明侧 settings 段照常渲染(yq merge 热改);运行时
改值走 host settings scope API(命名空间可读写,`installSettingsSection`
的作用),只是无专属表单 UI。动态表单需上游做(基建已有:
`dsh-client-schema-form` 包存在但未用于此)—— 可提 issue。

注:bundle store 路径变化**已被** dsh-web 服务指纹覆盖
(`DSH_PROFILE_FINGERPRINT` = 各 bundle 的 store 路径串,路径变 →
unit 变 → HM 自动重启服务;实测 peers 修复重建后一次拉起,无需手动)。

**已知限制:web face 的 preset 挂独立 tool-web,patch 层不可达**(实测
rc.6;**对称面:开保险丝的 patch 行同样不可达** —— 解法见「能力行
重放」节,fetch:true 经 preset 物化穿透)。`webSearch = null` 禁三行
(`web`/`web-search-deepseek`/`tool-web`
—— 三个独立行,"不要搜索能力"同时覆盖 provider 与工具,工具禁用不
依赖 provider)。

**base 行 tool-web 的三 face 三态**(逐 profile dump 实测 rc.6;这行
不是死行,是 headless 的活水 —— base 默认完整集、face patch 做减法):

| face | base tool-web | 谁禁的 | 搜索工具来源 |
|---|---|---|---|
| headless | **启用** | 无人禁 | base 行本身(裸会话无 preset 层) |
| web | 禁用 | dsh-web-app bundle patch | shipped preset 各自挂(standard/code/cordis 有,minimal 无) |
| tui | 禁用 | dsh-tui cordis.patch.yml:120(连批工具精简) | preset(liangshen 的 agent.cordis.yml:385 实证) |

web face 上 tool-web 存在两份的架构语义(源码注释 dsh-web-app
:383-384 原话:"The `web` service and its search provider stay in the
host composition; only the model-facing tool is per-session"):
web 服务 + provider 住宿主组合(有状态:provider 注册表/MCP 会话缓存/
凭证单点,轮换一次生效),模型面工具按 preset 实例化(无状态,但吃
每次请求的 prompt 预算,preset 裁剪自由度 + per-session 政策隔离)
—— 服务/消费者分离,工具调宿主 web 服务,服务再走选中 provider。

后果:**"禁工具"意图在 web face 部分丢失** —— preset 是 CLI 包内只读
独立组合,profile patch 只作用宿主树,自建同名 preset 又被 shipped
root first-root-wins 遮蔽,覆盖路线也堵死;preset 里的 tool-web 漏网
照常注册,`web_search` 工具卡留在 UI、schema token 照吃(provider 行
 已禁,调用报 `WEB_PROVIDER_CONFIGURED_MISSING` 结构化错误 —— 这本身
是上游"稳定注册"的正常设计,问题只在禁用意图没打全)。tui 同理
(preset 接管)。headless 的 disable 全净(宿主行即唯一行)。根治需
上游:preset 级配置化裁剪或 agent-presets 行级禁用(随 preset opt-out
issue 一并提)。

**已知限制:会话事件是封闭集,仓库外插件不能写自定义事件**(实测
rc.6 中毒 + 修复全程)。官方 `web/deepseek-search-llm-request` 之所以
能写,是它注册在 `dsh-session` 的 `KNOWN_SESSION_EVENT_TYPES` 封闭集
里(session-persistence :1119 读端校验:`KNOWN.has(type) ||
event.ignorable === true`);上游注释明说仓库外插件事件 by
construction 不在列表,注册面 deferred。**写自定义事件 = 毒化会话
日志**:读端 `SessionFormatUnsupportedError` 拒读整份日志(历史不可
回放),且写毒的会话在列表/打开时反复触发。曾给我们两个 zhipu
provider 加过审计事件(照官方 recordRequest 模式),实测毒化 —— 已
删(包 commit a02ae5f/dc91b57),教训:**加事件只验证了写路径(官方
包怎么写),没验证读回路径**;任何"日志追加"类功能必须先读一遍。

会话日志手术手册(已实操,供复发时参考):

- 格式:`session.jsonl.zstd` = **逐 append 批一个 zstd frame**(魔数
  `28 B5 2F FD` 切分),解开后每行一个 JSON;聚合行
  (`text-chunks`/`reasoning-chunks`/`tool-call-chunks`)由
  `decodeStorageRecord` 展开为**多条 seq 连续事件** —— 验证脚本必须
  展开聚合行,否则满屏假 gap
- 两个约束:seq 全程 0 起连续(**裸丢事件行 = seq gap,读端拒绝**);
  事件 type 须在已知集**或带 envelope 级 `ignorable: true`**
- 正确修法:毒事件行改 `"ignorable": true`(type 原样保留,读端跳过
  且 seq 不断)—— 不要丢行(第一次手术丢帧造成 seq gap),也不要
  整文件重压(第二次手术错在 zstd 单 frame —— 上游是逐行流式追加,
  整压成单 frame 读端报 "first frame is not exactly one header
  line";受影响 frame 内的行重压回逐行 frame,未受影响 frame 原样
  字节保留)
- 服务读坏日志会 boot 崩溃循环(dsh-web 起不来,3080 拒连);日志
  修好后 systemd 自动拉起,无需干预
- 上游闭门,无 issue 可提;若未来政策变化,素材:会话事件注册面或
  公开 ignorable 写入口

## 入口

单一 `dsh` wrapper:profile 子命令分发 `dsh <profile>` ≡
`dsh --profile <profile>`(手写 profiles 与自动 face 同权;`web` 走上游
原生子命令)。不再生成 per-profile wrapper(`dsh-<face>` 等)—— 子命令
分发等价,独立入口只是 $PATH 噪音,短命令需求由 shell alias 承担。

**stderr 过滤(wrapper 拥有的层)**:dsh-tui 启动期对每个版本错位的
peer 打一条 `upstream drift` 警告(apply() 无条件 console.warn,无
开关;profile 钉 rc.5、tui validated rc.6 → 每次 23 行刷屏)。wrapper
以 `grep --line-buffered -v '^\[dsh-tui\] upstream drift:'` 滤掉该
模式,其余 stderr 原样透传;要看原始警告直跑 store 里的 `bin/dsh`
(绕过 wrapper)即恢复。上游版本串对齐后此过滤自然空转。

## face 树独占插件通道(强一致性教义)

**交互树(face tree)只能由 face 插件生成**;手写 `profiles.<name>` 是
非交互命名组合的通道(base + 功能插件 + patches),两者不重叠。

为什么收口(此前是软一致性 —— 双通道各自合法,靠撞车 assert 兜底,
留下三个漏洞):

- **per-插件选项恒有锚**:`plugins.dsh-tui.defaultPreset` 挂在交互
  插件上,树由它生成,选项永不失焦(face 改名经推导链自动跟随)
- **树生命周期严格绑定插件**:enable/disable 即树的存在/消失,
  无"无主 tui 树"形态
- **一棵树恰一个 owner**:stamp/物化/孤儿清理语义无歧义

变体交互树不需要手写通道 —— 插件通道全覆盖:

```nix
# 第二棵 web 树:同 bundle 不同名,零手写 profile
plugins."web-dev" = {
  source = "@deepseek-ai/dsh-web-app";
  face = "web-dev";                # → dsh web-dev 子命令
};
```

检测与边界(eval 期 throw):手写 profile 的 plugins 里嵌 face bundle
(in-box 字符串命中 web-app/headless,或 derivation 源带
`passthru.dshFace`)。路径源无元数据不可检;`userPatchesFile` 是全权
委托同样检测不到 —— 这两处是文档纪律:交互 bundle 一律走插件通道。

### 默认 preset(per-face + 全局兜底;随 roster 接管下发)

```nix
plugins.dsh-tui.defaultPreset = "liangshen";  # tui 树默认(改名自动跟随)
programs.dsh.defaultPreset = "fww";           # 其余树兜底(再缺省 standard)
```

值直接进各 face 树 `agent-presets-nix` 行的 `config.default`(见下节
roster 接管)—— **无 settings 面**:settings 用户层恒胜组合层行,
故 nixdsh 从不写 `settings."agent-presets"`(freeform 与 typed 同设 →
throw;仅 freeform = 用户自管逃生口,文档化遮蔽语义)。负例全
fail-loud:非 face 插件设值 / freeform 冲突。preset id 存在性不校验
(手写 preset 是运行时状态;roster 自有 UnknownPresetError)。

### 权限模式(新会话默认;per-face 物理成立)

```nix
programs.dsh.permissionMode = "workspace-write";          # 全局兜底
programs.dsh.plugins.dsh-tui.permissionMode = "read-only"; # per-face 胜
```

与 preset 能力行**物理相反**:权限活在宿主组合层(`sandbox-policy` /
`approval` / `permission` 三行,每树一份,行值公式读
`DSH_PERMISSION_MODE` env),不在全局共享的 preset 层 —— 所以全局 +
per-face 是干净成立的(later-wins 行 patch,无需重放/fork)。

渲染三行同步一致(`sandbox-policy.mode` / `approval.policy` /
`permission.defaultPreset`),`danger-full-access` 自动映射
`approval: never`(与上游 env 公式同构)—— 三行不一致会让组合层
推断出 "custom" 而炸(dsh-permission-presets :116)。

**read-only 的表接管**:`read-only` 是合法 sandbox mode
(SANDBOX_MODES)但**不是**上游 preset——`permission-presets` 表默认
只有 `workspace-write`/`danger-full-access` 两条,服务构造即
`resolve(defaultPreset)`,未知即 throw。该表 `presets` 键是 z.dict
**整表替换**语义(default 仅在缺省时生效)→ `read-only` 模式下
`permission` 行 config 携带整表(上游两条逐字镜像 + `read-only`
本地条目,approval=ask)。负载键(sandbox/approval)镜像上游常量;
name/description 漂移仅影响 UI 文案。副作用为正:运行期手切
read-only 的会话也能被 derive 命中,显示为命名 preset 而非 custom。

**caveat**:UI 里"选择新会话的默认权限模式"写的是 settings 命名空间的
运行时用户层,恒胜组合层 —— 手选过一次后本选项被遮蔽(UI 改回即恢复)。
这是与 defaultPreset 协调同款的"settings 用户层在上"约束,方向相反:
那边 nixdsh 主动避开,这边是上游 UI 拥有该层。

**caveat(subagent 隐式下传)**:subagent child 的权限在委托边界一次性
固定 —— 继承父会话的显式 sandbox override,approval 钉死 `never`
(read-only 父的 child 恒 read-only 且永无审批弹窗,见下方 subagent
调研节);父事后 switch 不追溯已建 child。per-face permissionMode
因此自动覆盖该 face 树的全部后代,无需也无法 per-child 配置。

### "会话默认"型 settings 命名空间全景(实测 installSettingsSection 扫描)

上游 `installSettingsSection` 注册面共 9 家,其中"每会话起点的默认
选择"型(有 UI + 运行时用户层遮蔽 caveat)已全部 typed:

| 命名空间 | 键 | 值域 | nixdsh 面 |
|---|---|---|---|
| `permission` | `defaultPreset` | 3 preset 名(SANDBOX_MODES) | ✅ permissionMode(enum 三值) |
| `agent-presets` | `default` | roster id(运行时集) | ✅ defaultPreset(str) |
| `agent-default-model` | 模型 id | provider 注册表(运行时集) | ✅ defaultModel(str) |

其余为纯行为旋钮(无"会话默认"概念,无双层问题):`agent-loop`
(maxParallelToolCalls 等)、`shell`(bash/pwsh timeout 等)、
`llm-deepseek`/`pi-ai`(retry 策略)、`web-search-deepseek`。
**均不预制 typed 选项**:freeform settings 今日可达,rc 阶段 schema
未稳,typed 化 = 每次 bump 背 drift 负债;触发条件出现再按需做
(候选优先序:maxParallelToolCalls → shell.timeoutMs → llm retry)。

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

声明的 preset 进 farm(roster 根,见下节)—— **零 activation 物化**
(store 只读)。**import 工作流**:TUI 创造模式做原型(`~/.config/
deepseek-harness/.agent-presets/<名>`,user 根热发现)→ `cp -r` 进
config 仓库 → 声明 → 之后迭代走仓库。缺 `agent.cordis.yml` 求值期
fail-loud。

**勿导入插件 shipped 的预设**(踩过:liangshen 是 dsh-tui 自带的)。
辨别:副本目录里有 `.dsh-tui-managed.json`(owner = 插件名)即是插件
管理的同步物 —— 插件更新经此通道自动跟进,导入 = 冻结当前版本。
shipped 预设无需任何声明(进 farm);只导入**你自己创造/手写**的
预设(无 managed marker)。

### roster 接管与能力行重放(preset 层穿透;上游闭门,本地永久机制)

⚠ **本小节机制是本地永久机制(roster 接管),不是过渡补丁**。上游
不收 issue/PR,无修缝可等;若将来开放修缝(mountPreset overlay),
可退役 —— 注记保留可能,不依赖。

背景(实测 rc.6):能力行组的宿主层 patch 对 web/tui 会话**无效**
——dsh-web-app bundle 把 tool-web 等模型面工具整行禁用("The Web
surface disables them here and lets each session mount a preset
instead"),dsh-tui patch 同构;会话工具的真实来源是每会话挂载的
preset(standard:250 / liangshen:388 写死 `fetch: false`),行解析
序 agent → preset → global,宿主行够不着。工具插件的 schema 默认
本就是 `search: true, fetch: true`(dsh-tool-web index.js:747)——
保险丝是 preset 显式关的,不是插件默认。

**机制:roster 接管(两行舞 + farm)**。profile-boot 对
`agent-presets` 行的 config 无条件 clobber(roots 钉 shipped,
:180 `rows.has("agent-presets")` 守卫)—— 但 **clobber 只打 id**:
nixdsh 在每棵 face 树的 userPatches 里 ① 禁 base 的
`agent-presets` 行(随之行失效)② 异 id `agent-presets-nix` 重插
同包实例,`config = { default = <typed 值>; roots = [ { path =
<farm>; trust = "system"; } ]; }`。插件的 roots Config 本就是设计面
(:808),服务名是类常量与 entry id 无关(:848),同包多实例异 id
是既有实践(mcp-client ×7)。实证:web 树干净 boot,preset 菜单
roster 完全来自 farm(shipped 集被挤出)。

**farm**(`lib/preset.nix buildPresetFarm`)= 单一 store 只读根,
全部 preset 的**重放产物**:shipped 全量(能力行 yq 按 id 改写进
`agent.cordis.yml` —— **手选 shipped id 拿到的也是重写版,逃逸
关闭**;行不在则无操作,minimal 无 tool-web 是身份语义)+ discovered
+ declared(同名胜,声明即接管)。roster = `[farm(system), user]`,
includeUserRoot 缺省保留 → 手写 preset 照旧热发现;trust: system →
tui 视同 shipped(ensurePackagedPresets 永不碰,**marker 剥离舞与
activation 物化整体退役**,旧物化区带 stamp 目录一次性清理)。

- **零边际**:行组来自能力选项(webFetch/webSearch/将来任意),
  单一事实源自动穿透全部 preset;配置面无任何 per-preset 改写行
- **preset 自动发现**:enabled 插件源携带的 preset 自动接管(registry
  derivation 走 `passthru.dshPresets`(update.py 收录时探测 `presets/*/
  agent.cordis.yml`),flake path 源直扫目录)—— `plugins.dsh-tui.enable`
  是唯一事实,preset 跟随插件生命周期;用户显式 `presets.<name>`
  声明与发现撞名 → 显式胜;黑名单 `plugins.<name>.excludedPresets`
  不接管特定 preset,排除 id 不在插件探测集 → eval throw;全禁
  `plugins.<name>.presets = false`
- **上游跟随**:flake bump → source 包变 → farm 重建,与 profile
  的 base+userPatches 完全同构;disabled/insert 形态行不重放(全局
  树语义)
- **耦合注记**:两行舞对 base 行 id `"agent-presets"` 硬耦合 ——
  上游改名则 disable 行 warn-skip + 双服务共存炸(loud,非静默)
- **UI 标签语义**:preset 菜单的"内置"是 trust 二值不是出处 —— farm
  全体(system trust)显示内置样式,与 provenance 无关;插件携带的
  preset(如 liangshen)显示自己的 name/描述(不在上游本地化表),
  手写的(user 根)带 `· 用户` 后缀。真出处账在 dsh-presets 命令

用法(插件托管 preset 零声明;shipped fork 用助手消布局硬编码):

```nix
# liangshen 零声明:dsh-tui enabled → preset 自动发现接管(进 farm)
presets.fww.source = lib.mkDefault (nixdsh.lib.shippedPreset pkgs "standard"); # 换名
defaultPreset = "fww";   # 进各树 agent-presets-nix 行(不再走 settings)
webFetch = "zhipu";      # fetch:true 重放进全部 preset(含 shipped —— 逃逸已关)
```

### dsh-presets 命令(出处总账 + 树诊断)

`dsh-presets` 列出全部 preset 及其归属(构建期 JSON 快照,命令只读、
零 eval;farm 路径随快照下发):

```
$ dsh-presets
code      replayed   dsh
cordis    replayed   dsh
liangshen discovered plugins.dsh-tui
minimal   replayed   dsh
standard  replayed   dsh
```

- **replayed**:shipped id 的重放接管(随 dsh 升级,能力行已重放)
- **declared**:`presets.<name>` 显式接管;source 落在 shipped root 内
  → 标 `← shipped:<名>`(换名 fork)
- **discovered**:插件源自动发现接管,`plugins.<插件名>` 即归属

`--live` 比对各 face 树的 roster 行 `roots` 是否指向当前 farm:
旧 farm / 无行 = ✗ pending switch;✓ in sync;无行的树(headless/
手写)静默跳过。`--tree <face>` 单树诊断(default/roots/同步态 ——
settings 遮蔽类排障的入口)。user 根目录不再清理(只有用户自己的
手写物)。

### 分化轴调研结论(为何只有全局均一 + per-preset 逃生口)

"能不能 per-face 分化能力行(如 tui 树禁 fetch)?" —— rc.6 源码实证,
四条通道全关,且多数是有意设计:

1. **mount 时 overlay**:`mountPreset`(dsh-agent-presets lib/index.js:707)
   签名即 `{path}`,无任何 config 覆盖参数 —— preset 文件即终态组合
   ("a preset IS a composition" 是 API 级承诺)
2. **per-tree roster roots(最接近的一条,被显式堵死)**:
   `AgentPresets.Config` 有 `roots: [{path, trust}]`(:808),但
   profile-boot(lib/profile-boot-*.js:183)在所有 overlay 之后无条件
   追加 `{id: "agent-presets", config.roots = [shipped root]}` —— 树上
   声明的 roots 必被 clobber,roster 序恒为 [shipped(system), user]。
   上游注释明说意图:"a shipped preset still shadows a locally authored
   directory that claimed its name"(防本地 preset 冒充 shipped)
3. **settings**:名册 schema 仅 `{default}` 一键(:796)
4. **DSH_HOME fork**:粒度错 —— 会话历史/settings/skills/密钥全跟 fork,
   那是"两个用户"不是"一个用户两个面"

结论:preset id 是上游留下的唯一完备分化轴。nixdsh 语义定档:
全局均一(完备、零新概念)为用户面;`presets.<id>.patches`(行 id 寻址,
later-wins)为将来按需的逃生口;**face 轴糖物理不可能完备,永不建**
(会话内手动切 preset 会逃出配置)。上游闭门(不收 issue/PR),本地
终局 = fork 接管 + 行重放,无上游修缝可等 —— 通道 2 的 clobber 证据
(上游把 capability 分化定位在 settings 面)留作上游自身演化方向的
参考,不构成 nixdsh 的依赖。

残余边界(已关闭):会话内手动选非 default 的 shipped preset 曾拿
未改写版 —— roster 接管后 farm 全量重放,**shipped id 也是重写版,
该逃逸不复存在**。剩余真边界仅两条:① settings 用户层手选 default
恒胜组合层行(UI 手选后 nixdsh 的 defaultPreset 被遮蔽,UI 改回即
恢复);② 手写 profile 树无 roster 语义(设计:非交互组合)。

### subagent 机制调研(master@47f9438 实证)

包地图(8 个):`dsh-subagent`(service seam:`ctx.subagents` 单例 /
provider 注册表 / durable descriptor / continuable 编排)+
`dsh-subagent-{spawn,fork}-in-process`(共享
`subagent-in-process-driver` 的两个 in-process provider)+
`dsh-tool-subagent`(模型面委托工具,每 transport 一实例、各异
toolName)+ `dsh-tool-subagent-control`(全局 `send_message` /
`interrupt_agent`,+ 可选 `list-agents` 子插件)+
`dsh-tool-subagent-report`(child 作用域 `report` 回报工具)+
`dsh-client-ui-subagent`(UI)。

**两种生命周期**:`one-shot` 一次性委托(前台等结果,或
`run_in_background:true` 注册 Task,`job_output`/`job_kill` 收割);
`continuable` = durable Session + 进程内 Activation(驻留 epoch)——
`startContinuable` 返回 durable child id,`send_message` 追加 FIFO
turn,`interrupt_agent` 只停当前 turn 不 dispose,冷恢复靠持久
descriptor + 会话日志重放;结算时 manager 无条件给父送 settlement
notice(stop reason + 最终消息,子未 report 也要送)。

**spawn vs fork**:spawn = 全新 child、空会话、需自足 prompt、继承父
model/provider;fork = 种入父**已完成 turn 前缀**(截到最后
`turn/end`,进行中 turn 不含;父尚无完成 turn 则退化为 spawn)——
只传历史,不传工具限制/权限。注:base 行(dsh-base
cordis.patch.yml:324)fork 钉 `one-shot`(注释引 fork-one-shot Agent
Note:continuable 的 report 工具/提示段会打乱继承前缀的字节序,毁掉
fork 存在意义的 KV 复用),但 standard preset(agent.cordis.yml:193-198)
已覆盖为 `continuable` —— master 新翻转,fork 包 README"shipped 全
one-shot"未跟,以 rc.6 源码为准。

**平面归属(印证上文两平面教义,standard preset 注释原文自证)**:
host 面 = `subagents` 注册表 + spawn/fork 后端(进程单例,api-proxy
跨会话查它;provider 名只能注册一次 —— preset 放它第二个 session 炸)
+ `tool-subagent-report`(在单例注册 continuable-setup,非
scope-aware,每 mounted preset 一份会在第二会话重复注册 throw);
preset 面 = 委托**工具行**(`delegation` 组:standard
agent.cordis.yml:174 起;minimal 无;`subagent_codex`/
`subagent_claude_code` 行 `disabled:true` 待启,:203/:212)。

**child 组合强制 join 父 preset**:`applyChildComposition(childCtx,
parent, composition)` 把 join 做成唯一调用形态 —— 不 join 的 child
无法表示(join 前模型面工具注册表为空);join 的 preset id 记入 child
durable header 供冷读重建(取父**live scope 链**而非 header,父中途
switch 以新组合为准)。**无 per-child preset 选择**,无用户自定义
agent 文件(不像 opencode `.opencode/agent/*.md`);persona/
toolFilter/model/maxTokens/maxDepth 全是**工具实例级部署配置**(每个
`dsh-tool-subagent` 行一份,同实例恒定);模型每调只能传
`description`/`prompt`/`run_in_background`。

**委托策略固定(与 permissionMode 的交点)**:child 权限在委托边界
一次性固定 —— capture 父会话**显式** sandbox override 写入 child 自己
日志(`source: 'delegation'` 的 `sandbox/mode` 事件;冷恢复重放该事件
而非重新 capture,故父 switch 不追溯已建 child),approval **钉死
`never`**(无人应答 child 审批,确定性拒绝而非挂起);父无显式
override 则 child 动态跟部署默认。child runtime-context 带
`subagent:delegation` 声明(超范围→陈述限制,不重试)。

**对 nixdsh 的含义**:① 无新声明面 —— 无 settings 命名空间、无用户
agent 定义文件,subagent 暴露完全由 preset 工具行决定,现有机制天然
覆盖;② 启用 `subagent_claude_code` = fork standard 去掉该行
`disabled`(standard 注释原文即此教法)—— `presets.<id>.patches`
逃生口的教科书用例;③ permissionMode 的隐式下传见该节 caveat。

### subagent 实例(subagents typed 面)

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
    # toolName 缺省派生 "subagent_researcher";persona/maxDepth/enableRunInBackground 见 options
  };
};
```

每个实例渲染一行 `dsh-tool-subagent`(insert 通道,同 MCP —— 新行
id 不在树上,裸 patch 只会 warn+skip),落宿主组合层 **global 层**:
preset 会话经 dsh-tools `view()` 的 global 基底看到新 toolName
(preset 只遮蔽**同名**)—— 与 wf/ws 行组的同 id 遮蔽根因不同,
**无需 preset 重放**。

设计裁决(为何纯全局、无 `profiles` 键):行是 agent 面能力,与前端
无关;face 分化已能穿过 preset 轴免费获得(per-face `defaultPreset`
选带/不带 delegation 行的 preset)。启用 shipped 禁用行
(`subagent_claude_code`/`subagent_codex`)不归本面管 —— 那是
preset 内既有行的 `disabled` 去除,走 `presets.<id>.patches`。

求值期查重(上游 "already registered" 是 boot 期晚期 throw,TODO
已认):实例间 toolName 重复 / 撞 base 全局名(`subagent`/
`subagent_fork`)或全局控制工具(`send_message`/`interrupt_agent`/
`list_agents`/`report`)/ attr 名 `fork`(生成行 id 撞 base 的
`tool-subagent-fork`)→ throw。`maxDepth` 允许 0(= 禁止该实例的
child 再委托);`provider-managed` 仅出进程 provider 有意义,不进
typed(走 patches 逃生口)。

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

## stdio MCP 子进程 stderr 收纳

上游 mcp-client 不传 SDK 的 `stderr` 选项 → `@modelcontextprotocol/sdk`
stdio.js 默认 `inherit`:GitHub/zai 等 server 的启动日志直通终端,
TUI 里刷屏遮挡(SDK spawn 行 `stdio: ['pipe','pipe', stderr ?? 'inherit']`,
任何 boot 会话的入口都中招)。

nixdsh 渲染期默认把 stdio server 的 `command` 包成
`sh -c '… exec "$@" 2>>$XDG_STATE_HOME/deepseek-harness/mcp/<name>.log'`
(`mcpStderrToLog`,默认 true):日志保留排查能力、终端干净;`false`
恢复原始 inherit 形状。env/cwd 语义不变(row 配置作用在 exec 后的
真实进程);`$XDG_STATE_HOME` 缺省回落 `~/.local/state`。

## 密钥生命周期(store 零密钥,物化层明文)

`mcpServers` 的 secret 形态(`{ secretFile; prefix? }`)设计目标是
**store 工件零密钥**。链条三级(实测 rc.6):

| 级 | 位置 | 内容 | 暴露面 |
|---|---|---|---|
| 声明 | nix 配置 + secrets.yaml | `secretFile = "/run/secrets/xxx"`(路径,非值) | git 里全是 ENC[] |
| store | bundle 的 cordis.patch.yml | 占位符 `@dsh-secret:/run/secrets/xxx@` | world-readable,无密可泄 |
| 物化 | `~/.config/deepseek-harness/profiles/<name>/cordis.patch.yml` | **真密钥明文**(activation replace-secret 注入) | 0600/fww,home 700 |

物化层明文是**当前最优解,不是缺陷**:上游 mcp 行 schema 的
headers/env 是字面量 map,没有 env 间接引用字段 —— 运行时子进程要
真值,boot 前必须落进 patch 文件,能做的只有把权限收到 0600(同
sops-nix 物化哲学)。对照:exa 插件原生 `apiKeyEnv`(env 间接引用)
全程零明文 —— wrapper export + scrubbedParentEnv 下显式 env 是官方
凭证通道,这是上游插件 schema 的能力差异,不是 nixdsh 侧区别。

实测(本机 web/tui/headless 三份物化 patch):Zhipu key ×5 处
(web-reader/web-search-prime/zread headers + zai `Z_AI_API_KEY`)、
GitHub PAT ×1、Context7 key ×1;对应 store bundle 三份均只有
`/run/secrets/*` 占位符。轮换:改 /run/secrets 源 → 重建(activation
重读注入);store 不缓存旧值,无残留。

上游化候选(与 Plugins 页动态卡同一批 issue):mcp 行 schema 增加
env-indirection(如通用 `headers.<k>.env`),物化层即可退到纯路径
引用,明文归零。

### secretFile 声明内 env 桥(第二条通道)

env 型凭证(apiKeyEnv 消费者:llm 路由、webSearch 后端)有独立通道,
**不落 patch 文件,全程零明文**:`providers.<id>.secretFile` /
`webSearchProviders.<id>.row.secretFile` 声明后,wrapper 每次启动
现读文件 export —— 密钥来源与消费者同处一行,CLI/TUI/headless/
web 服务统一入口,无需 bash initExtra/EnvironmentFile 两条外部桥。

- env 名 = 显式 `apiKeyEnv` > **文件名大写约定**
  (`/run/secrets/zhipu_api_key` → `ZHIPU_API_KEY`);派生值同时渲染
  进行 config/路由(行自描述,不是猜上游默认 —— 同一派生喂 export
  与行,不存在猜错形态)
- 同 env 多声明:同文件去重(一个 ZHIPU_API_KEY 喂 LLM 路由 + 搜索
  后端),不同文件 → 求值期 throw(配置漂移)
- 文件缺失 → 不 export,provider 按请求报结构化错误(上游惰性设计;
  与 MCP 通道 fail-loud 语义不同:那里注入不齐 boot 必炸)
- 轮换即生效:每次调用现读,优于 EnvironmentFile 的启动快照

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
├── subagents.nix   # subagents 实例表(可选)
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
