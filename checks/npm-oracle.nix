# dsh npm publish oracle:pack 物化产物 vs 上游 npm tarball
# tarball 是"上游认为 runtime 长什么样"的唯一权威 —— package.nix 的
# pnpm deploy + peer 物化循环 + CLI pack 是对上游 `npm publish` 转换的
# 从源码重建;上游改 publish 形状(新增 runtime dep/文件/bin)时物化会
# 静默偏离,此 check 把偏离前移到 bump 当次。
# 四个不变量(2026-08-21 对 141eb6f ↔ rc.8 实测零差集):
#   1. manifest 逐字段深等价(含依赖名→版本全映射;canonicalizeManifest
#      与上游 publish 规范化在值层面收敛,键序无关)
#   2. 文件清单零差集(顶层排除 node_modules;内容不比 —— 源码级决定性
#      patch(CSS 相对路径等)使 client bundle 与上游 CI 产物字节不同属预期)
#   3. tarball 声明的全部 runtime dependencies 已物化进 $app/node_modules
#      (pnpm deploy 漏 peer 的历史教训的对侧防线)
#   4. bin 入口在本地载荷存在(wrapper 硬编码 lib/bin.js 的上游锚点)
# tarball 版本与 dsh.passthru.upstreamVersion 同源(package.nix 单一事实,
# preVersionCheck 同读);版本错位 → installCheck 先炸,hash 错位 → FOD 炸。
# bump 流程:改 commit + upstreamVersion → 重算本文件 tarball hash →
# nix flake check(会真实构建 dsh,属 bump 闸门的预期成本)
{ pkgs, lib }:

let
  dsh = pkgs.dsh;
  upstreamVersion =
    dsh.passthru.upstreamVersion or (throw "dsh 缺 passthru.upstreamVersion(checks/npm-oracle.nix 需要)");
  tarball = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${upstreamVersion}.tgz";
    hash = "sha256-uLDbbzvPOu13wlu5Af250O8Peb2MpAO1LjTBSnHRSH8=";
  };
in
# dsh 只声明 x86_64-linux;其余系统返回空集(与其他 checks 的跨系统无害一致)
lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform dsh) {
  dsh-npm-oracle =
    pkgs.runCommand "dsh-npm-oracle"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        app="${dsh}/lib/node_modules/@deepseek-ai/dsh"
        oracleDir="$(mktemp -d)"
        tar -xzf "${tarball}" -C "$oracleDir" --strip-components=1

        APP="$app" ORACLE="$oracleDir" UPSTREAM_VERSION="${upstreamVersion}" \
          ${lib.getExe pkgs.nodejs} --input-type=module <<'NODE'
        import { existsSync, readFileSync, readdirSync } from "node:fs";
        import { join } from "node:path";

        const app = process.env.APP;
        const oracle = process.env.ORACLE;

        const problems = [];
        const fail = message => problems.push(message);

        // 递归键排序的规范 JSON → 可比较字符串(与 manifest 键序无关)
        const canonical = value =>
          Array.isArray(value)
            ? "[" + value.map(canonical).join(",") + "]"
            : value !== null && typeof value === "object"
              ? "{" + Object.keys(value).sort()
                  .map(key => JSON.stringify(key) + ":" + canonical(value[key]))
                  .join(",") + "}"
              : JSON.stringify(value);

        const parse = path => JSON.parse(readFileSync(path, "utf8"));
        const oracleManifest = parse(join(oracle, "package.json"));
        const appManifest = parse(join(app, "package.json"));

        // 1) manifest 逐字段深等价
        for (const key of new Set([
          ...Object.keys(oracleManifest),
          ...Object.keys(appManifest),
        ])) {
          if (canonical(oracleManifest[key]) !== canonical(appManifest[key])) {
            fail(
              "package.json 字段 " + JSON.stringify(key) + " 与上游 publish 不一致" +
              "\n  上游: " + canonical(oracleManifest[key]) +
              "\n  本地: " + canonical(appManifest[key]),
            );
          }
        }

        // 2) 文件清单零差集(本地排除顶层 node_modules)
        const walk = (root, skipTopLevel) => {
          const out = new Set();
          const rec = (dir, prefix) => {
            for (const entry of readdirSync(dir, { withFileTypes: true })) {
              const rel = prefix + entry.name;
              if (skipTopLevel && rel === "node_modules") continue;
              if (entry.isDirectory()) rec(join(dir, entry.name), rel + "/");
              else if (entry.isFile()) out.add(rel);
              else fail("载荷含非常规文件(符号链接?): " + rel);
            }
          };
          rec(root, "");
          return out;
        };

        const ours = walk(app, true);
        const theirs = walk(oracle, false);
        for (const f of [...ours].filter(f => !theirs.has(f))) {
          fail("仅本地载荷存在: " + f);
        }
        for (const f of [...theirs].filter(f => !ours.has(f))) {
          fail("仅上游 tarball 存在: " + f);
        }

        // 3) 上游声明的 runtime dependencies 全部物化
        for (const dep of Object.keys(oracleManifest.dependencies ?? {})) {
          if (!existsSync(join(app, "node_modules", ...dep.split("/")))) {
            fail("上游 runtime dependency 未物化: " + dep);
          }
        }

        // 4) bin 入口存在
        const bin = oracleManifest.bin ?? {};
        for (const [name, rel] of Object.entries(
          typeof bin === "string" ? { [oracleManifest.name]: bin } : bin,
        )) {
          if (!existsSync(join(app, rel))) {
            fail("bin " + JSON.stringify(name) + " → " + rel + " 在本地载荷不存在");
          }
        }

        if (problems.length > 0) {
          process.stderr.write(
            problems.map(p => "dsh npm-oracle: " + p).join("\n") + "\n",
          );
          process.exit(1);
        }

        console.log(
          "npm-oracle: manifest + 文件清单 + " +
            Object.keys(oracleManifest.dependencies ?? {}).length +
            " 依赖物化 + bin 全部一致 (" + process.env.UPSTREAM_VERSION + ")",
        );
        NODE

        touch $out
      '';
}
