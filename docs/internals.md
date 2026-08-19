# nixdsh 内幕:设计准则与上游实证

> 维护者文档:设计裁决的理由、上游源码实证、调研结论与运维手册。
> 用户文档见 [README](../README.md)(配置指南/示例/已知限制)。
> 上游插件机制本体调研另见
> [deepseek-harness-plugin-research.md](deepseek-harness-plugin-research.md)。
> 「实测 rc.X」标注 = 该事实最后一次源码核对的版本(rc.5 = 08-13,
> rc.6 = npm-only,rc.7 = 08-17 `99f6f02`)。

## 仓库布局

```
nixdsh/
├── package.nix        # dsh CLI:nixpkgs#552467 基座(rc.7 源码 + 上游 lockfile
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
│   ├── names.txt      #   手动清单 owner/repo [subpath] [face=] [roster=]
│   ├── update.py      #   updater:tag 优先/HEAD 回退 + prefetch + 子模块/元数据物化
│   ├── generated.nix  #   机器生成,勿手改
│   └── overlay.nix    #   → pkgs.dshPlugins.<packageName>
└── plugins-modules/   # per-plugin typed module(按需,nixvim modules/plugins 同构)
```

## 设计准则:插件形态与通道选择

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
份中性默认,在 dsh-tui/cordis.yml:92 又有一份强意见默认 ——
`thinking: enabled` + `reasoningEffort: max`)。行归属哪个包无关紧要,判据
只看"这行是否未经你的声明就在树上"。因此 `inBoxPlugins` 的禁用行进
**所有 profile** 的用户 patch 层:两棵树里的同 id 行都被翻掉,没有该行的
树 warn+skip —— 一行声明天然覆盖多源,无需 per-face 重复。

**face 树 ≠ profile 树,判据永远对着最终树说话**(组合规律见 README
核心概念:交互面 profile = base 全套行 + face 树叠层,三 face 实测
一致)。dsh-tui 自带树不建立在 dsh-base 上、必须自带全套运行时行,但
tui profile 的最终树里 base 行都在 —— 单包树只是层的来源,行归属哪个
包无关紧要。

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
provider 全注册(模型可手切,活备选);webSearch/webFetch 侧仅选中者
启用(后端 insert 行与包源只在选中时进树,未选中者**不出任何行** ——
行从未存在,禁行只会换来 boot 期 "patch: entry not found" 警告)。
⚠ 该策略的前提是上游**无运行时 provider 切换**(dsh-web 实证:
`searchProvider` 是行 Config 非命名空间段,构造器定格)—— 若上游
将来支持热切,策略改为"声明即在,选择器热切"(lib/webseam.nix 注释
有同步标记)。

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
启用)已落地,见 README「网页搜索」节。

**迁移注记**:`webSearch` 默认 null 意味着三 face 的 `web_search` 工具
默认不再注册(base 树虽自带三行)—— 需要搜索的用户写
`webSearch = "deepseek-official";`(零配置,运行时配 key)找回。这是
显式哲学的代价,明确选择不改。

## web 缝深析(search/fetch 对照、SSRF、tool-web 三 face 三态)

