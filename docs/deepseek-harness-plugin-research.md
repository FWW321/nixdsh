# DeepSeek Harness (dsh) 插件机制调研

> 调研对象:[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)(下称 dsh)。
> 资料来源:上游仓库源码与 docs/(cordis-primer、cordis-tutorial、app-boot、bundle、capability-seams、
> event-producer-consumer、agent-lifecycle、tool-execution-pipeline、subsystems 等一手文档),
> 以及本仓库(nixdsh)对 rc.5-rc.7 的源码实证。
> 第二轮深读(2026-08,master)补齐:fiber 生命周期、dsh-scope 作用域链、事件全景、
> 工具守卫管道、动态 Cordis 插件(vm 沙箱)、客户端插件图(`dsh.client`/`__DSH_BOOT__`)。
> 本文聚焦 "Everything is a Plugin" 架构下的插件机制本体。

## 0. 一图流总览

```
dsh --profile <name>
  │
  ▼
$DSH_HOME/profiles/<name>/           ← profile = 一个目录(可写、机器本地)
  ├── package.json                    ← dsh.profile.bundles(有序 bundle 层表)+ 第三方依赖
  ├── node_modules/                   ← pnpm 安装的 out-of-tree 插件
  └── cordis.patch.yml                ← 用户 patch 层(HMR 热重载)
  │
  ▼  组合(在空根上按序叠 patch)
dsh.profile.bundles 各层 patch(dsh-base → dsh-web-app/dsh-headless/…)
  → profiles/<name>/cordis.patch.yml
  → $DSH_HOME/cordis.patch.yml(home 级,更高)
  → --patch overlays(最高)
  │
  ▼
组合树 = 有序 entry(行)列表 —— 行是 {id, name, config, disabled}
  │
  ▼  Cordis Loader 挂载
每个 entry 解析为 Cordis 插件(npm 包/相对路径),并发挂载为 fiber
   │  inject 声明依赖 → 服务(ctx.tools/ctx.llm/ctx.settings/…)就位
   │  apply(ctx) 注册:工具 schema、prompt 段、settings 命名空间、provider…
   ▼
运行期四套组织机制(§4):
   ① dsh-scope:每个 Agent 一棵注册视图(agent.ctx),链 agent→preset→global,
      注册向下继承、事件向上放行;realm 隔离 preset 私有服务
   ② 事件:agent/*(waterfall 拦截)+ session/*(持久事实)+ tools/*、fs/* 等能力缝
   ③ 工具守卫管道:pre-execute → approval → 单调 guards → execute → post-execute → result
   ④ agent 循环:turn/step 状态机,agent/inject() 供给模型上下文
   另有两条旁路:动态 Cordis 插件(agent 内存中自写自挂,vm 沙箱,§3.7)
              客户端插件图(dsh.client 双面包,__DSH_BOOT__,§3.8)
   │
   ▼
一棵完整独立的运行时进程(web/headless 各自 boot,无共享守护进程;
共享层是文件系统 $DSH_HOME:settings.yaml、凭证、会话存储)
```

## 1. 基座:Cordis 插件框架(vendored)

