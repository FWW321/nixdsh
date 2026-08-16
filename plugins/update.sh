#!/usr/bin/env bash
# dsh-plugins-update — vimPlugins update.py 的个人规模 transpose
# 读 names.txt(owner/repo [subpath])→ GitHub API 解析版本(tag 优先,HEAD 回退)
# → prefetch 源码树 → 读 package.json(packageName + dsh.bundle.patch)
# → 写 generated.nix(overlay.nix 消费为 pkgs.dshPlugins.<packageName>)
#
# 幂等:同 rev 重跑不产生 diff。网络依赖:GitHub API + codeload tarball。
set -euo pipefail

# 注:勿写成 ${1:-${X:-$(...)}} 多层嵌套(少个 } 会让错误远端显形,难排查),拍平
ROOT="${1:-${NIXDSH_ROOT:-}}"
if [ -z "${ROOT}" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "${ROOT}" ] || [ ! -d "${ROOT}/plugins" ]; then
  echo "usage: dsh-plugins-update [nixdsh-repo-root]  (or run inside the repo / set NIXDSH_ROOT)" >&2
  exit 2
fi
NAMES="${ROOT}/plugins/names.txt"
GENERATED="${ROOT}/plugins/generated.nix"

# GitHub API 认证:sops 的 github_token(owner=fww)存在则用,避免 60 req/h 匿名限流
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/run/secrets/github_token}"
AUTH=()
if [ -r "${GH_TOKEN_FILE}" ]; then
  AUTH=(-H "Authorization: Bearer $(cat "${GH_TOKEN_FILE}")")
fi

api() { curl -fsSL "${AUTH[@]}" "https://api.github.com/$1"; }

# owner repo -> "rev version"(release tag > 最新 tag > 默认分支 HEAD)
# API 失败必须炸出声(set -e + 无静默吞),绝不产出空 rev 的垃圾 entry
resolve_version() {
  local owner="$1" repo="$2" out branch sha
  if out=$(api "repos/${owner}/${repo}/releases/latest" | jq -er .tag_name); then
    echo "${out} ${out}"
    return
  fi
  if out=$(api "repos/${owner}/${repo}/tags" | jq -er '.[0].name'); then
    # tag 名解析出 commit:tags 端点带 commit sha
    sha=$(api "repos/${owner}/${repo}/git/ref/tags/${out}" | jq -er .object.sha)
    echo "${sha} ${out}"
    return
  fi
  branch=$(api "repos/${owner}/${repo}" | jq -er .default_branch)
  sha=$(api "repos/${owner}/${repo}/commits/${branch}" | jq -er .sha)
  echo "${sha} 0-unstable-$(date -u +%Y-%m-%d)"
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

first=1
emit() { # 追加一条 entry 到 ${TMP}/body(Nix attrset 各条独立,无需分隔符)
  first=0
  # 注:\" 不能内嵌在 "${:+}" 的嵌套引号里(bash 引号匹配在参数展开内失效),先拼片段
  sub=""
  [ -n "$7" ] && sub=" subpath = \"$7\"; "
  pat=""
  [ -n "$8" ] && pat=" bundlePatch = \"$8\"; "
  printf '  "%s" = { owner = "%s"; repo = "%s"; rev = "%s"; version = "%s"; hash = "%s";%s%s };\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$sub" "$pat" >>"${TMP}/body"
}

while IFS= read -r line; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}" # ltrim
  [ -z "${line}" ] && continue
  owner=$(cut -d'/' -f1 <<<"${line%% *}")
  repo=$(cut -d'/' -f2 <<<"${line%% *}")
  subpath=""
  read -r _ subpath _ <<<"${line}" || true
  [ -z "${owner}" ] || [ -z "${repo}" ] && { echo "bad line: ${line}" >&2; exit 1; }

  read -r rev version <<<"$(resolve_version "${owner}" "${repo}")"
  echo "→ ${owner}/${repo}: ${version} (${rev:0:12})"

  # prefetch 源码树:一条命令拿 store path + nar hash(fetchFromGitHub 兼容)
  json=$(nix store prefetch-file --unpack --json \
    "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz")
  src=$(jq -er .storePath <<<"${json}")
  hash=$(jq -er .hash <<<"${json}")

  dir="${src}"
  [ -n "${subpath}" ] && dir="${src}/${subpath}"
  pkg_json="${dir}/package.json"
  [ -f "${pkg_json}" ] || { echo "  no package.json at ${pkg_json}" >&2; exit 1; }
  name=$(jq -er .name "${pkg_json}")
  patch=$(jq -r '.dsh.bundle.patch // empty' "${pkg_json}")
  [ -n "${patch}" ] && echo "  bundle patch: ${patch}"

  emit "${name}" "${owner}" "${repo}" "${rev}" "${version}" "${hash}" "${subpath}" "${patch}"
done <"${NAMES}"

{
  echo "# 由 update.sh 生成,勿手改(nix run github:FWW321/nixdsh#dsh-plugins-update)"
  if [ "${first}" -eq 1 ]; then
    echo "{ }"
  else
    echo '{'
    cat "${TMP}/body"
    echo ''
    echo '}'
  fi
} >"${GENERATED}"

echo "✓ ${GENERATED}"