`ctx.web` 是**一个缝两个操作**(dsh-web README:17 原话:"one seam …
one provider-selection policy owner"):search/fetch 两套同构机制,
共用选择器策略、错误码词汇(`WEB_PROVIDER_*`)与执行时分发 —— 差异
只在生态现状。

| | search 缝 | fetch 缝 |
|---|---|---|
| 注册表 | `searchProviders`(exa/zhipu/deepseek 在填) | `fetchProviders`(rc.6 零注册者) |
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

**远端 reader 型 fetch provider 无 SSRF 面**(如 Zhipu web_reader
包装):抓取发生在 provider 服务商的网络(bigmodel.cn),不是本机 ——
经典目标(本机回环/内网/云元数据)从服务商网络不可达;本机唯一网络
活动是到 MCP 端点的出站 HTTPS。上游"provider 自负 SSRF 责任"对这类
provider 平凡满足(不从本地网络抓取,防护清单零条适用)。

**已知限制:web face 的 preset 挂独立 tool-web,patch 层不可达**(实测
rc.6;**对称面:开保险丝的 patch 行同样不可达** —— 解法见「roster
接管与能力行重放」节,fetch:true 经 preset 物化穿透)。`webSearch = null`
禁三行(`web`/`web-search-deepseek`/`tool-web`
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

## 会话事件封闭集与日志手术手册

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

## face 树收口(强一致性教义)

**交互树(face tree)只能由 face 插件生成**;手写 `profiles.<name>` 是
非交互命名组合的通道(base + 功能插件 + patches),两者不重叠。

为什么收口(此前是软一致性 —— 双通道各自合法,靠撞车 assert 兜底,
留下三个漏洞):

- **per-插件选项恒有锚**:`plugins.dsh-tui.defaultPreset` 挂在交互
  插件上,树由它生成,选项永不失焦(face 改名经推导链自动跟随)
- **树生命周期严格绑定插件**:enable/disable 即树的存在/消失,
  无"无主 tui 树"形态
- **一棵树恰一个 owner**:stamp/物化/孤儿清理语义无歧义

检测与边界(eval 期 throw):手写 profile 的 plugins 里嵌 face bundle
(in-box 字符串命中 web-app/headless,或 derivation 源带
`passthru.dshFace`)。路径源无元数据不可检;`userPatchesFile` 是全权
委托同样检测不到 —— 这两处是文档纪律:交互 bundle 一律走插件通道。

## roster 接管与能力行重放(preset 层穿透;上游闭门,本地永久机制)

⚠ **本节机制是本地永久机制(roster 接管),不是过渡补丁**。上游
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
  声明与发现撞名 → 显式胜;**`excludedPresets` = 源级物理剥离**
  (registry.withPresetsExcluded:preset 目录从插件源移除 —— 播种器
  ensurePackagedPresets 只认包内 presets/,目录没了就种不出来;
  这是唯一的真 opt-out,上游无 suppress 面);排除特定 preset 用
  `plugins.<name>.excludedPresets`,排除 id 不在 shipped 集 → eval
  throw;全禁接管(保留播种原件)用 `plugins.<name>.presets = false`
- **上游跟随**:flake bump → source 包变 → farm 重建,与 profile
  的 base+userPatches 完全同构;disabled/insert 形态行不重放(全局
  树语义)
- **耦合注记**:两行舞对 base 行 id `"agent-presets"` 硬耦合 ——
  上游改名则 disable 行 warn-skip + 双服务共存炸(loud,非静默)
- **播种器与剥离**:dsh-tui 的 `ensurePackagedPresets()` 在 apply()
  无条件跑(无 config 门),只认**包内 presets/** 目录,user 根缺
  即种、revision 变即换 —— roster 无 suppress 面,"隐藏 shipped
  preset"在上游不可表达。真 opt-out 只能做在打包层:excludedPresets
  经 registry.withPresetsExcluded 物理剥离源目录(播种器无从种、
  发现无从扫、farm 无从接管)。user 根的历史播种副本剥离后成孤儿
  (播种器不再触碰,目录不会被清)→ 一次性手动删除
- **UI 标签语义**:preset 菜单的"内置"是 trust 二值不是出处 —— farm
  全体(system trust)显示内置样式,与 provenance 无关;插件携带的
  preset(如 liangshen)显示自己的 name/描述(不在上游本地化表),
  手写的(user 根)带 `· 用户` 后缀。真出处账在 dsh-presets 命令

## 分化轴调研结论(为何只有全局均一 + per-preset 逃生口)

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
恢复);② 手写 profile 树与 headless 树无 roster 语义(设计:非交互
组合 / base 无 agent-presets 行 —— 舞的资格按 face 元数据判定:
in-box 表实测(web 有/headless 无)、registry 收录时 `roster=` 标记、
`plugins.<name>.presetRoster` 显式覆盖,缺省接管)。

## subagent 机制调研(master@47f9438 实证)

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

**平面归属(印证两平面教义,standard preset 注释原文自证)**:
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
逃生口的教科书用例;③ permissionMode 的隐式下传见 README 该节 caveat。

## "会话默认"型 settings 命名空间全景(实测 installSettingsSection 扫描)

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

## 密钥三级链条(实测 rc.6)

`mcpServers` 的 secret 形态(`{ secretFile; prefix? }`)设计目标是
**store 工件零密钥**。链条三级:

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

## 上游化路线

nixpkgs#552467 合并后:删 `package.nix`,overlay 改 `dsh = prev.dsh;`,
其余(模块/lib/插件机制)原样。
