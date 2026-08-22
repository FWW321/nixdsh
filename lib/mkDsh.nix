# nixvim 式独立实例化:不依赖 HM/NixOS eval,即可求值出一个绑定配置的 dsh
# (flake checks、未来抽独立 flake 时的对外 API)
{ lib, renderWrapper, applyPlugins, buildProfile, mkProfile }:

let
  inherit (lib) mapAttrs;

  mkDsh =
    { pkgs, modules ? [ ], extraSpecialArgs ? { } }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; } // extraSpecialArgs;
        modules = [
          # 传路径而非 import 结果:模块系统给路径模块记真实 _file →
          # options 的 declarations / 报错定位是文件而非 <unknown-file>
          # (nixosOptionsDoc 与消费方报错都依赖这一点)
          ../modules/options.nix
          {
            _file = "lib/mkDsh.nix";
            programs.dsh.package = lib.mkDefault pkgs.dsh;
          }
        ] ++ modules;
      };
      cfg = evaluated.config.programs.dsh;
      # 单次求值,wrapper 与 profileBundles 共用(renderWrapper 接受
      # applied 参数,不再内部重算)
      applied = applyPlugins { inherit cfg pkgs; };
      wrapper = renderWrapper { inherit cfg pkgs applied; };
      allProfiles = cfg.profiles // applied.facePlugins;
      withPlugins = name: p:
        let inc = applied.perProfile.${name} or { extraPlugins = [ ]; extraPatches = [ ]; }; in
        {
          plugins = p.plugins ++ inc.extraPlugins;
          userPatchesFile = p.userPatchesFile;
          userPatches = p.userPatches ++ inc.extraPatches;
        };
      profileBundles = mapAttrs
        (name: p: buildProfile {
          inherit pkgs;
          profile = mkProfile ({ inherit name; } // (withPlugins name p));
        })
        allProfiles;
    in
    {
      inherit (evaluated) config options;
      wrapper = wrapper;
      package = wrapper;
      inherit profileBundles;
    };
in
{
  inherit mkDsh;
}
