# filepath: ~/nixos-config/pkgs/dsh/checks.nix
# dsh profile 模型 flake checks(不阻塞日常 rebuild,nix flake check 时跑)
# 分层验证(共识 Q6/Q16):包内 installCheck 已覆盖 CLI 本身;此处覆盖 profile 组合:
#   dsh-profile-structure : bundle 工件形状(bundles 层序 + cordis 双文件)
#   dsh-profile-headless  : 正例 — headless profile 组合树可渲染(dsh --dump-config)
#   dsh-profile-nobase    : 负例 — 缺 @deepseek-ai/dsh-base 的组合 boot 必须 fail-loud
# 实测依据(rc.5):--dump-config 对坏组合只打印 "entry not found" 但 exit 0,
# 真正的 fail-loud(assertEntriesActivated: pending waiting for service)只在
# 实际 boot 时触发 → 负例用无参 boot 断言非零退出
{ pkgs }:

let
  dshLib = import ./lib.nix { inherit (pkgs) lib; };

  mkBundle = name: plugins:
    dshLib.buildProfile {
      inherit pkgs;
      profile = dshLib.mkProfile { inherit name plugins; };
    };

  goodProfile = mkBundle "web" [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
  ];

  headlessProfile = mkBundle "headless" [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-headless"
  ];

  # 负例:web-app 缺 base — dsh boot 的 assertEntriesActivated 必须拒绝
  nobaseProfile = mkBundle "web-nobase" [
    "@deepseek-ai/dsh-web-app"
  ];

  # 物化 bundle 到 scratch DSH_HOME(dsh boot 会改写 profile 根 cordis.yml,须可写副本)
  materialize = name: bundle: ''
    home="$TMPDIR/dsh-home"
    mkdir -p "$home/profiles"
    cp -a ${bundle} "$home/profiles/${name}"
    chmod -R u+w "$home/profiles/${name}"
    export DSH_HOME="$home"
  '';
in
{
  dsh-profile-structure = pkgs.runCommand "dsh-profile-structure-check"
    { nativeBuildInputs = [ pkgs.jq ]; } ''
      bundle=${goodProfile}
      expected='["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app"]'
      actual=$(jq -c '.dsh.profile.bundles' "$bundle/package.json")
      test "$actual" = "$expected" || {
        echo "bundles mismatch: $actual != $expected" >&2; exit 1;
      }
      test -f "$bundle/cordis.yml" || { echo "missing cordis.yml" >&2; exit 1; }
      test -f "$bundle/cordis.patch.yml" || { echo "missing cordis.patch.yml" >&2; exit 1; }
      touch "$out"
    '';

  dsh-profile-headless = pkgs.runCommand "dsh-profile-headless-check" { } ''
      ${materialize "headless" headlessProfile}
      ${pkgs.dsh}/bin/dsh --profile headless --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      # dsh-base 的条目必须在组合树里(证明层序叠加生效,而非空树碰巧 exit 0)
      grep -q "cordis-plugin-timer" "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "base layer entries missing from composed tree" >&2; exit 1;
      }
      touch "$out"
    '';

  # 负例:无参 boot 必须非零退出且 fail-loud 于 assertEntriesActivated
  dsh-profile-nobase = pkgs.runCommand "dsh-profile-nobase-check" { } ''
      ${materialize "web-nobase" nobaseProfile}
      if ${pkgs.dsh}/bin/dsh --profile web-nobase > "$TMPDIR/boot.log" 2>&1; then
        echo "profile without base unexpectedly booted" >&2
        exit 1
      fi
      grep -q "assertEntriesActivated" "$TMPDIR/boot.log" || {
        cat "$TMPDIR/boot.log" >&2
        echo "expected assertEntriesActivated fail-loud, different failure mode" >&2
        exit 1
      }
      touch "$out"
    '';
}
