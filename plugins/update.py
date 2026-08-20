# dsh-plugins-update — vimPlugins update.py 的个人规模 transpose(Python 重写)
# 读 plugins/names.txt(owner/repo [subpath])→ GitHub API 解析版本
# (tag 优先,HEAD 回退)→ nix prefetch → 读 package.json(packageName +
# dsh.bundle.patch + needsBuild 探测 + pnpmDeps hash 发现)
# → 写 plugins/generated.nix(overlay.nix 消费为 pkgs.dshPlugins.<packageName>)
#
# 幂等:同 rev 重跑不产生 diff。网络:GitHub API + codeload tarball。
# 用法:update.py [nixdsh-repo-root](缺省取 git toplevel / NIXDSH_ROOT)
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


def repo_root() -> Path:
    if len(sys.argv) > 1:
        return Path(sys.argv[1]).resolve()
    if root := os.environ.get("NIXDSH_ROOT"):
        return Path(root)
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
    )
    if out.returncode == 0:
        return Path(out.stdout.strip())
    sys.exit(
        "usage: update.py [nixdsh-repo-root]  "
        "(or run inside the repo / set NIXDSH_ROOT)"
    )


ROOT = repo_root()
NAMES = ROOT / "plugins" / "names.txt"
GENERATED = ROOT / "plugins" / "generated.nix"

# GitHub token:环境变量优先(符合惯例,CI 用 GITHUB_TOKEN),缺省回落
# 本机 sops 路径;都没有 → 匿名(60 req/h,小清单够用)
_token = (
    os.environ.get("GITHUB_TOKEN")
    or (
        Path("/run/secrets/github_token").read_text().strip()
        if Path("/run/secrets/github_token").is_file()
        else ""
    )
)
_HEADERS = {"Authorization": f"Bearer {_token}"} if _token else {}


