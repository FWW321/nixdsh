# 共享夹具:applyPlugins 直调底座、wrapper stub cfg、bundle 构建、
# activation 物化、in-tree 端到端模板 —— 消各域文件重复
{ pkgs, dshLib }:

let
  inherit (pkgs.lib) concatStringsSep;

  applyBase = {
    plugins = { };
    profiles = { default = { }; };
    inBoxPlugins = { };
  };

  # applyPlugins 直调:公共底座 + overlay(域文件只写差异面)
  applyWith = cfg: dshLib.applyPlugins {
    inherit pkgs;
    cfg = applyBase // cfg;
  };

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

  # renderWrapper stub cfg:fake package 无 bin.js → upstreamSubcommands
  # 回落内置名单 {web,plugin}(保留名负例依赖此行为)
  mkFakeCfg = overrides: {
    settings = { };
    telemetry = { mode = null; };
    providers = { };
    defaultModel = null;
    environment = { };
    dshHome = "/tmp/fake-dsh-home";
    package = pkgs.hello;
    defaultProfile = "base";
    extraArgs = [ ];
  } // overrides;

  # 模拟 activation:bundle 物化进 $DSH_HOME/profiles/(dsh boot 只认用户目录)
  materialize = name: bundle: ''
    home="$TMPDIR/dsh-home"
    mkdir -p "$home/profiles"
    cp -a ${bundle} "$home/profiles/${name}"
    chmod -R u+w "$home/profiles/${name}"
    export DSH_HOME="$home"
  '';

  # in-tree 端到端模板:cfg → applied 行组 → 真 bundle(base + 增量)→
  # 真 boot --dump-config,断言 entryId insert 进组合树(非 warn-skip)
  # + extraGreps(每条为须成功的 shell 命令)
  inTreeCheck =
    { checkName, profileName, entryId, cfg, extraGreps ? [ ] }:
    let
      applied = applyWith cfg;
      inc = applied.perProfile.default;
      bundle = dshLib.buildProfile {
        inherit pkgs;
        profile = dshLib.mkProfile {
          name = profileName;
          plugins = [ "@deepseek-ai/dsh-base" ] ++ inc.extraPlugins;
          userPatchesFile = null;
          userPatches = inc.extraPatches;
        };
      };
    in
    pkgs.runCommand checkName { } ''
      ${materialize profileName bundle}
      ${pkgs.dsh}/bin/dsh --profile ${profileName} --dump-config > "$TMPDIR/dump.log" 2>&1 \
        || { cat "$TMPDIR/dump.log" >&2; exit 1; }
      grep -q '${entryId}' "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "${entryId} entry missing from composed tree" >&2; exit 1;
      }
      ! grep -q 'entry "${entryId}" not found' "$TMPDIR/dump.log" || {
        cat "$TMPDIR/dump.log" >&2; echo "${entryId} row was warn-skipped (patch shape, not insert)" >&2; exit 1;
      }
      ${concatStringsSep "\n" (map (g: "${g} || { cat \"$TMPDIR/dump.log\" >&2; exit 1; }") extraGreps)}
      touch $out
    '';
in
{
  inherit applyWith mkBundle mkFakeCfg materialize inTreeCheck;
  inherit goodProfile headlessProfile nobaseProfile;
}