dsh 的"插件"不是自创概念,而是 [Cordis](https://cordis.nzsh.in)(vendor/cordis,与 loader/include/group 等一起 vendored 进仓库)。官方 primer(docs/cordis-primer.md)用五个思想概括:

1. **插件 = 实现 Service 的对象**。可以是一个带可选 `inject` 与 `apply(ctx)` 字段的函数,也可以是一个 `Service` 子类;Cordis 把它的生命周期挂进当前 context。
2. **context = 服务仓库**。服务认领稳定的 `ctx.<key>`(如 `ctx.tools`、`ctx.llm`、`ctx.sessions`、`ctx.settings`),其他插件按键查找服务而非 import 具体实现 —— 面向接口的组合。
3. **依赖用 `inject` 声明**。声明了所需服务的插件会等到服务存在才激活,加载顺序由服务需求表达,不需要手工 boot 序列。
4. **类型化事件通信**。四种分发模式,模式是事件公共契约的一部分:

   | 模式 | await? | 顺序 | 返回值 |
   |---|---|---|---|
   | `emit` | 否 | 注册序观察 | 无 |
   | `waterfall` | 否 | around-中间件(`next()` 委托/短路) | 有 |
   | `parallel` | 是 | 并行 | 无 |
   | `serial` | 是 | 注册序 | 有(首个非空返回胜出) |
   | `bail` | 否 | 注册序,首个非空返回即止 | 有 |

   (`bail` 见 cordis-api/events.md 五模式;宿主面事件以四模式为主,bail 现用于客户端面如 `slash/input-begin-command`。)waterfall 教义:只观察/注解的 listener **必须** `next()`;不 `next()` 即蓄意短路;单决策事件(如 `approval/request`)里短路即设计;`prepend: true` 仅当必须先于普通注册运行。

5. **注册皆可逆 effect**。prompt 段、工具 schema、adapter、provider、listener 都经 `ctx.effect()`/`ctx.on()` 安装,重载与卸载按逆序可预测地回滚(HMR 的根基)。

实践规则:行为封装进插件 —— 工具管道事件归 `ctx.tools`,模型流式归 `ctx.llm`,拦截与策略走事件,直接能力调用走服务方法;每个注册都要有 disposer。

### 1.1 Loader 与 include:cordis.yml 即组合树

文件化的组合由 `@cordisjs/plugin-include`(vendor/include)承载:读 YAML/JSON,变成 loader entries,文件可写时还能回写更新。**entry(行)格式**:

```yaml
- id: timer                    # 行 id:patch 寻址的锚(组合树内唯一)
  name: '@cordisjs/plugin-timer'  # name:插件解析名(npm 包名或相对路径)
- id: app
  name: ./plugins/app          # 相对路径相对 config 目录解析
  config:                      # config:该插件实例的配置(整行替换语义,非深合并)
    message: hello
  # disabled: true             # 禁用行(在树上但休眠)
```

- `@deepseek-ai/cordis-plugin-include` 把 `!!js` 解析为表达式节点;Loader 在挂载决策时对 `disabled` 插值(loader context),在 entry 激活后对其 `config` 插值(插件 context,可引用 `ctx.serviceName`);其余元数据(name/id/inject)保持字面量。
- **id 的深层语义**:id 是 loader diff 的锚 —— 编辑既有条目与"删除+新增"靠 id 区分;**无 id 的条目每次文件读取都生成新 id**,配置文件一改即被当作删除+新增而重挂(即使自身行未变),所以教程建议一律显式写 id。
- 除 `id/name/config/disabled` 外,行还可带 `inject`(行级依赖)、`group`(嵌套子列表作为一个单元加载/卸载)、`isolate`(给组独立服务 realm,两组可各见不同配置的同名 provider)。
- **行序无加载语义**:条目并发启动,激活顺序完全由服务依赖(inject)驱动。dsh-base 的 patch 头注释明说"行序无加载语义,分组只为读者服务"。
- 裸包名(`@deepseek-ai/dsh-*` 等 npm 包)经 Cordis Loader 内部模块加载器解析:默认从 config 目录解析;封闭运行时传 `bareModuleBaseUrl` 锚定到安装的包树。相对 specifier 恒相对 config 目录。
- patch 可 insert 新 entry,或按 `id` 匹配覆盖既有 entry 的字段(**config 是整块替换,不是深合并**)。

### 1.2 插件模块的三种形态与可选导出

插件本体是 .mjs/.ts 模块,命名导出 `apply`,Cordis 加载时调用 `apply(ctx, config)`:

```ts
// 1. 函数插件(最常用)
export function apply(ctx: Context) {}
// 2. 对象插件
export const objectPlugin = { name: 'object-plugin', apply(ctx) {} }
// 3. 类插件:Service 子类(需暴露服务时使用)
export class MyService extends Service {
  constructor(ctx: Context) { super(ctx, 'myService') }
}
```

可选导出:`name`(诊断显示名)、`inject`(依赖服务名数组)、`Config`(Schemastery schema,兼具 TS 接口与运行时校验器双重身份;校验在 `apply` 之前完成,非法配置抛带路径的 ValidationError,fiber 进 FAILED,进程 fail-loud 退出 —— 插件绝不半配置启动)。`apply` 抛错同样响亮失败;模块无法**解析**(包名/路径打错)只经 logger 报告,启动早期可能丢失 —— "新加条目无效果"先查拼写。类插件另有 `static inject`、`static Config` 与 `async * [Service.init]()` 生成器钩子(`yield () => cleanup` 交出清理器)。

### 1.3 fiber:插件实例的生命周期单元

vendor/cordis/src/fiber.ts 是理解挂载/卸载/HMR 的钥匙:

- **状态机**:`PENDING → LOADING → ACTIVE → FAILED / UNLOADING → DISPOSED`。`inject` 未满足的插件停在 **PENDING(合法等待态,非错误)**;`_refresh()` 以全部被注入 fibers 的 uid 计算 **epoch 字符串**,依赖集合变化即触发重载决策。
- **依赖追踪在加载后持续**:provider 卸载 → 依赖者随之卸载,provider 回归 → 依赖者重载。这是"配置层热换 `ctx.shell`/`ctx.fs` provider"能成立的根基。
- **事务性行更新**(`Entry.update`):仅 config 变更走原型交换 + `fiber.update`;`name`/`inject`/`group` 变更**先 import 新模块、后 dispose 旧实例 + 启新实例**,失败回滚到旧插件。组更新(`EntryGroup.update`)用 `Promise.allSettled` 并发调和整棵子树,任一失败回滚新增并重建旧行 —— loader 按 id diff 出的"增删改"每一步都是事务。
- **可逆注册的四种 effect 形态**(`ctx.effect` 入参可返回):单个 disposer 函数 / promise / (异步)生成器逐个 `yield` disposer。同步 disposer 逆注册序执行;多个异步 disposer 并发。`ctx.on` 本身就是 effect;产品级注册方法(`ctx.tools.register`、`ctx.llm.registerAdapter`、`ctx.web.registerSearchProvider`)内部全是"生成器 effect + 交出同步 disposer"的惯用法 —— 注册即归还注销器,dispose fiber 即整批回滚。
- **可选依赖三档**:静态 `inject = ['x']`(硬依赖,等不到就 PENDING);`ctx.get('x')`(机会主义探测,如 llm-deepseek 探测 `credentials`,有则用);运行时 `ctx.inject(['x'], cb)`(子上下文回调,`x` 出现才激活 —— tool-todo 用它挂可选的 `sessionProjections`,headless 等无该缝的组合不受影响)。

## 2. 从 Cordis 到 dsh:profile / bundle / patch 三层

### 2.1 profile(档)

profile 是 `$DSH_HOME/profiles/<name>` 下的目录(`$DSH_HOME` 取 `$DSH_HOME` env,缺省 `~/.dsh`),内含:

- **package.json** —— 两件事:① `dsh.profile.bundles`:有序 bundle 层表;② out-of-tree 插件的 `dependencies`(pnpm 安装进 profile 的 `node_modules`)。
- **cordis.patch.yml** —— 该 profile 的用户 patch 层。
- **pnpm-workspace.yaml** —— `initProfile` 写入 `nodeLinker: hoisted` + `autoInstallPeers: false`,让树外插件拿到扁平 node_modules、缺失 peer 沿父级解析落到 healed symlink 农场(全进程共享同一 cordis 实例)。
- **cordis.yml** —— 启动器**每次 boot 重写**的空根(`[]`),只为把 Loader 的 `baseUrl` 锚定在 profile 目录(vendored Loader 的树回写可能把组合结果烤进文件,故每次重置)。

`web` 与 `headless` 两个 profile 首次使用时从 shipped 模板自动初始化(`PROFILE_TEMPLATES`);其他名字必须经 `dsh plugin`(即 `initProfile`)创建,否则 fail-loud。`healProfilesModuleFallback` 维护扁平的 `$DSH_HOME/profiles/node_modules`(每个包一条 symlink),让裸插件名通过 Node 普通父级解析即可命中,不须 pnpm 管理 in-box 包。

### 2.2 bundle(捆)

bundle 是一个 npm 包,package.json 声明 `"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }` —— **bundle 的本体就是它的 patch 列表**(部分 bundle 还带运行时胶水插件,由其 patch 挂载)。in-box bundles:

| bundle | 角色 |
|---|---|
| `@deepseek-ai/dsh-base` | 所有 profile 第一层的共享核心:模型 adapter、`agent-default-model` 共享选择器、工具、持久化、策略、settings/credentials、遥测、宿主级 subagent provider —— 全部以 insert 行打在空根上 |
| `@deepseek-ai/dsh-web-app` | 浏览器交互面:web patch 层 + 运行时胶水插件(注意:它会把宿主层的模型面工具如 tool-web 整行禁用,改由每个会话挂载 preset 提供) |
| `@deepseek-ai/dsh-headless` | base 之上的直接一次性任务模式,无 Host/Web 层,挂 `headless-runner` |

bundle 解析双锚:dsh 安装优先,其次 profile 自身 `node_modules`。列在 bundles 里却没有 bundle 声明的包 → fail-loud。

### 2.3 patch 层与优先级链(官方语义)

组合在**空根**上按下列顺序叠 patch(后者胜):

```
dsh.profile.bundles 各层(bundle 序)      ← base insert → mode bundle
→ profiles/<name>/cordis.patch.yml       ← profile 用户层
→ $DSH_HOME/cordis.patch.yml             ← home 级用户层
→ --patch overlays                       ← 命令行覆盖
```

patch 文件是"顶层 YAML 数组",元素为 include `PatchOptions`(按 id 定向的 config 覆盖、`insert` 列表、允许 `!!js`):

- **id 定向 patch 替换整行 config** —— 保留字段必须重述,没有深合并层(dsh-base README 明确列为已知限制/契约)。
- **同一 patch 列表内 `insert` 的行立即进入索引**,后续 patch 可直接按 id 定向它们(dsh 对 vendored include 的本地化修改 #11)—— 这是"空根 + 多层 patch 在同一 include 级叠加"能工作的前提。
- patch 命中不存在的行 id → stderr 警告(不炸)。
- 空文件或纯注释文件会 throw(解析结果不是列表);要禁用该层写 `[]`。
- **同 id 多源行是常态**:同一行 id 可出现在多棵树(如 `llm-deepseek` 在 dsh-base 有一份中性默认,mode bundle 或第三方层可再给出强意见默认),同 id 后行胜出。
- 每次带 profile 的 boot 都用 `watchUserPatches` 让 `cordis.patch.yml` 保持 live:文件增删改触发事务性全量重组(HMR),坏读/坏解析保留上一棵好树并广播 `hmr/config-update-failed`。

### 2.4 插件包的"在场"三形态与启用路径

实测(rc 期;master 结构未变),一个包可以在系统中以三种方式在场:

| 形态 | 例子 | 在场方式 | 启用路径 |
|---|---|---|---|
| 树行自带 | `llm-deepseek`、`web-search-deepseek` | base/face 树里有行 | 行已在(默认启用);禁用须出 disable 行 |
| **装而未挂**(shipped but unrouted) | `dsh-mcp-client` | 随 CLI runtime 发布,任何树无行 | insert 行(loader 从 CLI 自身安装解析包);无行可 disable,卸载 = 删声明 |
| 完全外部 | `@tonydua/dsh-web-search-exa` | 不随 CLI、不在任何树 | insert 行 **+ 包源进 profile**(pnpm 安装或 nix 侧物化) |

判别维度之二:插件是**配置承载型**(无配置 → 功能为零或必败,如 mcp-client 零 server = 零工具、llm-deepseek 无 key 每请求必败)还是**裸用型**(零配置即完整工作,如 tool-bash/tool-fs/tool-todo)。

### 2.5 boot 序列(packages/boot/app-boot)

`dsh` 是薄启动器,真正的 boot 胶水在 `@deepseek-ai/dsh-app-boot`:

1. `loadLayeredEnv`:继承 env > 调用目录 `.env` > `$DSH_HOME/.env` 快照合并(拒绝 bootstrap-only 变量)。
2. `mountRootInclude`:注册 `cordis:include`/`cordis:group` 内建,挂载根组合。
3. 逐层应用 bundle patch → profile patch → home patch → overlay(`composeEntries` 用 include 自己的 `applyEntryPatches` 在空 entry 列表上做,保证"组合/旗标推导/config dump 与实际 boot 不漂移")。
4. Loader 并发挂载全部 entry;`assertEntriesLoaded`/`assertEntriesActivated` 审计:enabled 却无 fiber 的行、激活失败的行,连原始栈一起 fail-loud(`installFailLoud` 收敛成一行标注 stderr + exit 1,并给终端占有面恢复终端的机会)。
5. `watchUserPatches` 保持用户 patch 层 live。

生命周期细节:

- **并发挂载 + 依赖驱动激活**:声明 `inject` 的插件等所需服务出现才激活;inject 永不满足的插件处于 **PENDING 而非报错**(提供者稍后挂载是合法状态)。诊断法:遍历 `ctx.registry.values()` 的 fibers 找 `FiberState.PENDING`。
- **HMR**(`@deepseek-ai/cordis-plugin-hmr`):文件保存 → 卸载旧实例(全部 effect 回滚)→ 加载新代码 → 重新 `apply`。编辑 cordis.yml 本身也被捕捉:loader 按 id diff 条目,只挂/卸/重配变更部分。
- **fail-loud 审计**:`assertEntriesLoaded`(enabled 却无 fiber 的行)、`assertEntriesActivated`(激活失败行带原始栈、pending 行带未满足服务列表);Loader 拒绝与终端释放经 `installFailLoud` 合并为一条标注 stderr + exit 1,并给终端占有面恢复终端的机会。
- **平台门控实例**(base patch):`bash-sandbox`/`tool-bash` 带 `disabled: !!js process.platform === 'win32'`,pwsh 双子行反向 —— 一份 patch 实现每平台恰好一套 shell 栈。Windows 恢复 bash 须完整配方(禁 pwsh 两行且重启 bash 两行):两个执行器族注册同一 `bash` 服务,不完整配方加载即炸;同理 fs-sandbox 旁再挂 dsh-fs-local 会双重注册 `ctx.fs`。
- **服务去重是硬约束**:同 fiber 生命周期内一个 ctx 键只能被认领一次,重复注册即加载失败("already registered")。

诊断面:`dsh --dump-default-config` / `dsh --dump-config` 不 boot 直接看组合树;`renderConfigDump` 逐文件逐层标注(`# ==` 注释),patch 落空告警。

## 3. 插件能扩展什么(能力缝全景)

### 3.1 服务缝(ctx.<key>)+ 能力缝(seam)

**缝的定义(docs/capability-seams.md)**:一个 seam 是可替换能力,须同时具备三角色 —— Service Definition(声明接口)、Service Provider(实现)、Consumer(使用,通常是模型可见工具);只做一个角色不成缝,加能力要设计齐三角色。主要缝及 ctx 键(owner → 实现):

| 缝 | ctx 键 | 实现 provider |
|---|---|---|
| LLM | `ctx.llm` | llm-deepseek / llm-pi-ai / llm-replay |
| 文件系统 | `ctx.fs` | fs-local / fs-sandbox / fs-e2b |
| 子进程 | `ctx.subprocess` | subprocess-local / subprocess-e2b |
| shell | `ctx.shell` | bash-local / bash-sandbox / pwsh-local |
| 终端 | `ctx.terminals` | terminal-bash |
| 沙箱 | `ctx.sandbox` | sandbox-local |
| 审批 | `ctx.approval` | user-approval / acp 桥 |
| settings | `ctx.settings` | settings-file |
| 凭证 | `ctx.credentials` | credentials-local |
| skills | `ctx.skills` | skill-filesystem / skill-badge |
| web | `ctx.web` | web-search-deepseek / web-search-exa / web-search-perplexity / web-fetch-http |
| subagent | `ctx.subagents` | spawn/fork-in-process、acp、codex、claude-code、dsh-sdk 六种 provider |
| jobs | `ctx.jobs` | jobs-local |
| 压缩 | `ctx.compaction` | compaction-basic |
| 存储 | `ctx.storage` | storage-json / storage-sqlite |
| 会话持久化/查询/遥测 | `ctx.sessionPersistence` 等 | jsonl / sqlite / otel |
| 其他 | `ctx.lsp`、`ctx.codeRuntime`、`ctx.workflowEngine`、`ctx.spillStore`、`ctx.attachments`、`ctx.userQuestions`、`ctx.directoryPicker` | lsp-local、code-runtime-worker、workflow-worker-thread… |

设计威力:文件系统与子进程 provider 共享一个执行世界 —— 指向远程沙箱即连带迁移 Bash/PTY/LSP,无需 provider 分叉。除服务缝外还有**事件缝**(`fs/*`、`tools/*`、`telemetry/*`、`agent/*` 系列),用于附加策略与拦截而无需导入循环。

"一个缝一个 provider 选择策略所有者"(docs/capability-seams.md):如 ctx.web 的 search/fetch 两操作同构(注册表 + 选择器 + `WEB_PROVIDER_*` 错误码词汇)。fetch 缝演进:rc 期零注册者(SSRF 责任归 provider);master 已有 in-repo 包 `dsh-web-fetch-http`,但属"装而未挂"形态 —— 无任何 bundle 行挂载,base 的 tool-web 行仍带 `fetch: false` 保险丝,要启用须自行 insert。

### 3.2 settings 命名空间(installSettingsSection 通道)

用户可编辑配置走 `ctx.settings`(packages/settings):插件用 `register(ns, schema, {base, applies, validate})` 注册一个 kebab-case 命名空间,拿到 owner scope(`get/watch/update/replace/mutate`)。解析序:**schema 默认 → 组合层 base(entry config 子集)→ 用户层**(settings.yaml 里的段)。要点:

- 组合配置留在 cordis.yml;命名空间只承载**用户可编辑子集**。
- 用户层恒胜组合层;`replace({})` 重置回继承;`update` 只并进用户层不碰 base。
- `describe({redactSecrets:true})` 驱动配置 UI(表单由 schema 渲染);secret 字段 wire 上永不外发,写路径用 path op(`mutate`)避免"从脱敏视图整段重建导致删密钥"。
- 写冲突用 `expectedRevision` 乐观并发;外部编辑(settings-file provider 观察)以 `source: 'provider'` 提交,`settings/updated` 事件 deep-equal 门控。
- 实测注册面共 9 家命名空间:`permission`、`agent-presets`、`agent-default-model`、`agent-loop`、`shell`、`llm-deepseek`、`pi-ai`、`web-search-deepseek` 等。
- 注意(rc.6 期实测,Web UI 细节可能随版变动):Web Plugins 页的表单卡是前端硬编码的(只有 agent-loop/shell/web-search-deepseek 有卡),第三方命名空间装了也没有专属表单 —— Plugin Inventory 页(loader 条目只读投影)会列出"已启用",配置走 settings 文件/host API;`adding-a-settings-card.md` 则给出了正规的 `settings.plugin.item` slot 注册卡路径。

### 3.3 MCP 接入

`dsh-mcp-client` 是"装而未挂"形态:随 CLI runtime 发布、默认沉睡;每个 MCP 服务器对应一个插件实例(insert 行),工具注册进 `ctx.tools`,模型以 `mcp__<serverName>__<rawName>` 命名调用(与 Claude Code/Codex 同形)。

stdio 版 insert 行(官方 README 原例):

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio
    command: npx
    args: ['-y', '@modelcontextprotocol/server-github']
    env:
      GITHUB_TOKEN: !!js process.env.GITHUB_TOKEN
```

streamable-http 版:

```yaml
- id: mcp-web
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: web
    transport: streamable-http
    url: http://localhost:3000/mcp
    headers:
      Authorization: !!js '`Bearer ${process.env.MCP_TOKEN}`'
```

要点:config 字段还有 `cwd`、`toolCallTimeoutMs`(默认 60000)、`failOnStartupError`、`reconnect.{enabled,initialDelayMs,maxDelayMs,maxAttempts}`(指数退避,连接存活超 maxDelayMs 重置预算);`serverName` 须 `[A-Za-z0-9_-]{1,32}` 全局唯一;工具名超 64 字符或含非法字符时规范化并附 12 位确定性 hash(绝不冲突、不因连接顺序改名);stdio 桥接启动子进程前**剥离疑似凭据的环境变量与所有 `DSH_*` 变量**;HMR 热切换断开重连,`tools/list_changed` 整代替换工具集(失败保留上一代);只桥接 Tools,Resources/Prompts 暂缓。headers/env 是字面量 map + `!!js`(密钥应在行 config.env 里经 env 间接引用,nixdsh 用 store 占位符 + 物化期注入解决)。

### 3.4 agent preset(会话级插件组装)

preset = 一个会话 Agent 的插件组装:`agent.cordis.yml`(组合树)+ `preset.yml`(元数据)+ 任意 `.mjs` 插件文件,纯文件零构建,宿主 loader 负责解析。**热发现**:运行中新增 preset 免重启(user 根 `$DSH_HOME/.agent-presets/`;发现不带 memo,每次 `list()`/`resolve()` 重读根目录,坏 YAML 的 preset 带 `broken` 原因列出而非跳过)。"a preset IS a composition" 是 API 级承诺 —— `mountPreset` 签名只有 `{path}`,无任何 config 覆盖参数;行解析序 agent → preset → global,近者遮蔽远者。挂载细则:

- roster 服务(`ctx.agentPresets`)按进程只做一次 standing mount,各会话经 `dsh-scope` 父链加入;同 preset 的工具/prompt 段/投影单元全进程仅一份。
- 子代理通过**同步的** `composeFrom()` 绑定父组合而非重新 mount(重 mount 会碰组合文件已编辑/已删除两种偏差)。
- 挂载拒绝三种情况:无 agent scope 的目标(会把工具注册成全局)、永不激活的行、向 root realm 发布服务的行(应使用 isolate realm 或放回宿主组合)。
- 模块解析三规则:裸包名锚定宿主组合的 baseUrl(preset 目录在用户 home 下,Node 向上查找够不到 harness);相对路径锚定 preset 自身目录(插件文件与技能目录随目录走);绝对路径转 `file:` URL 再 ESM import(兼容 Windows 盘符/UNC)。
- 创作只允许整目录 copy(`copy(from, id, name?)`);组合文件的 `write()` 被覆写为 no-op,防止 Loader 把会话运行时状态写回共享文件。

### 3.5 skill、subagent、扩展运行时

- **skill**(packages/skill 四包:`dsh-skill` 服务定义 / `dsh-skill-filesystem` 本地 provider / `dsh-skill-badge` 打包徽章 / `dsh-tool-skill` 消费者)。技能格式:kebab-case 名,目录束 `<name>/SKILL.md` 或扁平 `<name>.md`(不递归);frontmatter 键 `disable-model-invocation`/`user-invocable` 归一化为调用策略。**发现优先级(rank 小者胜)**:

  | rank | 来源 | 根目录 |
  |---|---|---|
  | 100 | project-dsh | `<projectRoot>/.dsh/skills` |
  | 200 | project-agents | `<projectRoot>/.agents/skills` |
  | 300 | custom | `Config.customSkillDirs` |
  | 400 | user-dsh | `<dshHome>/skills` |
  | 500 | user-agents | `<agentsHome>/skills` |
  | 600 | bundled | `Config.bundledSkillDir` |

  projectRoot 取最近含 `.git` 的祖先。模型侧:会话首个 `agent/pre-step` 注入 `<available_skills>` 目录(仅 name+description);目录 digest 变化经 `agent.inject()` 全量替换;模型调 `skill({name})` 工具时才加载完整定义并二次校验。也可运行时 `ctx.skills.register()` 编程注册。
- **subagent**:宿主面 `dsh-subagent`(ctx.subagents 注册表、durable descriptor)+ 模型面委托工具行(dsh-tool-subagent 每 transport 一实例)。child 组合强制 join 父 preset;child 权限在委托边界一次性固定(approval 钉死 never)。
- **extensions**(packages/extensions):自指工具族,详见 §3.7 —— `cordis-host-runner`(定义注册表 + `node:vm` 沙箱,`ctx.dynamicCordisRunner`)、`cordis-client-runner`(浏览器半运行器)、`tool-cordis`(模型面 `cordis_define`/`cordis_run`/… 工具族,让 agent 在**内存中**定义并挂载自己写的插件 —— 不建文件、不装包、不改 cordis.yml,重启即逝)、`ui-cordis`(面板与只读卡)。即"插件管理插件"的元能力。

### 3.6 会话事件(生成式已知集;树外禁区)

`KNOWN_SESSION_EVENT_TYPES`(packages/core/session/src/known-event-types.ts)是**生成物**:`gen-persistence-catalog` 从本仓库全部 `SessionEventMap` 声明合并成员生成,是"该构建认识的词汇表",不是硬编码封闭清单。持久化**读路径**拒读包含未知且未标 `ignorable` 的事件类型的日志(coordinator.ts:"可能由更新版 harness 写入,拒绝对其解读")—— 这是前向兼容守卫,不是禁止扩展。**仓库内扩展是文档化正道**(architecture.md:"Add durable session state → extend SessionEventMap; render and replay from the log";`agent/inbox/spliced`、`todo/write`、`hook/*` 等皆由此入表);**仓库外**插件的注册面 deferred —— 树外自定义事件类型确实会毒化日志(读端拒读整份日志),by construction 不开放。

### 3.7 动态 Cordis 插件(自指工具集:agent 写插件挂进自己的进程)

packages/extensions 四包让模型本人检视并扩展自己运行所在的 cordis 运行时。**与 §2 的静态组合正交**:动态包不建 Plugin 文件、不装 npm 包、不改任何 cordis.yml、不活过进程重启、不能自动"转正"(README 原话:要保留实验,请 agent 走常规插件开发流程)。

**工具族**(`tool-cordis`,`inject = ['tools','systemPrompt','dynamicCordisRunner','cordisInspect']` —— 无 runner 的组合永不激活):

- `cordis_inspect_list` / `cordis_inspect_query`(platform host|client)/ `cordis_inspect_self`(三档深度,含动态包完整源码)—— 只读检视,数据来自**生成的编译期 API 目录**(`src/api-catalog.ts`,AST 投影全仓库 cordis 声明)与活服务求交;
- `cordis_define`(定义)/ `cordis_run`(mode `run|update`)/ `cordis_stop` / `cordis_undefine` —— 生命周期动词;
- 系统提示段 `tool:cordis`(order 115)教完整工作流;`@pluginId` 引用钩子:`agent/pre-step` 监听器扫描用户消息中 `/@([a-z]{3,6}-\d+)/`,注入 `<cordis_dynamic_plugin_context>` 元数据(不含源码)—— 用户一句话即可指向既有动态插件。

**定义模型**(cordis-host-runner/src/registry.ts):`DynamicCordisPlugin`(pluginId = `<prefix>-<n>`,prefix 由模型起 3–6 个小写字母)下挂**不可变版本** `DynamicCordisDefinition`(packageId = `pkg-<n>`);一次激活尝试 = pluginRunId。`define` 只做语法预检(`new Script` 编译,未铸 id 前拒掉不可解析代码)**不运行任何东西**;存储立场:注册表纯进程内存,会话日志只携带元数据**永不携带代码**;跨会话隔离:别的会话的插件"读作不存在而非被拒"。

**宿主沙箱**(node:vm,`vmTimeoutMs` 只限同步段):

- **教学陷阱**:扣留的 Node API 重定向为教学错误 —— `require` → "改用 ctx 服务(`inject: ['fs']` 等)"、timer 全家 → `inject: ['timer']`、`fetch` → `ctx.web`;函数值全局抛错、数据全局保持 undefined(防 `typeof process` 探测引爆);标记版 console(`[cordis:<id>]`);补 btoa/atob/TextEncoder;`instanceof` 跨 realm prelude。
- **ctx 门面**(guard.ts):只暴露生命周期动词(`effect/on/once/provide/timer`)、只读 `tools` 视图、**声明过的 inject 服务**(读 `ctx.fiber.inject`);框架内部(`root/fiber/registry`)扣留;工具定义经 marker 只认自家 `defineTool` 产物,VM realm schema 经迭代式跨 realm JSON 克隆归一(内存有界而非调用栈有界)。
- 信任立场明说:**不是安全边界**,"当 bash 权限看待";宿主半统一挂在一个 `cordis-dynamic` 组 fiber 下,子 fiber 失败即清理不留残骸。

**运行回合**(带浏览器半的包):`cordis_run` → `cordis/request-run` 事件(**只含元数据,代码永不上广播**)→ 浏览器面板应答 `runHostHalf`(幂等,先启宿主半)→ `getClientCode`(唯一取码通道,仅该页)→ `resolveRequestRun` 首答胜出。授权粒度:单勾 = 仅此 package;双勾 = 该插件**未来版本**。异步结局经 `agent.steer()` 注回模型对话(含修复指引:同 pluginId 定义修正版 + `mode:"update"` 激活)。

**浏览器半**(cordis-client-runner):**参数即符号面**的闭包求值 —— `new Function('React','console','styles','host',…traps, code)`;无 JSX(`React.createElement`);`host.call(method, args)` 经 remote 走到自家宿主半 `harness.handle` 注册的处理器(**仅 Client→Host 单向**,基础设施只路由);`styles.insert(css)` 注 `<style data-dyn>` 随卸载移除;载入复用与静态插件**完全相同**的 `__ModuleLoader__`/Loader 机制(id `dyn/<pluginId>`),天然获得激活门控、fiber 清理与状态投影。ui-cordis 提供全局面板(shell.overlay 席位)与 `cordis_define` 只读卡。

### 3.8 客户端插件图(`dsh.client` 与 `__DSH_BOOT__`)

一个包可同时携带宿主半与浏览器半,三个约定协作(**不存在 `dsh.host` 字段** —— 宿主半就是普通 cordis 行):

1. **宿主半 = 根 export**:普通插件;纯客户端包可以是空 `apply()`(cordis-client-runner 即典范,行只为出现在宿主组合树)。
2. **浏览器半 = `exports["./client"]`**:指向 tsdown 共享 preset 产出的 `lib/client.js`(纯度门禁禁止跨插件值导入)。
3. **桥 = package.json `"dsh": { "client": { "platform": "web", "inject": [...], "immediately": bool } } }`**(`parseDshClient` 逐字段校验;inject 是图依赖边,激活权威仍走 cordis 服务等待;immediately 标记 boot 一阶段预取,缺省惰性)。

宿主侧 `ctx.clientModules`(packages/client/modules,`inject = ['webServer','loader']`)四张面孔:

- **增量扫描**(无全量重扫路径):监听 cordis `internal/plugin`(fiber 建/毁)标脏 entry 名,microtask flush 调和;含"非客户端包"负缓存。
- **组图**:每合格包一行 `{id, url: '/plugins/<id>/client.js?rev=<内容哈希>', rev, inject?, immediately?}`;整图再哈希为图 rev。声明了 `dsh.client` 却无构建产物的包激活即败(提示先 build)。
- **bundle 路由**:注册 `/plugins` 前缀路由,`no-cache` 服务 client.js(.map)。
- **index tap**:`<script>window.__DSH_BOOT__ = …</script>` 注入 `<head>` 首位(`<` 转义 `\u003c`,插件可控字符串无法逃出 script 元素)。

浏览器侧:**bundle 执行只注册工厂**(`window.__ModuleLoader__.load({id, factory})`),一切副作用(含 CSS)住进工厂闭包、首次物化执行并记忆化;vendored Loader 消费该模块表完成两阶段 boot(模块面 → 插件面,静默门控)。**名册是组合而非扫描**:哪些 `dsh.client` 包上线由 yml 行决定。

**客户端 HMR**:宿主 hmr 包 stat 轮询(默认 500ms —— 网络挂载没有 inotify 也工作)各 bundle → `rebuilt(id)` → SSE `/plugins/events` 广播;浏览器每帧串行重载一个插件:`invalidate` → `prefetch`(旧 fiber 仍服务时注册新工厂)→ `registry.delete` **先于** fiber 卸载(避开 vendored Loader 自处置分支把行标 disabled)→ 排干旧 fiber → 移除自有 `<style>` → `entry.refresh()` 重挂。依赖级联零触碰:fiber 激活 epoch 串起 provider uid,换 provider 自动级联全部依赖者。

## 4. 运行时机制深入(作用域/事件/管道/循环)

静态组合(§2)之外,dsh 用四套运行时机制把插件能力组织成产品:作用域、事件、工具守卫管道、agent 循环。

### 4.1 作用域系统 dsh-scope(每个 agent 一棵注册视图)

packages/core/scope 是**库而非服务**。`ScopeKey` 是不透明对象 —— 生产中**即 Agent 对象自身**;`createScope(ctx, key)` 挂一个空插件得专有 fiber,再 `ctx.extend` 打上 scope 标签;`scopeOf(ctx)` 就近读标签(undefined = 全局)。agent 循环构造时 `this.scope = createScope(loopCtx, this); this.ctx = this.scope.ctx.extend({ agent: this })` —— **`agent.ctx` 即该 agent 专属的注册边界**(工具/段/变量/监听只进该 agent,dispose 全部回滚)。

- **一条父链,两个方向**(`bindScopeParent`):**注册视图向下继承** —— 子作用域可见祖先层,近者遮蔽远者(`ScopedLayers.chainLayers/merge`);**事件准入向上放行** —— 祖先作用域的 listener 收到全部后代的事件,反向不通。产品中的具体链:**agent scope → preset standing scope → global**。
- **`scopeTarget(base, key)`**:仅路由用的事件载体(组合 `Context.filter` + 作用域谓词);监听者无标签 → 全局接收;有标签 → 仅当它是 key 或 key 的祖先才准入。这让"一个 preset 的常驻组合观察到旗下每个 agent"成为可能,而兄弟 preset 充耳不闻。
- **ScopedLayers**(store.ts):每个作用域感知注册表(ctx.tools、ctx.systemPrompt)一全局层 + 惰性作用域层;`peek` 故意链盲(自身 restriction/guard 不继承祖先);**同一调用上下文同时决定可见性与所有权**;层全空才回收。
- **realm ≠ scope**:realm 是 Cordis 服务存储隔离轴(root realm 共享符号表 vs `isolate` realm 子树私有符号)。preset 挂载审计**拒绝向 root realm 发布服务的行**("须坐 isolate realm 或回宿主组合")—— 防两个 preset 撞名、防宿主读到单一实例;`serviceForAgent` 按 fiber 归属读取某 agent 的 isolate 实例。
- **生成的 scope 不变量**:invariant 伴生包钩住 `internal/dispatch`,配合生成的 scoped 事件表断言"每次 scope 过滤分发必须带载体,且载体键与 payload 命名的主体一致" —— 结构上杜绝路由与主体漂移。
- 安全非目标(README 原话):"Scopes route trusted same-process plugins; they are not sandboxes or authority boundaries."

### 4.2 事件系统全景

事件是第一扩展点,选域是多数改动的第一决策(architecture.md)。分发模式是事件公共契约,声明处 JSDoc 带 `@mode` 标签,生成目录据此核对声明与分发点。三大域(节选 event-producer-consumer.md):

| 域 | 事件 → 模式 | 要点 |
|---|---|---|
| `agent/*`(live 协调) | `agent/pre-step`、`agent/request`、`agent/request-error` = **waterfall**;`agent/turn-stopping` = **serial**(唯一串行检查点,可再导一步);`agent/created|disposed|status|error|inbox/*|session-start` = emit | 全部 scope 过滤;waterfall 听者可改写入消息/拒绝/改请求配置/决定重试 |
| `session/*`(持久事实) | `session/event` = emit;`session/flush` = **parallel**(await 的持久性检查点,无否决);`session/created|disposed` = emit | session/event 是日志广播面,重放/持久化/遥测/投影全从它派生 |
| `tools/*`(能力管道) | `tools/pre-execute`、`tools/execute`、`tools/post-execute`、`tools/code-dispatch-log` = **waterfall**;`tools/result`、`tools/change` = emit | result 冻结只读;change 故意不过滤 |

能力事件:`fs/write-intent`、`fs/edit-intent`(waterfall)+ `fs/observed`(emit);`llm/stream`(waterfall,流式包装点);`approval/request`(waterfall,缺席即 fail-closed 'unavailable');`system-prompt/assemble`(waterfall,返回值权威,唯一 complete 段事后复原)。

**融合分发器**:agent 侧事件经 `agentEvents(ctx, agent, carrier)` 分发 —— payload 自动注入 agent 主体,scope 键与主体结构上不可能漂移;其 emit 绕过 Cordis 默认分发以逐监听器容纳同步抛/异步拒。**消费者信条**:pre-step 听者含 compaction-basic、plan-mode、hooks-claude-code/codex、tool-skill、time-context 等十余家 —— 互不相识,靠注册表服务与事件连接。

### 4.3 工具注册表与守卫执行管道(ctx.tools)

`ToolRuntime`(`inject = ['systemPrompt']`)。注册:`ctx.tools.register(defineTool({...}))` —— `output {schema, render}` **强制声明**;args 由参数 DSL 校验(类型/必填/枚举/嵌套全自动);`exec` 冻结 + 不透明 token(仅 `exec.signal` 可被 around 包装替换);body 返回声明 schema 的唯一规范 JSON 值;基础设施失败用 throw(→ isError)。**注册即 effect,层 = 调用上下文的 scope**:全局 ctx → 全局工具;`agent.ctx` → 该 agent 专属(同名遮蔽全局);dispose 即注销,schema 自动流入 prompt 装配(§4.5)。

管道精确顺序(tool-execution-pipeline.md):

```
tool/call 先入日志 → presentCall(UI)
→ tools/pre-execute waterfall(allow | deny | ask)
→ ask → ctx.approval(缺席/无 agent ⇒ 拒)
→ 单调 guards(注册式守卫,只能拒绝;后位 waterfall 无法翻案)
→ tools/execute waterfall(around dispatch:超时/重试/指标)
→ execute(args, exec)
→ tools/post-execute waterfall(accept | 改内容 | 改值 | block+feedback, +additionalContexts)
→ finalizeContent(定义方,恰一次,仅内容)
→ 物化(无损快照 + deepFreeze)
→ tools/result(emit,冻结含故障)
→ 持久 tool/result → presentResult → 批结算 → additionalContexts 以 user/message FIFO 注回
```

选缝规则:pre-execute = 可扩展 allow/deny/ask 策略;`ctx.tools.guard()` = 单调终拒;execute = 包装 dispatch;post-execute = 变换结果;`tools/result` = 只读观察。调度缝 `[TOOL_RUNTIME_SCHEDULER]` 让循环的并行调度器**策略有序而 dispatch 重叠**(并行池上限 `maxParallelToolCalls`,默认 10,settings 可热调)。

**Code Mode**:`native | code | both`;保留传输 `run_code` 永不入可过滤层;`code` 下模型只见 `run_code` + 一段确定性 TS/Python SDK(tools:sdk 段);模型直呼其他工具名在创建执行时即 UNKNOWN_TOOL —— 早于 pre-execute/审批/守卫("无物可观察或批准一个只会失败的调用");SDK 子调用带 parent token 走**完整管道**;持久日志经 `tools/code-dispatch-log` waterfall(spill 策略在此替换超长内容)。

### 4.4 agent 循环与 turn/step 流

**step = 一次模型请求 + 其工具调用;turn = 零或多步**(architecture.md 原图):

```
turn/start
  认领 next-step 输入 + 一条排队消息
  装配 prompt 段 + 工具 schema
  → agent/pre-step                reject | enter(messages)
     reject 或首入改空 → 关一个无步的 turn(日志仍记尝试)
     step/start
     entered 消息以 user/message 入日志
     从日志投影模型历史
     agent/request → llm/stream → assistant/chunk* → assistant/message
     tool/call* → tools/pre-execute → tools/execute → tools/post-execute → tool/result*
     step/end
     工具欠新请求或 next-step 输入到达 → 认领 → 下一 step
  → agent/turn-stopping
turn/end
```

- **Agent 句柄**(`ctx.agents` 注册表,插件只面向此接口、零循环依赖):`id`(= sessionId)、`session`、`inbox`、`status`、**`ctx`(agent 作用域注册边界)**、`send/followup/steer/inject/cancel/whenIdle`。`inject()` = 非唤醒 next-step 上下文:运行中在最近的 pre-step 边界被领取;空闲则挂起到 followup/steer 唤醒。
- **inbox**:每次变更先追加持久 `agent/inbox/spliced` 事件再变活投影;`claim` = 整个 next-step 列表 + 一条 next-turn 消息(纯删除 splice)。
- **注册表事务**:enter/announce 拆分(回滚安全的有序拆除);ID 撞击边界;工厂缝 `setFactory` + `create/resume` → `AgentHandle`(dispose 是消费者能力,调用 fiber 与工厂结构性共担,会合到一个记忆化静默边界);initiator 经 AsyncLocalStorage 进程局部传播(工具执行据此盖 `exec.agent` 章)。
- **请求路径**:种子配置 + 持久 `request/header` → `agent/request` waterfall → `prepareCall` → 日志冻结请求;流式经 `llm/stream` waterfall;错误走 `agent/request-error` waterfall(`{kind:'retry'}` 续环);取消收束到 wake latch(cancel-convergence)。

### 4.5 会话日志与系统提示装配

- **"Model-visible means logged" 运行时不变量**:到达模型请求的任何东西必须可从日志重建;新模型可见输入 = 新 session 事件(扩展 `SessionEventMap` 并从日志渲染,见 §3.6)。`deriveMessages()` 从日志投影模型历史;fork/resume/转录/遥测/持久化全部派生自此流。
- **SystemPrompt**(ScopedLayers 同构):`section / context / tools(provider) / variable / suppressRuntimeContext` 注册;装配序:作用域链层 → 变量(近者胜)→ 段按 `order` 排序(惯例:-100 身份 / 0 persona / 100–199 工具指引)→ 工具 schema 连接(参数 structuredClone + `Config.toolOrder` 排序,须恰一个 `<unlisted-tools>` 锚)→ 恰一个 `complete: true` 段 → `system-prompt/assemble` waterfall(返回值权威)。严格 `{{variable}}` 插值(畸形/未知/undefined 即抛);运行时上下文快照带 "supersedes earlier" 前缀语。
- tools 注册表自接:`ctx.systemPrompt.tools(context => this.wireSchemas(context.scope))` —— 工具 schema 进 prompt 无需插件操心。

### 4.6 HMR 深入(partial reload 与回滚)

- vendored hmr 服务(chokidar)三分类:配置文件命中 → 串行化 per-file refresh(坏读保留上一棵好树 + `hmr/config-update-failed`);框架/CLI 外部变更 → 整进程 reload;缓存用户模块 → 去抖 partialReload。
- **partialReload**:变更文件的依赖者分类 accepted/declined;**插件入口文件 = 原子重载单元**;备份并清空 ESM loadCache + CJS require.cache → 重新 import → `registry.delete(plugin)` 旧实例 → 逐 fiber **保留 entry 链接**重新 `plugin()`;任一步失败**回滚双缓存与注册**;完成后 `hmr/reload` 事件。
- 与启动的衔接:`watchUserPatches` 用 `hmr.registerConfig` 精确监视 profile 与 home 两份 patch 文件;组合禁用共享 hmr 行时(web/headless 即如此),启动器自挂 watch-only hmr + timer。
- **重载安全内建于服务**:AgentLoop 保留 prepared adapter 注册("HMR 不能把一个 adapter 的能力结果混进另一个的请求");invariants 包每包一个专用子 fiber,companion 可重载重复注册同名包而不留旧状态。

## 5. 插件开发实战(官方教程路径)

docs/cordis-tutorial/ 七章动手教程(首插件 → 生命周期与 effects → 服务 → 事件 → 配置校验 → 组合与 HMR → 注册真实工具,全部可无 key 运行)。最小插件与真实工具注册(教程 01/07 原例):

```ts
// hello.ts —— 最小插件
import type { Context } from '@deepseek-ai/cordis'
export const name = 'hello'
export function apply(ctx: Context) {
  console.log('hello from my first plugin')
}
// cordis.yml: - name: './hello.ts'
```

```ts
// greet-tool.ts —— 注册模型可调用工具
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { CallId } from '@deepseek-ai/dsh-llm'

export const name = 'greet-tool'
export const inject = ['tools']

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'greet',
    description: 'Greet the named person.',
    parameters: {
      name: { type: 'string', required: true, description: 'Who to greet' },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) { return `Hello, ${args.name}!` },
  }))
}
```

观察者插件只需监听事件:`ctx.on('tools/result', (exec, result) => …)`。工具执行管线:pre-policy → 单调守卫 → around dispatch(waterfall)→ post-policy → 结果观察;`ctx.commands` 注册不经模型回合的人类命令(/compact、/plan、/goal 等);后台工作注册 `ctx.jobs`。

**进程外 SDK**(packages/sdk 三包:protocol 线协议 / client TS API / server stdio JSON-RPC 服务插件)。Python SDK:

```python
from deepseek_harness import DeepSeekHarness
with DeepSeekHarness(provider=…, model=…, cwd=…, session_root=…,
                     cordis=str(CONFIG.resolve())) as harness:
    result = harness.run(prompt, session_id=…)
print(result.final_response)
```

配置经 `cordis` 选项或 `DSH_CORDIS_CONFIG` env 传入;打包的可执行文件自带全部插件,目标机器无需 Node.js。

**examples/ 六例各演示什么**:

| 例子 | 演示能力 |
|---|---|
| headless-agent | 非交互一次性编码 agent;`e2b.cordis.yml` 覆盖层演示用共享 E2B 沙箱整体替换本地 FS/子进程 provider |
| web-cordis | 自指演示:agent 经 tool-cordis 检查自己的插件树、动态挂载/卸载自己写的内存插件 |
| mcp-memory | 三个第三方记忆 MCP 的参考配置;`--patch` 一次性启用;DSH 只启动进程不负责安装的责任边界 |
| acp-agent | Agent Client Protocol(JSON-RPC over stdio)自动化服务器;per-session cwd、权限请求/取消 |
| jsonrpc-agent | Python SDK 无人值守 agent;minimal 变体 = 持久 bash + str_replace_editor 两工具的最小组合 |
| web-schedule | Web 覆盖层加会话本地持久提醒工具(随 Session 存活/恢复) |

仓库内新增官方包的规范见 `docs/cookbook/adding-a-package.md`(package.json 不变量、peer/devDeps 布局、README 必含 Model Experience 与 Known Limitations 章节)。

## 6. 安装与分发

- **官方路径**:`dsh plugin --profile <name> <pnpm args>` —— 在 profile 目录内原样转发 pnpm(相对路径 spec 先重锚到调用目录,故 `add .` 可装本地 checkout);装毕 `reconcilePlugins` 重读 manifest:**声明了 `dsh.bundle` 的依赖自动按序追加进 `dsh.profile.bundles`**,移除即出层;无 bundle 声明的新依赖留作普通依赖并一次性警告("装为纯依赖")—— 随后手改该 profile 的 `cordis.patch.yml` 加 insert 行。一次性启用:`dsh web --patch /path/to/xxx.cordis.yml`(可指向磁盘任意位置的副本)。
- **in-box**:bundle 名写进 `dsh.profile.bundles` 即可,dsh 运行时从自身安装解析(双锚:先安装目录后 profile node_modules)。
- **第三方扩展的三种主流形态**:
  1. 树外 Cordis 插件 npm 包(`dsh plugin add` 进 profile + insert 行配置);
  2. MCP 服务器(无需写 dsh 插件,一条 mcp-client insert 行即桥接 —— mcp-memory 即官方示范);
  3. Cordis 覆盖层 YAML(`--patch` 或用户补丁层)做纯组合定制,不改代码。
- **社区生态**(2026-08 实测检索):[awesome-dsh-plugin/awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)(精选列表,7k+★)、[0xsline/awesome-deepseek-harness](https://github.com/0xsline/awesome-deepseek-harness)(dsh-external/hub 与 dsh-plugin topic 汇总)、[Anil-matcha/awesome-deepseek-harness](https://github.com/Anil-matcha/awesome-deepseek-harness)、[Dominic789654/awesome-deepseek-harness](https://github.com/Dominic789654/awesome-deepseek-harness)、官方 Discussions 与 Discord;插件仓库可打 `dsh-plugin` GitHub topic 便于发现。仓库内无官方 awesome 列表;官方 monorepo 约 220+ 包全在 `@deepseek-ai/dsh-*` scope。
- **本仓库(nixdsh)路径**:profile 即 derivation、插件即 option —— `dshPlugins` 集合(vimPlugins 同构,`plugins/names.txt` + updater 周期 PR),声明式渲染 bundle 层序/patch/settings,绕开 pnpm 逃生口的"声明漂移"问题(非 Nix 装的插件在 profile stamp 变化时被重置)。

## 7. 设计哲学小结(为什么"一切皆插件")

0. **没有特权核心**(docs/architecture.md 原话:"There is no privileged core to patch"):模型适配器、工具注册表、会话日志、甚至 agent 循环本身全部是插件,每个部件都可从配置层替换;扩展 dsh 的方式就是把一个插件挂到其他插件旁边。Cordis 框架本体源自 cordiverse(论文 *A Programming Paradigm for Spatiotemporal Composability*),vendored 在 `vendor/cordis/`。

1. **组合即数据**:整棵运行时是 YAML 行表的有序叠加,`--dump-config` 可完整审视;组合、dump、boot 共用同一 `applyEntryPatches`,不可能漂移。
2. **整行替换、fail-loud、无深合并**:覆盖必须重述全部字段 —— 类型上烦,语义上诚实;坏配置在 boot 期炸而不是运行期漂。
3. **注册廉价、鉴权按请求、错误在使用点**:未配置的 provider 不炸 boot,只占 UI 槽位与 prompt 预算 → "未声明即禁用"有实益。
4. **两平面教义**:宿主组合面(服务/注册表/有状态)与 preset 会话面(工具实例/无状态/吃 prompt 预算)分离;web 服务住宿主,模型面工具按 preset 实例化。
5. **一切注册可逆**:effect/disposer 语义支撑 HMR —— 用户 patch 层热重载、preset 热发现、settings 外部编辑观察,全部建立在 Cordis 的可逆注册上。
6. **无共享守护进程**:每个 face boot 一棵完整独立的 cordis 树;跨 face 共享的只有文件系统($DSH_HOME)。

## 附录 A:关键源码/文档索引

| 主题 | 位置(上游仓库) |
|---|---|
| Cordis 入门 | `docs/cordis-primer.md`、`docs/cordis-tutorial/`(七章动手教程)、`docs/cordis-api/`(生成 API 参考) |
| fiber/effect 语义 | `vendor/cordis/src/fiber.ts`、`vendor/cordis/src/registry.ts`、`docs/cordis-api/fiber.md` |
| 行/include 格式 | `vendor/include/README.md`、`@deepseek-ai/cordis-plugin-include` |
| boot 序列/profile 契约 | `packages/boot/app-boot/README.md`、`apps/cli/src/profile-boot.ts` |
| bundle 契约 | `packages/bundle/README.md`、`packages/bundle/base/README.md` |
| CLI 行为/层优先级 | `apps/cli/README.md` 及其 reference/ |
| 能力缝 | `docs/capability-seams.md`(生成物) |
| 作用域系统 | `packages/core/scope/README.md`、`docs/subsystems/scope.md` |
| 事件全景 | `docs/event-producer-consumer.md`(生成物)、`docs/subsystems/core.md` |
| 工具管道/Code Mode | `docs/tool-execution-pipeline.md`、`packages/core/tools/README.md`、`docs/cookbook/adding-a-tool.md` |
| agent 循环/turn 流 | `docs/agent-lifecycle.md`、`docs/architecture.md`、`packages/core/agent/README.md` |
| settings 子系统 | `packages/settings/README.md`、`docs/subsystems/settings.md` |
| preset 机制 | `packages/preset/agent-presets/README.md` |
| 动态 Cordis 插件 | `packages/extensions/`(host-runner/tool-cordis/client-runner/ui-cordis 各 README)、设计注 `.agents/notes/implemented/feature/2026-07-08-self-referential-cordis-toolset.md` |
| 客户端插件图 | `packages/client/modules/README.md`、`docs/subsystems/client-modules.md` |
| MCP 桥 | `packages/mcp/mcp-client/README.md` |
| skill 子系统 | `packages/skill/README.md`、`docs/subsystems/skills.md` |
| SDK | `packages/sdk/README.md`、`examples/jsonrpc-agent/minimal.py` |
| 组合图 | `apps/cli/composition.md`(生成物,base 78 行全表) |
| 新增官方包规范 | `docs/cookbook/adding-a-package.md`、`docs/cookbook/extension-cookbook.md` |
| vendored 修改清单 | `vendor/README.md`(18 条本地化修改) |
| 架构总览 | `docs/architecture.md`("no privileged core to patch") |

## 附录 B:dsh-base 行全清单(78 行,master 2026-08)

来源:`apps/cli/composition.md`(脚本生成,源 `packages/bundle/base/cordis.patch.yml`,master 实测 78 个行 id;下表为 rc 期分组、行数略有出入)。按职能分组:

- **框架**:timer、hmr
- **模型面**:llm、llm-retry、llm-pi-ai(挂载但 dormant,settings 出现 `llm-pi-ai:` 段才注册路由)、llm-deepseek(key/endpoint 全运行时从 settings/credentials 解析,不内联)、agent-default-model(出厂默认 `provider: deepseek-official, model: deepseek-v4-flash`)
- **会话/存储**:session、session-persistence-jsonl、session-query-sqlite、session-projection、session-title、session-title-llm、session-telemetry-otel、session-checkpoint-policy、attachment-local、spill-local、spill-policy、storage 侧无
- **agent 核心**:agent、agent-loop、agent-instructions、system-prompt、commands、command-feedback、plan-mode、token-meter、compaction-basic、command-compact、tool-result-pruner、repeat-tool-reminder
- **goal/编排**:goal、goal-round-driver、command-goal、tool-goal、tool-ralph、tool-workflow、workflow-worker-thread、tool-jobs、jobs
- **工具**:tools、tool-bash、tool-pwsh、tool-fs、tool-fs-search、tool-str-replace-editor、tool-todo、tool-skill、tool-web、timeout-policy
- **subagent**:subagent、subagent-spawn-in-process、subagent-fork-in-process、tool-subagent、tool-subagent-fork、tool-subagent-control、tool-subagent-list-agents、tool-subagent-report
- **沙箱/权限**:sandbox、sandbox-policy、bash-sandbox、pwsh-sandbox、fs-sandbox、fs-observation-policy、approval、permission、shell-env、subprocess
- **web**:web、web-search-deepseek
- **skill**:skill、skill-filesystem、skill-badge
- **settings/凭证**:settings、credentials
- **API 网关**:typert、typert-loader、typert-gateway、user-questions

(注:平台门控 —— bash-sandbox/tool-bash 带 `disabled: !!js process.platform === 'win32'`,pwsh 双子行反向;Windows 上 ACL 受限令牌链承责,POSIX 上 pwsh 行禁用。)

## 附录 C:术语表

- **entry/行**:cordis.yml 列表的一项 `{id, name, config, disabled}`;id 是 patch 寻址锚。
- **bundle**:声明 `dsh.bundle.patch` 的 npm 包,profile 的一个 patch 层。
- **profile**:`$DSH_HOME/profiles/<name>` 目录,bundle 层表 + 用户 patch + 依赖。
- **patch**:id 定向覆盖 + insert 列表的 YAML 数组;config 整行替换。
- **face(交互面)**:web/headless 等交互 bundle(`PROFILE_TEMPLATES` 仅此二者;tui 只是 CLI 帮助文本里的示例名,非 shipped face);两两互斥(同树声明 → duplicate loader entry id 拒 boot)。
- **preset**:会话级 Agent 组装(agent.cordis.yml + 元数据 + .mjs),热发现;standing mount 每 preset 每进程一次,会话经 scope 父链加入。
- **seam(缝)**:Service Definition + Provider + Consumer 三角色齐备的可替换能力接缝(ctx.web 的 search/fetch 即两缝)。
- **fiber**:Cordis 中一个插件实例的挂载单元;dispose 即回滚其全部注册;epoch 由被注入 fibers 的 uid 串成,依赖变化驱动重载。
- **scope / scope key**:dsh-scope 的注册视图单位;生产中 scope key 即 Agent 对象;`agent.ctx` 是该 agent 专属注册边界。
- **scoped event / 载体(scopeTarget)**:仅路由用的事件 thisArg;无标签监听者全局接收,有标签者仅当是主体 key 或其祖先才准入。
- **realm**:Cordis 服务存储隔离轴(root realm 进程共享 vs isolate realm 子树私有);preset 服务必须坐 isolate realm,不得漏进 root。
- **动态包(dynamic Cordis package)**:模型经 cordis_define 在内存中定义、vm 沙箱求值的临时插件;pluginId 下挂不可变 packageId 版本;不活过重启。
- **dsh.client / __DSH_BOOT__**:package.json 声明的浏览器半清单与宿主注入的启动图;bundle 执行只注册工厂,首次物化才跑副作用。