def api(path: str):
    req = urllib.request.Request(
        f"https://api.github.com/{path}", headers=_HEADERS
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def resolve_version(owner: str, repo: str) -> tuple[str, str]:
    """最新 tag(semver 最大;release tag 并池 —— 上游有的仓库 tag-only
    发版,如 dsh-TUI v0.8.3+ 无 release)> 默认分支 HEAD。
    失败即抛,绝不产出空 rev。"""

    def tag_key(name: str):
        # "v0.8.5" → [(1,0),(1,8),(1,5)];非数字段(如 -rc 前缀)排最低
        s = name[1:] if name[:1] in ("v", "V") else name
        return [
            (1, int(seg)) if seg.isdigit() else (0, 0)
            for seg in s.replace("-", ".").split(".")
        ]

    try:
        tags = [t["name"] for t in api(f"repos/{owner}/{repo}/tags?per_page=100")]
        try:
            tags.append(api(f"repos/{owner}/{repo}/releases/latest")["tag_name"])
        except (urllib.error.HTTPError, KeyError):
            pass
        if not tags:
            raise IndexError("no tags and no latest release (API cache node?)")
        tag = max(tags, key=tag_key)
        sha = api(f"repos/{owner}/{repo}/git/ref/tags/{tag}")["object"]["sha"]
        return sha, tag
    except (urllib.error.HTTPError, IndexError, KeyError, ValueError):
        pass
    branch = api(f"repos/{owner}/{repo}")["default_branch"]
    sha = api(f"repos/{owner}/{repo}/commits/{branch}")["sha"]
    import datetime

    return sha, f"0-unstable-{datetime.date.today().isoformat()}"


def prefetch(owner: str, repo: str, rev: str) -> tuple[str, str]:
    """codeload tarball → (storePath, narHash),fetchFromGitHub 兼容。"""
    out = subprocess.run(
        [
            "nix", "store", "prefetch-file", "--unpack", "--json",
            f"https://github.com/{owner}/{repo}/archive/{rev}.tar.gz",
        ],
        check=True, capture_output=True, text=True,
    )
    data = json.loads(out.stdout)
    return data["storePath"], data["hash"]


def parse_gitmodules(src: Path) -> list[tuple[str, str]]:
    """.gitmodules → [(path, url)];无文件返回空。tarball 不含子模块内容,
    只含这份清单 —— 物化所需的钉点 SHA 另查 contents API。"""
    gm = src / ".gitmodules"
    if not gm.is_file():
        return []
    import configparser

    cp = configparser.ConfigParser()
    cp.read(gm)
    out = []
    for section in cp.sections():
        if not section.startswith("submodule "):
            continue
        path = cp.get(section, "path", fallback="")
        url = cp.get(section, "url", fallback="")
        if path and url:
            out.append((path, url))
    return out


def resolve_submodule(
    owner: str, repo: str, rev: str, path: str, url: str
) -> dict:
    """子模块钉点解析:contents API 给 gitlink SHA + 上游仓库坐标。"""
    info = api(f"repos/{owner}/{repo}/contents/{path}?ref={rev}")
    if info.get("type") != "submodule":
        sys.exit(
            f"  {path}: expected a submodule gitlink at {rev}, "
            f"got {info.get('type')}"
        )
    m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$", url)
    if not m:
        sys.exit(f"  {path}: non-GitHub submodule URL unsupported: {url}")
    return {"owner": m[1], "repo": m[2], "rev": info["sha"]}


def probe_pnpm_hash(src: str) -> str:
    """fetchPnpmDeps hash 发现:fakeHash 构建预期失败,从错误信息取 got:。"""
    lock = json.loads((ROOT / "flake.lock").read_text())
    rev = lock["nodes"]["nixpkgs"]["locked"]["rev"]
    url = f"https://github.com/NixOS/nixpkgs/archive/{rev}.tar.gz"
    expr = (
        f'(import (builtins.fetchTarball "{url}") {{}})'
        ".fetchPnpmDeps.override "
        f'{{ pnpm = (import (builtins.fetchTarball "{url}") {{}}).pnpm_11; }}'
        " { "
        f'pname = "probe"; version = "1"; src = {src}; '
        f"fetcherVersion = 4; hash = \"{FAKE_HASH}\"; }}"
    )
    out = subprocess.run(
        ["nix", "build", "--no-link", "--impure", "--expr", expr],
        capture_output=True, text=True,  # 预期失败,不 check
    )
    if m := re.search(r"got:\s+(sha256-\S+)", out.stderr + out.stdout):
        return m.group(1)
    sys.exit(f"pnpmDeps hash discovery failed:\n{out.stderr[-800:]}")


def nix_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    entries = []
    for raw in NAMES.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        owner, repo = parts[0].split("/", 1)
        # 尾参两类:face=<名>(交互面标记,收录时人审判定 —— 互斥语义无法
        # 自动推导:id 冲突之外还有 TTY 等运行期约束)或 subpath。
        # face 物化进 generated.nix → 用户 plugins.<name>.enable 即自动生成
        # face profile;subpath 为 monorepo 子目录
        subpath = ""
        face = ""
        roster = ""
        for p in parts[1:]:
            if p.startswith("face="):
                face = p.removeprefix("face=")
            elif p.startswith("roster="):
                # roster=(true|false):face 树是否带 base agent-presets 行
                # (roster 舞资格;收录时探测 bundle patch 的 insert 行)
                roster = p.removeprefix("roster=")
            elif not subpath:
                subpath = p

        rev, version = resolve_version(owner, repo)
        print(f"→ {owner}/{repo}: {version} ({rev[:12]})")

        src, hash_ = prefetch(owner, repo, rev)
        pkg_dir = Path(src) / subpath if subpath else Path(src)
        pkg_json = pkg_dir / "package.json"
        if not pkg_json.is_file():
            sys.exit(f"  no package.json at {pkg_json}")
        manifest = json.loads(pkg_json.read_text())

        # git 子模块(如 dsh-TUI v0.8.1 的 vendor/dsh-std):tarball 只带
        # .gitmodules 清单。逐个解析钉点 → prefetch → 记录;含独立
        # pnpm-lock.yaml 的子模块(自带构建工具链)额外探 pnpmDeps hash
        submodules = []
        sub_stores: dict[str, str] = {}
        for path, url in parse_gitmodules(Path(src)):
            pin = resolve_submodule(owner, repo, rev, path, url)
            sub_src, sub_hash = prefetch(pin["owner"], pin["repo"], pin["rev"])
            print(f"  submodule {path}: {pin['owner']}/{pin['repo']}"
                  f" @ {pin['rev'][:12]}")
            entry = {"path": path, **pin, "hash": sub_hash}
            if (Path(sub_src) / "pnpm-lock.yaml").is_file():
                entry["pnpmHash"] = probe_pnpm_hash(sub_src)
                print(f"    pnpmDeps: {entry['pnpmHash'][:19]}…")
            submodules.append(entry)
            sub_stores[path] = sub_src

        # needsBuild 探测:主入口 export target 在 git 源码缺失
        # → 上游提交的 lib 过期/不全,derivation 需构建(tsc)+ 打包运行时 node_modules
        dot = (manifest.get("exports") or {}).get(".", {})
        main_target = (
            dot.get("import") or dot.get("default")
            if isinstance(dot, dict) else dot
        ) or manifest.get("main") or ""
        main_target = (
            main_target.lstrip("./") if isinstance(main_target, str) else ""
        )
        needs_build = bool(main_target) and not (
            pkg_dir / main_target
        ).is_file()
        pnpm_hash = ""
        if needs_build:
            print(
                f"  main target {main_target} missing in source → build needed"
            )
            # 根 lockfile 把子模块内的包记作 workspace importer ——
            # 缺席时 --frozen-lockfile 直接拒绝。探测必须用"主树 + 子模块
            # 物化"的合成树(与 overlay.nix 的合成源同构),构建同理
            probe_src = src
            if submodules:
                import tempfile

                combined = Path(tempfile.mkdtemp(prefix="dsh-submods-"))
                subprocess.run(
                    ["cp", "-r", f"{src}/.", str(combined)], check=True
                )
                subprocess.run(
                    ["chmod", "-R", "u+w", str(combined)], check=True
                )
                for path, sub_src in sub_stores.items():
                    subprocess.run(
                        ["rm", "-rf", str(combined / path)], check=True
                    )
                    subprocess.run(
                        ["cp", "-r", sub_src, str(combined / path)], check=True
                    )
                probe_src = str(combined)
            pnpm_hash = probe_pnpm_hash(probe_src)
            print(f"  pnpmDeps: {pnpm_hash[:19]}…")

        fields = [
            ("owner", owner), ("repo", repo), ("rev", rev),
            ("version", version), ("hash", hash_),
        ]
        if subpath:
            fields.append(("subpath", subpath))
        if face:
            fields.append(("face", face))
        if roster:
            fields.append(("roster", roster))
        if submodules:
            fields.append(("submodules", json.dumps(submodules)))
        if patch := (manifest.get("dsh", {}).get("bundle", {}).get("patch")):
            fields.append(("bundlePatch", patch))
        # peers 物化:peerDependencies ∪ dependencies(宿主 dsh 安装是它们的
        # 唯一提供者,buildProfile 据此做回链 symlink)。deps 并入是必须的:
        # 预构建插件源码 tree 不带 node_modules,运行时 import 的依赖
        # (如 @tonydua/dsh-web-search-exa 的 @deepseek-ai/schemastery)
        # 须经回链解析 —— 实测漏链 = ERR_MODULE_NOT_FOUND 炸 boot
        # (ESM 从插件真实路径向上找 node_modules,profile 级链接救不了)
        # deps 并入 devDeps:预构建插件源码树不带 node_modules,运行时
        # import 的一切 @deepseek-ai/* 都须经回链 —— exa 的教训是
        # dependencies,本次 zhipu 的教训是 devDependencies(settings 段
        # 安装是运行时路径,上游包把它错放 devDeps)。宁可多链(nix store
        # 硬链接零成本)不可漏链(漏 = ERR_MODULE_NOT_FOUND 炸 boot)
        peers = sorted(
            set((manifest.get("peerDependencies") or {}).keys())
            | {
                k
                for k in (manifest.get("dependencies") or {})
                if k.startswith("@deepseek-ai/")
            }
            | {
                k
                for k in (manifest.get("devDependencies") or {})
                if k.startswith("@deepseek-ai/")
            }
        )
        if peers:
            fields.append(("peers", json.dumps(peers)))
        # preset 探测:presets/<id>/agent.cordis.yml 的插件托管预设
        # (dsh-tui 的 liangshen 形态 —— ensurePackagedPresets 播种源)。
        # 物化 dshPresets → eval 期零构建发现;无 presets/ 目录 = 不写
        # (字段缺省,overlay 不物化)
        preset_ids = sorted(
            p.name
            for p in pkg_dir.glob("presets/*")
            if (p / "agent.cordis.yml").is_file()
        )
        if preset_ids:
            print(f"  presets: {', '.join(preset_ids)}")
            fields.append(("dshPresets", json.dumps(preset_ids)))
        if needs_build:
            fields += [("needsBuild", True), ("pnpmHash", pnpm_hash)]

        def nix_val(v):
            if v is True:
                return "true"
            if isinstance(v, list):
                return "[ " + " ".join(nix_val(i) for i in v) + " ]"
            if isinstance(v, dict):
                return (
                    "{ "
                    + " ".join(f"{k} = {nix_val(x)};" for k, x in v.items())
                    + " }"
                )
            if v.startswith("[") or v.startswith("{"):
                # JSON 容器(字符串形态)→ 逐元素递归转义
                return nix_val(json.loads(v))
            return nix_str(v)

        attrs = " ".join(f"{k} = {nix_val(v)};" for k, v in fields)
        entries.append(f"  {nix_str(manifest['name'])} = {{ {attrs} }};\n")

    body = "".join(entries)
    GENERATED.write_text(
        "# 由 update.py 生成,勿手改"
        "(nix run github:FWW321/nixdsh#dsh-plugins-update)\n"
        + ("{ }\n" if not entries else "{\n" + body + "}\n")
    )
    print(f"✓ {GENERATED}")


if __name__ == "__main__":
    main()
