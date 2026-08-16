# filepath: ~/code/FWW321/nixdsh/hm-module.nix
# dsh Home Manager 模块 —— programs.dsh
# 消费面:
#   - home.packages:默认 dsh wrapper(settings yq-merge + defaultProfile 注入)
#     + 每 profile 一个 dsh-<name> wrapper(强制绑定该 profile)
#   - home.activation:profile bundle 物化到 $DSH_HOME/profiles/<name>
#     (Samuka007 stamp 方案:store 路径比对,未变不动;dsh boot 会改写 profile 根
#      cordis.yml,故物化为可写副本而非 symlink)
#   - systemd.user.services.dsh-web:常驻 dsh web(open-design 同形态)
# typed 插件层(programs.dsh.plugins.<name>)经 dshLib.applyPlugins 折进
# 各 profile 的 plugins/userPatches(见 lib.nix)
{ config, lib, pkgs, ... }:

let
  dshLib = import ./lib.nix { inherit lib; };
  cfg = config.programs.dsh;

  mainWrapper = dshLib.renderWrapper {
    inherit cfg pkgs;
    name = cfg.binName;
  };

  # typed 插件层增量 + 原始 profile 声明 → 最终 profile
  applied = dshLib.applyPlugins { inherit cfg pkgs; };
  finalProfiles = lib.mapAttrs
    (name: p:
      let inc = applied.perProfile.${name} or { extraPlugins = [ ]; extraPatches = [ ]; }; in
      p // {
        plugins = p.plugins ++ inc.extraPlugins;
        userPatches = p.userPatches ++ inc.extraPatches;
      })
    cfg.profiles;

  profileBundles = lib.mapAttrs
    (name: p: dshLib.buildProfile {
      inherit pkgs;
      profile = dshLib.mkProfile {
        inherit name;
        inherit (p) plugins userPatchesFile userPatches;
        disabled = cfg.disabledPlugins;
      };
    })
    finalProfiles;

  profileWrappers = lib.mapAttrs
    (name: _: dshLib.renderWrapper {
      inherit cfg pkgs;
      name = "dsh-${name}";
      fixedProfile = name;
    })
    cfg.profiles;

  # activation:物化不可变 bundle 为可写副本(dsh 每次 boot 改写 profile 根 cordis.yml)
  activateProfile = name: bundle:
    let
      dir = "${cfg.dshHome}/profiles/${name}";
      stamp = "${dir}/.dsh-nix-stamp";
      artifact = toString bundle;
    in
    ''
      if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${artifact}" ]; then
        :
      else
        rm -rf "${dir}"
        mkdir -p "${dir}"
        cp -a "${artifact}/." "${dir}/"
        chmod -R u+w "${dir}"
        printf '%s' "${artifact}" > "${stamp}"
      fi
    '';

  webCommand = lib.concatStringsSep " " (
    [
      (lib.getExe mainWrapper)
      "web"
      "--host"
      cfg.web.host
      "--port"
      (toString cfg.web.port)
    ]
    ++ lib.concatMap (h: [ "--trusted-host" h ]) cfg.web.trustedHosts
    ++ cfg.web.extraArgs
  );
in
{
  imports = [ ./modules/options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ mainWrapper ] ++ lib.attrValues profileWrappers;

    # unstable HM:dag 在 config.lib(lib 参数未扩展,lib.hm.dag 已移除)
    home.activation.dshProfiles =
      config.lib.dag.entryAfter [ "writeBoundary" ]
      (lib.concatStringsSep "\n" (lib.mapAttrsToList activateProfile profileBundles));

    systemd.user.services.dsh-web = lib.mkIf cfg.web.enable {
      Unit = {
        Description = "dsh web — DeepSeek Harness Web UI";
        After = [ "network.target" ];
        Wants = [ "network.target" ];
      };
      Service = {
        ExecStart = webCommand;
        Restart = "on-failure";
        RestartSec = 5;
        # wrapper 自身 export DSH_HOME($HOME 在 user service 环境可用)
        EnvironmentFile = cfg.environmentFiles;
      };
      Install = lib.mkIf cfg.web.autoStart {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
