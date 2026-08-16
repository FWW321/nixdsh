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
          (import ../modules/options.nix)
          {
            programs.dsh.package = lib.mkDefault pkgs.dsh;
          }
        ] ++ modules;
      };
      cfg = evaluated.config.programs.dsh;
      wrapper = renderWrapper { inherit cfg pkgs; };
      applied = applyPlugins { inherit cfg pkgs; };
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
