# filepath: ~/code/FWW321/nixdsh/hm-module.nix
# dsh Home Manager 模块 —— programs.dsh
# 消费面:
#   - home.packages:单一 dsh wrapper(settings yq-merge + defaultProfile 注入
#     + profile 子命令分发:dsh <profile> ≡ dsh --profile <profile>;
#     web 走上游原生子命令,不再生成 per-profile wrapper)
#   - home.activation:profile bundle 物化到 $DSH_HOME/profiles/<name>
#     (Samuka007 stamp 方案:store 路径比对,未变不动;dsh boot 会改写 profile 根
#      cordis.yml,故物化为可写副本而非 symlink)
#   - systemd.user.services.dsh-web:常驻 dsh web(open-design 同形态)
# typed 插件层(programs.dsh.plugins.<name>)经 dshLib.applyPlugins 折进
# 各 profile 的 plugins/userPatches(见 lib/)
{ config, lib, pkgs, ... }:

let
  dshLib = import ./lib { inherit lib; };
  cfg = config.programs.dsh;

  # typed 插件层增量 + in-box 条目行 + 原始 profile 声明 + face 自动 profile
  # → 最终 profile
  applied = dshLib.applyPlugins { inherit cfg pkgs; };
  allProfiles = cfg.profiles // applied.facePlugins;

  # 单一入口:主 wrapper 挂 profile 子命令分发(dsh <profile> →
  # --profile <profile>);名单 = 手写 profiles + 自动 face,用户零声明。
  # 不再生成 per-profile wrapper(dsh-<face> 等):子命令分发等价,独立
  # wrapper 只是 $PATH 噪音;短命令需求由 shell alias 承担。
  # 撞上游子命令(web 除外)在 renderWrapper 层 eval 期 throw
  mainWrapper = dshLib.renderWrapper {
    inherit cfg pkgs;
    name = cfg.binName;
    subcommands = lib.attrNames allProfiles;
  };

  # bash 补全:bash-completion 的 XDG_DATA_HOME 用户目录(~/.local/share/
  # bash-completion/completions/<bin>)。xdg.dataFile 是 HM 声明式 link:
  # face 移除/改名 → activation 自动删/换 link,store 旧的归 GC,零遗留。
  # 只声明文件本身,不要求用户启用 programs.bash(文件在对的位置,任何
  # bash-completion 消费方都能拾取)
  bashCompletion = dshLib.renderCompletion {
    name = cfg.binName;
    subcommands = lib.attrNames allProfiles;
    profiles = lib.attrNames finalProfiles;
    upstream = dshLib.upstreamSubcommands cfg.package;
  };
  finalProfiles = lib.mapAttrs
    (name: p:
      let inc = applied.perProfile.${name} or { extraPlugins = [ ]; extraPatches = [ ]; }; in
      p // {
        plugins = p.plugins ++ inc.extraPlugins;
        userPatches = p.userPatches ++ inc.extraPatches;
      })
    allProfiles;

  profileBundles = lib.mapAttrs
    (name: p: dshLib.buildProfile {
      inherit pkgs;
      profile = dshLib.mkProfile {
        inherit name;
        inherit (p) plugins userPatchesFile userPatches;
      };
    })
    finalProfiles;

  # agent 预设:build 期重放能力行组(单一事实源 applied;行组增删改 →
  # 产物路径变 → stamp 重物化,删除自动清理)+ 剥 tui marker(所有权归
  # 声明方,ensurePackagedPresets 视无 marker 目录为 conflict 永不碰)。
  # 双源合流:插件源自动发现(applied.discoveredPresets,经 sourceOf
  # 解析链 —— 零 source 插件也发现)+ 显式 presets.<name> 声明(胜)。
  # 校验在 lib.validatePresets(eval 期 fail-loud);stamp 语义同 profile
  # (声明名 Nix 拥有,物化覆盖创造模式迭代版 —— 声明即接管)。
  # ⚠ 能力行被 preset 层遮蔽的根因与 retiring 条件见 lib/preset.nix 注记
  presetArtifacts = lib.mapAttrs
    (name: src: dshLib.buildPreset {
      inherit pkgs;
      source = src;
      rows = applied.wfRows ++ applied.wsProviderRows ++ applied.wsSelectorRow;
    })
    (applied.discoveredPresets
      // (dshLib.validatePresets cfg.presets));
  # skills:validateSkills 校验 + 相对目标名(文件 → <名>.md / 目录 → <名>)
  skillSources = dshLib.validateSkills cfg.skills;

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
let
  # preset 出处总账(构建期快照,命令只读不 eval):三态 + fork 标注
  presetOriginsJSON = dshLib.presetOrigins {
    inherit pkgs;
    declared = dshLib.validatePresets cfg.presets;
    inherit (applied) discoveredOrigins;
  };
  # dsh-presets 命令(lib 层,checks 直测;--live 对比物化区)
  dshPresetsCmd = dshLib.mkPresetOriginsCmd {
    inherit pkgs;
    origins = presetOriginsJSON;
    dshHome = cfg.dshHome;
  };
in
{
  imports = [ ./modules/options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ mainWrapper dshPresetsCmd ];

    xdg.dataFile."bash-completion/completions/${cfg.binName}".text =
      bashCompletion;

    # unstable HM:dag 在 config.lib(lib 参数未扩展,lib.hm.dag 已移除)
    home.activation.dshProfiles =
      config.lib.dag.entryAfter [ "writeBoundary" ]
      (lib.concatStringsSep "\n" (lib.mapAttrsToList activateProfile profileBundles)
      + ''

        # 孤儿清理:带 stamp(本模块物化)但已不在当前 profile 集的目录
        # (face 插件移除/profile 改名后遗留;wrapper 由 home.packages
        # 常规清理,目录在 HM 管辖外须自扫)。无 stamp 的目录是用户
        # dsh plugin add 创建的,不碰
        _keep="${lib.concatStringsSep " " (lib.attrNames finalProfiles)}"
        for _dir in "${cfg.dshHome}"/profiles/*; do
          [ -e "$_dir" ] || continue
          [ -f "$_dir/.dsh-nix-stamp" ] || continue
          _name="$(basename "$_dir")"
          case " $_keep " in
            *" $_name "*) ;;
            *) rm -rf "$_dir" ;;
          esac
        done

        # agent 预设物化(热发现,免重启)+ 同语义孤儿清理。无 stamp 的
        # 目录是 TUI 创造模式/手写的,不碰。物化的是 buildPreset 产物
        # (能力行已重放,marker 已剥),stamp = 产物路径
        _pkeep="${lib.concatStringsSep " " (lib.attrNames presetArtifacts)}"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (name: artifact: ''
            _pdir="${cfg.dshHome}/.agent-presets/${name}"
            _pstamp="$_pdir/.dsh-nix-stamp"
            if [ -f "$_pstamp" ] && [ "$(cat "$_pstamp")" = "${toString artifact}" ]; then
              :
            else
              rm -rf "$_pdir"
              mkdir -p "$_pdir"
              cp -a "${toString artifact}/." "$_pdir/"
              chmod -R u+w "$_pdir"
              printf '%s' "${toString artifact}" > "$_pstamp"
            fi
          '')
          presetArtifacts)}
        for _dir in "${cfg.dshHome}"/.agent-presets/*; do
          [ -e "$_dir" ] || continue
          [ -f "$_dir/.dsh-nix-stamp" ] || continue
          _name="$(basename "$_dir")"
          case " $_pkeep " in
            *" $_name "*) ;;
            *) rm -rf "$_dir" ;;
          esac
        done

        # skills 物化($DSH_HOME/skills,上游 watch 热发现免重启)。
        # stamp 键 = attr 名,存于 skills/.dsh-nix-stamps/(不污染发现根:
        # 扫描跳过 . 开头目录,frontmatter 只认 <名>.md/<名>/SKILL.md);
        # 孤儿清理:stamp 在而声明已删 → 删物化物与 stamp。不碰用户手放文件
        mkdir -p "${cfg.dshHome}/skills/.dsh-nix-stamps"
        _skeep="${lib.concatStringsSep " " (lib.attrNames skillSources)}"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (name: rel: ''
            _starget="${cfg.dshHome}/skills/${rel}"
            _sstamp="${cfg.dshHome}/skills/.dsh-nix-stamps/${name}"
            if [ -f "$_sstamp" ] && [ "$(cat "$_sstamp")" = "${toString cfg.skills.${name}.source}" ]; then
              :
            else
              rm -rf "$_starget"
              cp -a "${toString cfg.skills.${name}.source}" "$_starget"
              chmod -R u+w "$_starget" 2>/dev/null || true
              printf '%s' "${toString cfg.skills.${name}.source}" > "$_sstamp"
            fi
          '')
          skillSources)}
        for _stamp in "${cfg.dshHome}"/skills/.dsh-nix-stamps/*; do
          [ -e "$_stamp" ] || continue
          _name="$(basename "$_stamp")"
          case " $_skeep " in
            *" $_name "*) ;;
            *)
              rm -rf "${cfg.dshHome}/skills/$_name" "${cfg.dshHome}/skills/$_name.md"
              rm -f "$_stamp"
              ;;
          esac
        done
        rmdir "${cfg.dshHome}/skills/.dsh-nix-stamps" 2>/dev/null || true
      '');

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
        # bundle 指纹:profile 组合(in-box 开关/插件集)变化 → unit 变化 →
        # HM 重启服务。组合树只在 boot 时加载,settings.yaml 热重载覆盖不到
        # 条目级变化 —— 没有指纹,改 inBoxPlugins/plugins 后运行中的 web
        # 服务仍是旧树(已踩坑:llm-deepseek 禁用不生效直到手动重启)
        Environment =
          let
            fingerprint = lib.concatStringsSep " "
              (lib.mapAttrsToList (n: b: "${n}=${toString b}") profileBundles);
          in
          [ "DSH_PROFILE_FINGERPRINT=${fingerprint}" ];
      };
      Install = lib.mkIf cfg.web.autoStart {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
