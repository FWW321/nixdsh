# names.txt + update.sh → generated.nix → pkgs.dshPlugins.<packageName>
# (vimPlugins 的 generated.nix 同构;集合懒式:只含 names.txt 声明的插件)
#
# 两类插件,两条路径:
#  1. 预构建(npm 发布态,lib/ 完整):拷贝源码树即用(status-rotator 等)
#  2. needsBuild(update.sh 探测:主入口 export target 在 git 源码缺失):
#     fetchPnpmDeps 离线装依赖 → 插件自己的 compile(tsc) → prune --prod
#     → 连同运行时 node_modules 打包 —— 对齐 `dsh plugin add`(pnpm install
#     进 profile)的真实布局,否则真实 boot ERR_MODULE_NOT_FOUND
#
# passthru 携带 packageName/dshBundlePatch 供 lib.nix mkPlugin 求值期读取
{
  fetchFromGitHub,
  fetchPnpmDeps,
  hostDsh ? null,
  lib,
  nodejs_24,
  pnpm_11,
  pnpmConfigHook,
  runCommand,
  stdenv,
}:

let
  pnpm = pnpm_11.override { nodejs-slim = nodejs_24; };

  # peer 回链必须做在插件 derivation 内部:Node ESM 从文件真实路径向上
  # 找 node_modules(symlink 会被 realpath 化),profile 级链接走不到插件
  # 的 store 路径。宿主安装 = npm hoisted 布局的 node_modules 根。
  hostModules = "${toString hostDsh}/lib/node_modules/@deepseek-ai/dsh/node_modules";
  linkPeers = peers: lib.concatMapStringsSep "\n"
    (p: ''
      if [ -d "${hostModules}/${lib.escapeShellArg p}" ]; then
        mkdir -p "$out/node_modules/$(dirname ${lib.escapeShellArg p})"
        ln -sfn "${hostModules}/${lib.escapeShellArg p}" "$out/node_modules/${lib.escapeShellArg p}"
      else
        echo "warning: peer '${p}' not found in host dsh install; skipping" >&2
      fi
    '')
    peers;

  buildPlugin =
    name: e:
    let
      mainSrc = fetchFromGitHub {
        owner = e.owner;
        repo = e.repo;
        rev = e.rev;
        hash = e.hash;
      };

      # git 子模块物化树。两层都必须看到同一棵树:根 lockfile 把子模块内
      # 的包记作 workspace importer,缺席即 --frozen-lockfile 拒绝 ——
      # fetchPnpmDeps 的独立沙箱也不例外,故合成在 derivation 外完成。
      # 路径以仓库根为基准;当前唯一用例(dsh-TUI)包根 = 仓库根(无
      # subpath),两者并存时须改为相对包根解析
      submodules = e.submodules or [ ];
      # excludedPresets 的物理实现:preset 目录从源树剥离(构建期)。
      # 播种器(dsh-tui ensurePackagedPresets 只认包内 presets/)、
      # 发现扫描、roster 全部无从看见 —— 黑名单 = 不存在
      stripPresets = e.stripPresets or [ ];
      subTrees = map (s: rec {
        inherit (s) path;
        src = fetchFromGitHub { inherit (s) owner repo rev hash; };
        # 含独立 pnpm-lock.yaml 的子模块 = 自带构建工具链的工作区
        deps =
          if s ? pnpmHash
          then fetchPnpmDeps {
            pname = "dsh-plugin-${name}-${s.repo}";
            inherit (e) version;
            src = src;
            inherit pnpm;
            fetcherVersion = 4;
            hash = s.pnpmHash;
          }
          else null;
      }) submodules;

      src =
        if submodules == [ ]
        then mainSrc
        else
          runCommand "source" { }
            (
              ''
                cp -r ${mainSrc}/. "$out"
                chmod -R u+w "$out"
              ''
              + lib.concatMapStrings (t: ''
                rm -rf "$out/${t.path}"
                cp -r ${t.src} "$out/${t.path}"
              '') subTrees
            );
    in
    stdenv.mkDerivation {
      pname = "dsh-plugin-${name}";
      inherit (e) version;

      inherit src;

      # monorepo 插件:构建根为仓库内子目录(fetchFromGitHub 解包名 = source)
      sourceRoot = lib.optionalString (e ? subpath) "source/${e.subpath}";

      pnpmDeps = fetchPnpmDeps {
        pname = "dsh-plugin-${name}";
        inherit (e) version;
        inherit src pnpm;
        fetcherVersion = 4;
        hash = e.pnpmHash;
      };

      nativeBuildInputs = [
        nodejs_24
        pnpm
        pnpmConfigHook
      ];

      # pnpmConfigHook(configure 阶段)已离线装好全量依赖;跳过 prepare 钩子
      # (其用 npm run,沙箱无 npm;clean 会删上游已提交的部分 lib),构建阶段
      # 直接 tsc 增量编译缺失产物,再跑上游自带的 verify 脚本
      pnpmConfigHookPreConfigure = "export pnpm_config_ignore_scripts=true";
      preConfigure = ''
        export pnpm_config_ignore_scripts=true
      '';

      buildPhase = ''
        runHook preBuild
        # 子模块工作区(上游 compile 的 build:dsh-std 步):复用同一
        # config hook 换根换 store 离线安装,再整工作区 build 产出 lib/
        # (根 tsc 经 node_modules 的 workspace 链接消费这些 lib)。
        # 注意:hook 会把全局 store-dir 覆写成子模块自己的 store,构建完
        # 必须恢复根 store —— 否则根级 prune 按子 store 解析,缺包转网络
        # (沙箱无网,EAI_AGAIN 刷屏即此症状)
        rootStore="$(pnpm config get store-dir)"
        ${lib.concatMapStrings (t: lib.optionalString (t.deps != null) ''
          pnpmDeps="${t.deps}" pnpmRoot="$PWD/${t.path}" pnpmConfigHook
          pnpm --dir "${t.path}" -r run build
        '') subTrees}
        if [ ${toString (lib.length subTrees)} -gt 0 ]; then
          pnpm config set store-dir "$rootStore"
        fi
        # tsc 输出到 lib/(package.json exports 指向),源内已有部分 lib 只增不删
        pnpm exec tsc -p tsconfig.json
        if pnpm run --silent verify:build 2>/dev/null; then :; else
          echo "verify:build failed (non-fatal,插件自带校验);继续" >&2
        fi
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # preset 剥离(eval 期已按 shipped 集校验过;此处二次防御,
        # 覆盖无 passthru 元数据的路径):目录物理删除,含失败即炸
        ${lib.concatMapStrings (id: ''
          if [ -e "presets/${id}" ] || [ -L "presets/${id}" ]; then
            rm -rf "presets/${id}"
          else
            echo "stripPresets: plugin ships no preset '${id}' in presets/ — typo, or stale after upstream drop?" >&2
            exit 1
          fi
        '') stripPresets}
        # 子模块的构建工具链(tsdown/typescript)不入运行时产物
        # (@dsh-std/* 零运行时依赖,留下的 lib/ + 源内数据即全部)
        ${lib.concatMapStrings (t: ''
          find "${t.path}" -name node_modules -type d -prune -exec rm -rf {} +
        '') subTrees}
        # 剪掉 devDependencies(tsc 等),保留运行时闭包;
        # 整树连 node_modules 打包 → profile symlink 后 import 链可解析。
        # prune 会清 node_modules 整目录再重装,非交互环境须 CI=true
        # (pnpm 对无 TTY 的确认提示;该键也进不了 pnpm config set)
        export CI=true
        pnpm prune --prod
        # pnpm prune 不清 .pnpm/node_modules 的提升别名:被剪包(含 peer
        # 组合目录,如 react 18/19 混排)留下悬空 symlink,炸 stdenv 的
        # noBrokenSymlinks 校验 → 只删目标缺失的链接(有效链接不动)
        find node_modules -xtype l -delete
        cp -r . "$out"
        ${lib.optionalString (hostDsh != null) (linkPeers (e.peers or [ ]))}
        runHook postInstall
      '';

      passthru = {
        packageName = name;
        dshBundlePatch = e.bundlePatch or null;
        dshFace = e.face or null;
        # face 树是否带 base agent-presets 行(roster 舞资格;update.py
        # roster= 尾参物化,收录时探测)
        dshRoster = e.roster or null;
        # 剥离后的托管 preset 集(发现扫描消费);shipped 集留档供
        # excludedPresets 校验(拼错/上游已删 → eval throw)
        dshPresets = lib.subtractLists stripPresets (e.dshPresets or [ ]);
        dshPresetsShipped = e.dshPresets or [ ];
        # 再剥离入口:registry 层 excludedPresets 消费(源 derivation 复制派生)
        stripPresets = ids: buildPlugin name (e // { stripPresets = ids; });
      };

      meta = with lib; {
        description = "dsh plugin (built from source): ${e.owner}/${e.repo}@${e.version}";
        platforms = platforms.unix;
      };
    };

  plainPlugin =
    name: e:
    let
      stripPresets = e.stripPresets or [ ];
    in
    runCommand "dsh-plugin-${name}"
      {
        passthru = {
          packageName = name;
          dshBundlePatch = e.bundlePatch or null;
          dshFace = e.face or null;
          dshRoster = e.roster or null;
          dshPresets = lib.subtractLists stripPresets (e.dshPresets or [ ]);
          dshPresetsShipped = e.dshPresets or [ ];
          stripPresets = ids: plainPlugin name (e // { stripPresets = ids; });
        };
        meta = with lib; {
          description = "dsh plugin source: ${e.owner}/${e.repo}@${e.version}";
          platforms = platforms.all;
        };
      }
      ''
        # cp -r src/. $out:src 是只读 store 路径,`cp -r src $out` 在 $out
        # 已存在时会拷成 $out/<basename> 嵌套(runCommand 预建 $out);
        # cp 保留 src 的 0555 权限位,后续 linkPeers 须先恢复可写
        cp -r ${fetchFromGitHub {
          owner = e.owner;
          repo = e.repo;
          rev = e.rev;
          hash = e.hash;
        }}${lib.optionalString (e ? subpath) "/${e.subpath}"}/. "$out"
        chmod -R u+w "$out"
        # preset 剥离(同 buildPlugin:物理删除,fail-loud)
        ${lib.concatMapStrings (id: ''
          if [ -e "$out/presets/${id}" ] || [ -L "$out/presets/${id}" ]; then
            rm -rf "$out/presets/${id}"
          else
            echo "stripPresets: plugin ships no preset '${id}' in presets/ — typo, or stale after upstream drop?" >&2
            exit 1
          fi
        '') stripPresets}
        ${lib.optionalString (hostDsh != null) (linkPeers (e.peers or [ ]))}
      '';
in
lib.mapAttrs
  (name: e:
    if e ? needsBuild
    then buildPlugin name e
    else plainPlugin name e)
  (import ./generated.nix)
  # 外部消费者出口:宿主耦合型/异构构建(esbuild 等)插件在下游 flake 自建
  # derivation 时,仍需 peer 回链保持与 dsh plugin add 等价的 node_modules
  # 布局(linkPeers 闭包已含 hostDsh)。见 nixdsh README「非 Nix 逃生口」
  # 与 docs/deepseek-harness-plugin-research.md §nix 侧物化。
  # 用例:nixos-config 的 @open-design/dsh-runtime(OD 协议适配器,版本与
  # OD daemon 原子耦合,不走 registry 独立版本化)
  // { inherit linkPeers; }
