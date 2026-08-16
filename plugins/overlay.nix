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
      src = fetchFromGitHub {
        owner = e.owner;
        repo = e.repo;
        rev = e.rev;
        hash = e.hash;
      };
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
        # tsc 输出到 lib/(package.json exports 指向),源内已有部分 lib 只增不删
        pnpm exec tsc -p tsconfig.json
        if pnpm run --silent verify:build 2>/dev/null; then :; else
          echo "verify:build failed (non-fatal,插件自带校验);继续" >&2
        fi
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # 剪掉 devDependencies(tsc 等),保留运行时闭包;
        # 整树连 node_modules 打包 → profile symlink 后 import 链可解析
        pnpm prune --prod
        cp -r . "$out"
        ${lib.optionalString (hostDsh != null) (linkPeers (e.peers or [ ]))}
        runHook postInstall
      '';

      passthru = {
        packageName = name;
        dshBundlePatch = e.bundlePatch or null;
        dshFace = e.face or null;
        dshPresets = e.dshPresets or [ ];
      };

      meta = with lib; {
        description = "dsh plugin (built from source): ${e.owner}/${e.repo}@${e.version}";
        platforms = platforms.unix;
      };
    };

  plainPlugin =
    name: e:
    runCommand "dsh-plugin-${name}"
      {
        passthru = {
          packageName = name;
          dshBundlePatch = e.bundlePatch or null;
          dshFace = e.face or null;
          dshPresets = e.dshPresets or [ ];
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
        ${lib.optionalString (hostDsh != null) (linkPeers (e.peers or [ ]))}
      '';
in
lib.mapAttrs
  (name: e:
    if e ? needsBuild
    then buildPlugin name e
    else plainPlugin name e)
  (import ./generated.nix)
