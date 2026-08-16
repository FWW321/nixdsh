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
├── hm-module.nix      # HM 消费面:wrappers + activation 物化 + systemd user 服务
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
programs.dsh.plugins.dsh-sysmon = {          # 名字=packageName → source 免声明
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
