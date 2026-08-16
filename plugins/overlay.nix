# filepath: ~/nixos-config/pkgs/dsh/plugins/overlay.nix
# names.txt + update.sh → generated.nix → pkgs.dshPlugins.<packageName>
# (vimPlugins 的 generated.nix 同构;集合懒式:只含 names.txt 声明的插件)
#
# dshPlugins.<name> 是"插件就绪目录"derivation(源码树,monorepo 取 subpath),
# passthru 携带 packageName/bundlePatch 供 lib.nix mkPlugin 求值期读取
# (derivation 不可求值期检视 package.json,元数据在 update 时已物化)
{
  fetchFromGitHub,
  lib,
  runCommand,
}:

let
  entries = import ./generated.nix;
in
lib.mapAttrs
  (name: e:
    runCommand "dsh-plugin-${name}"
      {
        passthru = {
          packageName = name;
          dshBundlePatch = e.bundlePatch or null;
        };
        meta = with lib; {
          description = "dsh plugin source: ${e.owner}/${e.repo}@${e.version}";
          platforms = platforms.all;
        };
      }
      ''
        cp -r ${fetchFromGitHub {
          owner = e.owner;
          repo = e.repo;
          rev = e.rev;
          hash = e.hash;
        }}${lib.optionalString (e ? subpath) "/${e.subpath}"} "$out"
      '')
  entries
